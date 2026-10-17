#!/usr/bin/env bash
# Restore point of a recette or production release, Odoo stopped (§3.2, step 3 of
# docs/plans/k8s-deployment.md):
# - CNPG database: cold volume snapshot (Backup method volumeSnapshot, online: false; CNPG
#   fences the instance meanwhile), when the release has a CNPG cluster;
# - filestore: VolumeSnapshot of the current volume.
# Both are labelled with the release and annotated with what a restoration needs (previous
# image, generation). Nothing is ever deleted: the administrator purges old restore points.
# Usage: ci/deploy-snapshot.sh RELEASE FROM_DIGEST TO_DIGEST → prints the restore point name
# Env: NAMESPACE (default: namespace of the kubeconfig context), SNAPSHOT_TIMEOUT (900 s)
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: ci/deploy-snapshot.sh RELEASE FROM_DIGEST TO_DIGEST"
release="${1:?$usage}"
from="${2:?$usage}"
to="${3:?$usage}"
namespace="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}')}"
timeout="${SNAPSHOT_TIMEOUT:-900}"

values="$(helm get values "$release" -n "$namespace" --all -o json)"
value() { jq -r "($1) // empty" <<<"$values"; }
cluster="$(value '(.state.cnpgCluster | select(. != "")) // .database.external.cnpgCluster')"
generation="$(value .state.generation)"
class="$(value .snapshots.volumeSnapshotClass)"
[ -n "$class" ] || {
    echo "snapshots.volumeSnapshotClass is not set" >&2
    exit 1
}
name="$release-$(date -u +%Y%m%d-%H%M%S)"
metadata="namespace: $namespace
  labels:
    app.kubernetes.io/instance: $release
    restore-point.odoo/release: $release
  annotations:
    restore-point.odoo/from-digest: \"$from\"
    restore-point.odoo/to-digest: \"$to\"
    restore-point.odoo/generation: \"$generation\"
    restore-point.odoo/database: \"$cluster\""

{
    if [ -n "$cluster" ]; then
        cat <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $name
  $metadata
spec:
  cluster: {name: $cluster}
  method: volumeSnapshot
  online: false
---
EOF
    fi
    cat <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $name-filestore
  $metadata
spec:
  volumeSnapshotClassName: $class
  source: {persistentVolumeClaimName: $release-odoo-data-$generation}
EOF
} | kubectl apply -f - >&2

if [ -n "$cluster" ]; then
    kubectl -n "$namespace" wait "backup/$name" --for=jsonpath='{.status.phase}'=completed \
        --timeout="${timeout}s" >&2 || {
        kubectl -n "$namespace" get "backup/$name" -o jsonpath='{.status.error}' >&2
        echo >&2
        exit 1
    }
fi
kubectl -n "$namespace" wait "volumesnapshot/$name-filestore" \
    --for=jsonpath='{.status.readyToUse}'=true --timeout="${timeout}s" >&2
if [ -n "$cluster" ]; then
    # The instance was fenced during the cold snapshot
    kubectl -n "$namespace" wait "clusters.postgresql.cnpg.io/$cluster" --for=condition=Ready \
        --timeout=300s >&2
fi
echo "$name"
