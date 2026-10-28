#!/usr/bin/env bash
# Restore job of the workflow, run only when the deploy job failed, persistent environments
# (the manual procedure is in docs/operations.md of the chart):
#   - complete pending restore point of the release: new CNPG cluster <cluster>-r<revision>
#     recovered from it (CNPG "cluster" chart, values of the active cluster, one
#     instance), its volumeSnapshot section copied from the active cluster, the stable
#     Service switched to it, the point labelled restored, then helm rollback to the
#     revision before the point (old image, Odoo restarted);
#   - no such point: the database was not touched, helm rollback only, or nothing at all
#     without release or when the release is deployed (deploy job failed in its
#     preflight or smoke test);
#   - the update was applied and Odoo serves it (only the validation failed): nothing is
#     restored, the point has to be validated by hand.
# The previous cluster is never deleted (analysis, then the administrator uninstalls it).
# With POINT, a manual rollback to that restore point (any state): Odoo is stopped first,
# and what was saved since the point is lost.
# Usage: ci/deploy-restore.sh ENV [POINT]
# Env: NAMESPACE (default: namespace of the kubeconfig context), CNPG_CHART_REPO
#      (https://cloudnative-pg.github.io/charts), SMOKE (https, or none without Gateway)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh
# shellcheck source=ci/deploy-lib.sh
source ci/deploy-lib.sh

usage="usage: ci/deploy-restore.sh ENV [POINT]"
env="${1:?$usage}"
point="${2:-}"
[[ "$env" =~ ^[a-z0-9-]+$ ]] || fail "invalid environment name: $env"
namespace="${NAMESPACE:-$(namespace_of_context)}"
[ -n "$namespace" ] || fail "no namespace: set NAMESPACE or the namespace of the kubeconfig context"
release=odoo
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if ! helm get values "$release" -n "$namespace" -a -o json >"$work/values.json" 2>/dev/null; then
    [ -z "$point" ] || fail "no release $release in $namespace"
    # The deploy job failed before the first installation (preflight): nothing was created
    echo "**Nothing to restore**: no release \`$release\` in \`$namespace\`." | ci_summary
    echo "deploy-restore: no release $release in $namespace: nothing to restore"
    exit 0
fi
[ "$(value .ephemeral)" != true ] || fail "$env is ephemeral: no restore point"
prefix="$(value .labelPrefix)"
service="$(value .database.external.host | cut -d. -f1)"

{
    echo "### Restoration $env"
    echo
    echo "- release \`$release\`, namespace \`$namespace\`, statut \`$(release_status)\`"
} | ci_summary

# A run cancelled during helm upgrade leaves its hook Jobs running in the cluster: never
# restore under a migration still in progress
[ -z "$(hook_jobs Active)" ] || fail "hook Jobs still running ($(hook_jobs Active | tr '\n' ' ')): try again once they end"

if [ -z "$point" ]; then
    complete_pending "$prefix" >"$work/pending"
    [ "$(grep -c . "$work/pending")" -le 1 ] ||
        fail "several complete pending restore points: $(cut -d' ' -f1 "$work/pending" | tr '\n' ' ')"
    read -r point target <"$work/pending" || true
    if [ -n "$point" ] && serving "$target"; then
        {
            echo
            echo "**No restoration**: the update is applied and Odoo serves it; only its validation failed."
            echo "Check, then validate the point: \`kubectl -n $namespace label backups.postgresql.cnpg.io $point $prefix/upgrade-state=validated --overwrite\`."
        } | ci_summary
        fail "update applied and served, restore point $point left pending: validate it by hand"
    fi
    if [ -z "$point" ] && [ "$(release_status)" = deployed ]; then
        # The deploy job failed before helm upgrade (preflight) or after it (smoke test):
        # the deployed release is the one serving, there is nothing to undo
        echo "**Nothing to restore**: the release is deployed and no restore point is pending." | ci_summary
        echo "deploy-restore: $release deployed, no pending restore point: nothing to restore"
        exit 0
    fi
else
    kubectl -n "$namespace" get backups.postgresql.cnpg.io "$point" >/dev/null ||
        fail "restore point $point not found"
fi

# Revision to roll back to: the last one deployed before the restore point (the point
# r<N> was taken by revision N), or before the failed update without a point
revisions="$(helm history "$release" -n "$namespace" --max 100 -o json)"
if [ -n "$point" ]; then
    [[ "$point" =~ -preupgrade-r([0-9]+)$ ]] || fail "unexpected restore point name: $point"
    point_revision="${BASH_REMATCH[1]}"
else
    point_revision="$(jq -r 'last | .revision' <<<"$revisions")"
