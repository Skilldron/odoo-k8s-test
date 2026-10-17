#!/usr/bin/env bash
# Deploys an image with the chart (§3.2 of docs/plans/k8s-deployment.md):
#   1. preflight, before any downtime: server-side rendering, Secrets and their keys, CNPG
#      database (ready, WAL archiving, volume snapshots enabled), cap of the review apps;
#   2. Odoo at 0 with the new image;
#   3. restore point (recette, production; none before the database exists);
#   4. db-init Job until Odoo's database exists (recette, production), migrate Job;
#   5. Odoo at 1, smoke test through the Gateway.
# After a failure in 3, 4 or 5, Odoo stays at 0 and the job summary gives the Job logs, the
# restore point and the restore runbook. Nothing is deleted outside review.
# The state of the environment (Helm values "state": database created, filestore
# generation, restored database) is read from the release and carried over. An image that
# is already deployed is only started: no stop, no restore point, no Job.
# Usage: ci/deploy.sh ENV IMAGE@DIGEST
#   ENV   review | recette | production
# Env: PR_NUMBER (review), NAMESPACE (default: namespace of the kubeconfig context),
#      REVIEW_MAX_APPS (5), SMOKE (https, or none without Gateway), EXTRA_VALUES (tests)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh
# shellcheck source=ci/deploy-lib.sh
source ci/deploy-lib.sh

usage="usage: ci/deploy.sh ENV IMAGE@DIGEST"
env="${1:?$usage}"
ref="${2:?$usage}"
case "$env" in
review | recette | production) ;;
*) fail "unknown environment $env" ;;
esac
[[ "$ref" =~ ^[^@]+@sha256:[a-f0-9]{64}$ ]] || fail "image must be IMAGE@sha256:<digest>: $ref"
repository="${ref%@*}"
digest="${ref#*@}"
short="${digest#sha256:}"
short="${short:0:12}"
namespace="${NAMESPACE:-$(namespace_of_context)}"
[ -n "$namespace" ] || fail "no namespace: set NAMESPACE or the namespace of the kubeconfig context"
if [ "$env" = review ]; then
    [ -n "${PR_NUMBER:-}" ] || fail "PR_NUMBER is required for a review"
    release="pr-$PR_NUMBER"
else
    release=odoo
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
restore_point=""
cluster=""
state_args=()

{
    echo "### Déploiement $env"
    echo
    echo "- release \`$release\`, namespace \`$namespace\`"
    echo "- image \`$ref\`"
} | ci_summary

runbook() { # summary after a failed update: Odoo is stopped, what to do
    local next
    {
        echo
        echo "#### Odoo est arrêté"
        echo
        echo "- Image précédente : \`${previous_digest:-aucune}\`."
        if [ -n "$restore_point" ]; then
            echo "- Point de restauration : \`$restore_point\`."
        else
            echo "- Pas de point de restauration (base créée par ce déploiement)."
        fi
        echo "- **Correctif** : corriger, puis nouveau déploiement sur la base telle quelle."
        if [ -n "$restore_point" ] && [ -n "$cluster" ]; then
            if [[ "$cluster" =~ ^(.*)-([0-9]+)$ ]]; then
                next="${BASH_REMATCH[1]}-$((BASH_REMATCH[2] + 1))"
            else
                next="$cluster-2"
            fi
            echo "- **Restauration** (runbook) :"
            echo "  1. base, par l'administrateur : \`helm install $next cluster --repo https://cloudnative-pg.github.io/charts -n $namespace -f <valeurs de $cluster> -f deploy/examples/cnpg-cluster-recovery.values.yaml --set fullnameOverride=$next --set recovery.backupName=$restore_point\`, puis le patch \`volumeSnapshot\` de \`$next\` ;"
            echo "  2. Odoo : workflow \`rollback\`, soit \`ci/deploy-rollback.sh $env $restore_point $next-app $next\`."
        elif [ -n "$restore_point" ]; then
            echo "- **Restauration** : base avec l'outil de l'équipe, puis \`ci/deploy-rollback.sh $env $restore_point <Secret de la base restaurée>\`."
        fi
    } | tee /dev/stderr | ci_summary
}

stopped_fail() { # stopped_fail <message>: failure after the stop, Odoo stays at 0
    if [ "$env" != review ]; then
        runbook
    fi
    fail "$1; Odoo stays stopped"
}

# A run cancelled during helm upgrade leaves the release pending
log "Release $release in $namespace"
status="$(release_status)"
case "$status" in
pending-install)
    [ "$env" = review ] ||
        fail "first installation of $release interrupted (pending-install): see the runbook"
    helm uninstall "$release" -n "$namespace" --wait >/dev/null
    status=none
    ;;
pending-upgrade | pending-rollback)
    echo "    $status: back to the previous revision"
    helm rollback "$release" -n "$namespace" --wait >/dev/null
    ;;
esac
previous_digest="$(release_values | jq -r '.image.digest // empty')"
previous_replicas="$(release_values | jq -r '.odoo.replicas // 0')"
save_state
initialized="$(jq -r '.state.initialized // false' "$work/state.json")"

log "Preflight"
if [ "$env" = review ] && [ "$status" = none ]; then
    reviews="$(helm list -n "$namespace" -q --filter '^pr-[0-9]+$')" || fail "helm list failed"
    count="$(grep -c . <<<"$reviews" || true)"
    [ "$count" -lt "${REVIEW_MAX_APPS:-5}" ] ||
        fail "cap of ${REVIEW_MAX_APPS:-5} review apps reached: close a pull request or raise REVIEW_MAX_APPS"
