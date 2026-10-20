#!/usr/bin/env bash
# Deploys an image to an environment with the chart of deploy/chart.env. The chart owns the
# update: its hooks stop Odoo, take the restore point, migrate the database, then
# validate the point and purge the old ones. This script only:
#   1. checks, before any downtime: server-side rendering, Secrets and their keys, the
#      stable Service and its CNPG cluster (ready, WAL archiving, the administrator's
#      volumeSnapshot patch), deletionPolicy Delete of the snapshot classes, no orphan
#      restore point, cap of the review apps;
#   2. runs helm upgrade --install: with --wait for an update of a persistent instance,
#      otherwise (first installation, review app) without, then kubectl rollout status,
#      since the Odoo pods wait for the post-install migrate Job;
#   3. runs the smoke test through the Gateway.
# After a failed update, Odoo stays stopped: the restore job of the workflow runs
# ci/deploy-restore.sh. An image that is already deployed is left as it is.
# Usage: ci/deploy.sh ENV IMAGE@DIGEST
#   ENV   name of the environment, values in deploy/values/<ENV>.yaml
# Env: PR_NUMBER (review app pr-<n>, ephemeral values), NAMESPACE (default: namespace of the kubeconfig context),
#      REVIEW_MAX_APPS (5), DEPLOY_TIMEOUT (helm --timeout, 60m), SMOKE (https, or none
#      without Gateway), EXTRA_VALUES (tests)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh
# shellcheck source=ci/deploy-lib.sh
source ci/deploy-lib.sh

usage="usage: ci/deploy.sh ENV IMAGE@DIGEST"
env="${1:?$usage}"
ref="${2:?$usage}"
[[ "$env" =~ ^[a-z0-9-]+$ ]] && [ -f "deploy/values/$env.yaml" ] ||
    fail "unknown environment $env: no deploy/values/$env.yaml"
[[ "$ref" =~ ^[^@]+@sha256:[a-f0-9]{64}$ ]] || fail "image must be IMAGE@sha256:<digest>: $ref"
repository="${ref%@*}"
digest="${ref#*@}"
short="${digest#sha256:}"
short="${short:0:12}"
namespace="${NAMESPACE:-$(namespace_of_context)}"
[ -n "$namespace" ] || fail "no namespace: set NAMESPACE or the namespace of the kubeconfig context"
# A review app (ephemeral=true in the values) is the release pr-<n> of a pull request
review=""
release=odoo
if [ -n "${PR_NUMBER:-}" ]; then
    [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || fail "PR_NUMBER must be a pull request number: $PR_NUMBER"
    review=true
    release="pr-$PR_NUMBER"
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

{
    echo "### Deployment $env"
    echo
    echo "- release \`$release\`, namespace \`$namespace\`"
    echo "- image \`$ref\`"
} | ci_summary

log "Release $release in $namespace"
status="$(release_status)"
echo "    status: $status"
case "$status" in
pending-*)
    # A run cancelled during helm upgrade: a hook may still run, or the update is lost
    [ -z "$(hook_jobs Active)" ] || fail "update in progress (hook Jobs running): try again later"
    if [ -n "$review" ]; then
        if [ "$status" = pending-install ]; then
            helm uninstall "$release" -n "$namespace" --wait >/dev/null
            status=none
        else
            helm rollback "$release" -n "$namespace" --wait >/dev/null
            status="$(release_status)"
        fi
    else
        fail "release $release left $status by an interrupted update: treated as a failed update (restore job)"
    fi
    ;;
esac
previous_digest="$(release_values | jq -r '.image.digest // empty')"

# Same image already deployed and serving: nothing to do, no downtime
if [ "$status" = deployed ] && [ "$digest" = "$previous_digest" ]; then
    log "Image already deployed: nothing to do"
    kubectl -n "$namespace" rollout status "deploy/$release" --timeout=600s >/dev/null ||
        fail "Odoo is not running"
    echo "**Image already deployed**, nothing to do." | ci_summary
    echo "deploy: $release already on $short in $namespace"
    exit 0
fi

log "Preflight"
if [ -n "$review" ] && [ "$status" = none ]; then
    reviews="$(helm list -n "$namespace" -q --filter '^pr-[0-9]+$')" || fail "helm list failed"
    count="$(grep -c . <<<"$reviews" || true)"
    [ "$count" -lt "${REVIEW_MAX_APPS:-5}" ] ||
        fail "cap of ${REVIEW_MAX_APPS:-5} review apps reached: close a pull request or raise REVIEW_MAX_APPS"
