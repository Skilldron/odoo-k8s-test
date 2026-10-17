#!/usr/bin/env bash
# Odoo step of the restore runbook (§3.3 of docs/plans/k8s-deployment.md), once the
# administrator has restored the database from the restore point into a new cluster:
# Odoo on the image of before the restore point, the restored database, and a new
# filestore volume (generation + 1) created from the snapshot of the restore point. No Job:
# the restored database matches that image. The failed database and the previous filestore
# volume stay in place. The data entered since the restore point are lost.
# Usage: ci/deploy-rollback.sh ENV POINT SECRET [CLUSTER]
#   ENV      recette | production
#   POINT    restore point, as given by ci/deploy.sh
#   SECRET   Secret of the restored database (keys host, port, username, password)
#   CLUSTER  its CNPG Cluster (required when the environment uses CNPG): next restore points
# Env: NAMESPACE (default: namespace of the kubeconfig context), SMOKE (https, or none),
#      EXTRA_VALUES (tests)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh
# shellcheck source=ci/deploy-lib.sh
source ci/deploy-lib.sh

usage="usage: ci/deploy-rollback.sh ENV POINT SECRET [CLUSTER]"
env="${1:?$usage}"
point="${2:?$usage}"
db_secret="${3:?$usage}"
cluster="${4:-}"
case "$env" in
recette | production) ;;
*) fail "restoration is for recette and production, not $env" ;;
esac
namespace="${NAMESPACE:-$(namespace_of_context)}"
[ -n "$namespace" ] || fail "no namespace: set NAMESPACE or the namespace of the kubeconfig context"
release=odoo
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

{
    echo "### Restauration $env"
    echo
    echo "- release \`$release\`, namespace \`$namespace\`, point \`$point\`"
} | ci_summary

log "Restore point $point"
snapshot="$(kubectl -n "$namespace" get volumesnapshot "$point-filestore" -o json)" ||
    fail "restore point $point not found (VolumeSnapshot $point-filestore)"
[ "$(jq -r '.status.readyToUse' <<<"$snapshot")" = true ] ||
    fail "VolumeSnapshot $point-filestore is not ready"
annotation() { jq -r --arg k "restore-point.odoo/$1" '.metadata.annotations[$k] // empty' <<<"$snapshot"; }
digest="$(annotation from-digest)"
[[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] ||
    fail "restore point $point has no previous image (from-digest: ${digest:-none})"
if [ -n "$(annotation database)" ] && [ -z "$cluster" ]; then
    fail "the environment uses CNPG ($(annotation database)): give the Cluster of the restored database"
fi

current="$(release_values)"
repository="$(jq -r '.image.repository // empty' <<<"$current")"
[ -n "$repository" ] || fail "release $release not found in $namespace"
save_state
generation=$(($(jq -r '.state.generation // 1' "$work/state.json") + 1))
state_args=(--set state.initialized=true --set state.generation="$generation"
    --set state.filestore="$point-filestore" --set state.databaseSecret="$db_secret"
    --set state.cnpgCluster="$cluster")

log "Preflight"
require_keys "$db_secret" host port username password
if [ -n "$cluster" ]; then
    cnpg_ready "$cluster"
fi
render_values "${state_args[@]}" --set odoo.replicas=1

log "Odoo on ${digest:7:12}, filestore generation $generation, database $db_secret"
helm_odoo "${state_args[@]}" --set odoo.replicas=1 --wait --timeout 10m >/dev/null ||
    fail "Odoo did not start after the restoration"
url="$(odoo_url)"
if [ -n "$url" ] && [ "${SMOKE:-https}" != none ]; then
    log "Smoke test $url"
    smoke "$url" || fail "smoke test failed on $url"
fi
output url "$url"

{
    echo
    echo "**Restauré.** ${url:+URL : $url}"
    echo
    echo "- Image : \`$repository@$digest\` ; base : \`$db_secret\` ; filestore : génération $generation."
    echo "- Les saisies faites depuis le point de restauration sont perdues."
    echo "- L'ancienne base et le volume \`$release-odoo-data-$((generation - 1))\` restent en place (suppression manuelle)."
} | ci_summary
echo "deploy-rollback: $release restored from $point in $namespace${url:+ ($url)}"