fi
target_revision="$(jq -r --argjson r "$point_revision" '[.[] | select(.revision < $r and
    (.status == "deployed" or .status == "superseded"))] | last | .revision // empty' <<<"$revisions")"

if [ -z "$point" ]; then
    [ -n "$target_revision" ] || fail "first installation failed: nothing to restore (see the deploy job)"
    log "No restore point: database untouched, helm rollback to revision $target_revision"
    helm rollback "$release" "$target_revision" -n "$namespace" --wait --timeout 15m >/dev/null ||
        fail "helm rollback failed"
    echo "**Back to revision $target_revision**, database untouched by the update." | ci_summary
else
    [ -n "$target_revision" ] || fail "no deployed revision before the restore point $point"
    cluster="$(kubectl -n "$namespace" get backups.postgresql.cnpg.io "$point" -o jsonpath='{.spec.cluster.name}')"
    active="$(active_cluster "$service")"
    new="${active%-r[0-9]*}-r$point_revision"
    if [ -n "${2:-}" ]; then
        log "Manual rollback: Odoo stopped"
        kubectl -n "$namespace" scale deployment --replicas=0 \
            -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=odoo" >/dev/null
        kubectl -n "$namespace" wait pod --for=delete --timeout=600s \
            -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=odoo" >/dev/null
    fi
    log "Restore point $point (cluster $cluster) into the new cluster $new"
    db_release="$(kubectl -n "$namespace" get clusters.postgresql.cnpg.io "$cluster" \
        -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}')"
    [ -n "$db_release" ] || fail "cluster $cluster was not installed with the CNPG cluster chart"
    chart_version="$(helm list -n "$namespace" -o json |
        jq -r --arg r "$db_release" '.[] | select(.name == $r) | .chart | sub("^cluster-"; "")')"
    helm get values "$db_release" -n "$namespace" -o json >"$work/database.json"
    helm upgrade --install "$new" cluster --repo "${CNPG_CHART_REPO:-https://cloudnative-pg.github.io/charts}" \
        --version "$chart_version" -n "$namespace" -f "$work/database.json" \
        --set fullnameOverride="$new" --set cluster.instances=1 \
        --set mode=recovery --set recovery.method=backup --set recovery.backupName="$point" \
        --set recovery.database="$(jq -r '.cluster.initdb.database // "app"' "$work/database.json")" \
        --set recovery.owner="$(jq -r '.cluster.initdb.owner // "odoo"' "$work/database.json")" \
        >/dev/null || fail "helm install of the cluster $new failed"
    kubectl -n "$namespace" wait "clusters.postgresql.cnpg.io/$new" --for=condition=Ready --timeout=1800s >/dev/null ||
        fail "cluster $new not ready"
    snapshot="$(kubectl -n "$namespace" get clusters.postgresql.cnpg.io "$cluster" -o json |
        jq -c '{spec: {backup: {volumeSnapshot: .spec.backup.volumeSnapshot}}}')"
    kubectl -n "$namespace" patch clusters.postgresql.cnpg.io "$new" --type merge -p "$snapshot" >/dev/null
    kubectl -n "$namespace" wait pod -l "cnpg.io/cluster=$new,cnpg.io/instanceRole=primary" \
        --for=condition=Ready --timeout=600s >/dev/null || fail "primary of $new not ready"
    log "Stable Service $service -> $new"
    kubectl -n "$namespace" patch service "$service" \
        -p "{\"spec\":{\"selector\":{\"cnpg.io/cluster\":\"$new\"}}}" >/dev/null
    kubectl -n "$namespace" label backups.postgresql.cnpg.io "$point" "$prefix/upgrade-state=restored" \
        --overwrite >/dev/null
    log "helm rollback to revision $target_revision"
    helm rollback "$release" "$target_revision" -n "$namespace" --wait --timeout 15m >/dev/null ||
        fail "helm rollback failed (database already restored in $new)"
    {
        echo
        echo "**Restored** from \`$point\` into the cluster \`$new\`; release back to revision $target_revision."
        echo
        echo "- Previous cluster \`$active\` kept: analyse it, then uninstall it."
        echo "- Scale \`$new\` to the wanted instances (\`helm upgrade $new … --reuse-values --set cluster.instances=N\`)."
        if [ -n "${2:-}" ]; then
            echo "- What was entered since the restore point is lost."
        fi
    } | ci_summary
    output cluster "$new"
fi

url="$(odoo_url)"
if [ -n "$url" ] && [ "${SMOKE:-https}" != none ]; then
    log "Smoke test $url"
    smoke "$url" || fail "smoke test failed on $url (Odoo is up: check the Gateway)"
fi
echo "deploy-restore: $release restored in $namespace${point:+ from $point}"
