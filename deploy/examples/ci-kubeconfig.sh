#!/usr/bin/env bash
# Prints the kubeconfig of the deployment ServiceAccount of a namespace (ci-access.yaml),
# for the KUBECONFIG secret of the matching GitHub environment. The context sets the
# namespace, which the CI scripts deploy to. Run it with administrator access to the
# cluster, whose API server address must be reachable from the GitHub runners.
# Usage: deploy/examples/ci-kubeconfig.sh NAMESPACE > kubeconfig
#        gh secret set KUBECONFIG --env <environment> < kubeconfig
# Rotation: delete the Secret odoo-deploy-token, apply ci-access.yaml again, then update
# the GitHub secret.
set -euo pipefail
namespace="${1:?usage: ci-kubeconfig.sh NAMESPACE}"
secret=odoo-deploy-token
for _ in $(seq 1 30); do
    token="$(kubectl -n "$namespace" get secret "$secret" -o jsonpath='{.data.token}' 2>/dev/null || true)"
    [ -n "$token" ] && break
    sleep 1
done
[ -n "$token" ] || {
    echo "ci-kubeconfig: no token in $namespace/$secret (apply ci-access.yaml first)" >&2
    exit 1
}
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
ca="$(kubectl -n "$namespace" get secret "$secret" -o jsonpath='{.data.ca\.crt}')"
cat <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: cluster
    cluster:
      server: $server
      certificate-authority-data: $ca
users:
  - name: odoo-deploy
    user:
      token: $(base64 -d <<<"$token")
contexts:
  - name: odoo-deploy
    context: {cluster: cluster, user: odoo-deploy, namespace: $namespace}
current-context: odoo-deploy
KUBECONFIG