fi
render_values --set odoo.replicas=0
for secret in $(value '.image.pullSecrets[]?'); do
    require_keys "$secret" .dockerconfigjson
done
while read -r secret key; do
    require_keys "$secret" "$key"
done < <(jq -r '.secrets.env[]? | "\(.secret) \(.key)"' "$work/values.json")
for class in $(value '.odoo.persistence.storageClass, .database.ephemeral.storageClass'); do
    cluster_object storageclasses.storage.k8s.io "$class"
done
if [ "$env" != review ]; then
    keys=(admin-passwd)
    [ "$initialized" = true ] || keys+=(admin-user-password)
    require_keys "$(value .secrets.existingSecret)" "${keys[@]}"
    require_keys "$(value '(.state.databaseSecret | select(. != "")) // .database.external.secret')" \
        host port username password
    cluster="$(value '(.state.cnpgCluster | select(. != "")) // .database.external.cnpgCluster')"
    if [ -n "$cluster" ]; then
        cnpg_ready "$cluster"
    else
        echo "    database not managed by CNPG: no restore point of the database"
    fi
    snapclass="$(value .snapshots.volumeSnapshotClass)"
    [ -n "$snapclass" ] || fail "snapshots.volumeSnapshotClass is not set: no restore point possible"
    cluster_object volumesnapshotclasses.snapshot.storage.k8s.io "$snapclass"
fi

# Same image, last update completed (Odoo at 1): only make sure Odoo runs. After a failed
# update (Odoo at 0), running it again is a retry: new restore point, then the Jobs again on
# the database as it is.
if [ "$digest" = "$previous_digest" ] && [ "$status" = deployed ] && [ "$previous_replicas" = 1 ]; then
    log "Image already deployed: Odoo at 1, no Job"
    helm_odoo --set odoo.replicas=1 --wait --timeout 10m >/dev/null || fail "Odoo did not start"
    url="$(odoo_url)"
    if [ -n "$url" ] && [ "${SMOKE:-https}" != none ]; then
        smoke "$url" || fail "smoke test failed on $url"
    fi
    output url "$url"
    echo "**Image déjà déployée**, Odoo démarré. ${url:+URL : $url}" | ci_summary
    echo "deploy: $release already on $short in $namespace"
    exit 0
fi

log "Stop: Odoo at 0, image $short"
helm_odoo --set odoo.replicas=0 >/dev/null || fail "helm upgrade failed (stop)"
wait_pods_gone
if [ "$env" = review ]; then
    # The ephemeral database restarts on its new volume; the migrate Job does not retry
    kubectl -n "$namespace" rollout status "deploy/$release-postgres" --timeout=300s >/dev/null ||
        fail "the ephemeral database did not start"
fi

if [ "$env" != review ]; then
    if [ "$initialized" = true ]; then
        log "Restore point"
        restore_point="$(NAMESPACE="$namespace" ci/deploy-snapshot.sh "$release" \
            "${previous_digest:-none}" "$digest")" || stopped_fail "restore point failed"
        echo "    $restore_point"
        output restore_point "$restore_point"
    else
        log "Database creation (db-init Job)"
        helm_odoo --set odoo.replicas=0 --set jobs.dbInit.run=true >/dev/null ||
            stopped_fail "helm upgrade failed (db-init)"
        job="$release-db-init-$(helm status "$release" -n "$namespace" -o json | jq -r .version)"
        if wait_job "$job" $(($(value .jobs.dbInit.activeDeadlineSeconds) + 60)); then
            echo "    database created"
        elif grep -q "exists, aborting" "$work/$job.log"; then
            echo "    database already created by a previous attempt"
        else
            job_logs_summary "$job"
            stopped_fail "db-init Job failed"
        fi
    fi
    state_args=(--set state.initialized=true)
fi

log "Migrate Job"
helm_odoo --set odoo.replicas=0 --set jobs.migrate.run=true ${state_args[@]+"${state_args[@]}"} \
    >/dev/null || stopped_fail "helm upgrade failed (migrate)"
job="$release-migrate-$short"
if ! wait_job "$job" $(($(value .jobs.migrate.activeDeadlineSeconds) + 60)); then
    job_logs_summary "$job"
    stopped_fail "migrate Job failed"
fi

log "Start: Odoo at 1"
if ! helm_odoo --set odoo.replicas=1 ${state_args[@]+"${state_args[@]}"} --wait --timeout 10m \
    >/dev/null; then
    helm_odoo --set odoo.replicas=0 ${state_args[@]+"${state_args[@]}"} >/dev/null || true
    stopped_fail "Odoo did not start"
fi
url="$(odoo_url)"
if [ -n "$url" ] && [ "${SMOKE:-https}" != none ]; then
    log "Smoke test $url"
    if ! smoke "$url"; then
        helm_odoo --set odoo.replicas=0 ${state_args[@]+"${state_args[@]}"} >/dev/null || true
        stopped_fail "smoke test failed on $url"
    fi
fi
output url "$url"

{
    echo
    echo "**Déployé.** ${url:+URL : $url}"
    if [ "$env" = review ]; then
        echo
        echo "Connexion : \`admin\` / \`$(kubectl -n "$namespace" get secret "$release-secrets" \
            -o go-template='{{index .data "review-admin-password" | base64decode}}')\`"
    else
        echo
        echo "Points de restauration (purge par l'administrateur) :"
        kubectl -n "$namespace" get volumesnapshots -l "restore-point.odoo/release=$release" \
            --sort-by=.metadata.creationTimestamp -o name | sed 's|.*/|- |; s|-filestore$||'
    fi
} | ci_summary
echo "deploy: $release deployed in $namespace${url:+ ($url)}"
