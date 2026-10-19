#!/usr/bin/env bash
# Removes the review app of a pull request: its hook resources (migrate Job, hook
# ConfigMap: Helm does not track them), then helm uninstall pr-<n>, which deletes all of
# its other resources, volumes included. Only the release pr-<n> is touched. Nothing to do when it does not exist.
# Usage: ci/review-remove.sh N
# Env: NAMESPACE (default: namespace of the kubeconfig context), DRY_RUN=true (print only)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh

number="${1:?usage: ci/review-remove.sh N}"
[[ "$number" =~ ^[0-9]+$ ]] || {
    echo "review-remove: N must be a pull request number: $number" >&2
    exit 1
}
release="pr-$number"
namespace="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}')}"
[ -n "$namespace" ] || {
    echo "review-remove: no namespace (NAMESPACE or the kubeconfig context)" >&2
    exit 1
}

if ! helm status "$release" -n "$namespace" >/dev/null 2>&1; then
    echo "review-remove: no review app $release in $namespace"
    exit 0
fi
if [ "${DRY_RUN:-}" = true ]; then
    echo "review-remove: would uninstall $release in $namespace"
    exit 0
fi
kubectl -n "$namespace" delete jobs,configmaps --wait --timeout=5m \
    -l "app.kubernetes.io/instance=$release,app.kubernetes.io/managed-by=Helm" >/dev/null
helm uninstall "$release" -n "$namespace" --wait --timeout 5m
echo "- review app \`$release\` removed" | ci_summary
echo "review-remove: $release uninstalled from $namespace"