fi
render_values --history-max 10
[ "$(jq '.ephemeral == true' "$work/values.json")" = "${review:-false}" ] ||
    fail "deploy/values/$env.yaml: ephemeral must be true for a pull request (PR_NUMBER), false otherwise"
for secret in $(value '.image.pullSecrets[]?'); do
    require_keys "$secret" .dockerconfigjson
done
while read -r secret key; do
    require_keys "$secret" "$key"
done < <(jq -r '.secrets.env[]? | "\(.secret) \(.key)"' "$work/values.json")
if [ "$(value .odoo.persistence.enabled)" = true ] && [ -z "$(value .odoo.persistence.existingClaim)" ]; then
    for class in $(value .odoo.persistence.storageClass); do
        cluster_object storageclasses.storage.k8s.io "$class"
    done
fi
for class in $(value .database.ephemeral.storageClass); do
    [ -z "$review" ] || cluster_object storageclasses.storage.k8s.io "$class"
done
if [ -z "$review" ]; then
    # Odoo's database is created by the first successful deployment
    keys=(admin-passwd)
    helm history "$release" -n "$namespace" -o json 2>/dev/null |
        jq -e 'any(.[]; .status == "deployed" or .status == "superseded")' >/dev/null ||
        keys+=(admin-user-password)
    require_keys "$(value .secrets.existingSecret)" "${keys[@]}"
    require_keys "$(value .database.external.secret)" username password
    service="$(value .database.external.host | cut -d. -f1)"
    cluster="$(active_cluster "$service")" ||
        fail "stable Service $service of the database not found in $namespace"
    [ -n "$cluster" ] || fail "Service $service has no selector cnpg.io/cluster"
    echo "    database: Service $service -> CNPG cluster $cluster"
    cnpg_ready "$cluster"
    snapshot_class_deletes "$(kubectl -n "$namespace" get clusters.postgresql.cnpg.io "$cluster" \
        -o jsonpath='{.spec.backup.volumeSnapshot.className}')"
    if [ "$(value .odoo.persistence.enabled)" = true ]; then
        snapshot_class_deletes "$(value .restorePoints.volumeSnapshotClass)"
    fi
    # Orphan restore point: the update it protected was applied, its validation failed
    if [ "$status" = deployed ]; then
        orphan="$(complete_pending "$(value .labelPrefix)" | cut -d' ' -f1 | head -1)"
        [ -z "$orphan" ] ||
            fail "restore point $orphan is still pending while the release is deployed: its update succeeded, its validation failed. Check, then: kubectl -n $namespace label backups.postgresql.cnpg.io $orphan $(value .labelPrefix)/upgrade-state=validated --overwrite"
    fi
fi

timeout="${DEPLOY_TIMEOUT:-60m}"
if [ -z "$review" ] && [ "$status" != none ]; then
    log "Update: helm upgrade --wait (hooks: stop, restore point, migrate, validate)"
    if ! helm_odoo --wait --timeout "$timeout" >"$work/helm.log" 2>&1; then
        cat "$work/helm.log" >&2
        failed_jobs_summary
        {
            echo
            echo "#### Odoo is stopped"
            echo
            echo "The \`restore\` job restores the pending restore point (\`ci/deploy-restore.sh $env\`)."
        } | ci_summary
        fail "update failed"
    fi
else
    log "Install: helm upgrade --install (migrate Job after the release, Odoo waits for it)"
    if ! helm_odoo --timeout "$timeout" >"$work/helm.log" 2>&1; then
        cat "$work/helm.log" >&2
        failed_jobs_summary
        fail "installation failed"
    fi
    kubectl -n "$namespace" rollout status "deploy/$release" --timeout=600s >/dev/null ||
        fail "Odoo did not start"
fi

url="$(odoo_url)"
if [ -n "$url" ] && [ "${SMOKE:-https}" != none ]; then
    log "Smoke test $url"
    # Pods ready: a failure here points at the Gateway, not at the update
    smoke "$url" || fail "smoke test failed on $url (Odoo is up: check the Gateway)"
fi
output url "$url"

{
    echo
    echo "**Deployed.** ${url:+URL: $url}"
    if [ -n "$review" ]; then
        echo
        echo "Login: \`admin\` / \`$(kubectl -n "$namespace" get secret "$release-secrets" \
            -o go-template='{{index .data "review-admin-password" | base64decode}}')\`"
    else
        echo
        echo "Restore points:"
        for state in pending validated restored; do
            points "$state" | awk -v s="$state" '{print "- `" $1 "` (" s ")"}'
        done
    fi
} | ci_summary
echo "deploy: $release deployed in $namespace${url:+ ($url)}"
