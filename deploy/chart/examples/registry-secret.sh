#!/usr/bin/env bash
# Registry Secret to pull a private image (image.pullSecrets), one per namespace.
# For GHCR: a classic personal access token with read:packages, owned by a machine account
# that can read the packages (fine-grained tokens are not accepted by GHCR). Plan its
# rotation: create the Secret again, the next pod start uses it.
# Usage: REGISTRY_USER=<user> REGISTRY_TOKEN=<token> examples/registry-secret.sh NAMESPACE [NAME]
# Env: REGISTRY (ghcr.io)
set -euo pipefail
namespace="${1:?usage: registry-secret.sh NAMESPACE [NAME]}"
name="${2:-ghcr}"
: "${REGISTRY_USER:?REGISTRY_USER is required}" "${REGISTRY_TOKEN:?REGISTRY_TOKEN is required}"
kubectl -n "$namespace" create secret docker-registry "$name" \
    --docker-server="${REGISTRY:-ghcr.io}" \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
