#!/usr/bin/env bash
# Application Secret of a persistent instance (secrets.existingSecret), created with
# kubectl. Any tool can produce it instead (Sealed Secrets, SOPS, External Secrets: see
# external-secret.example.yaml), with the same keys:
#   admin-passwd         master password (database manager, odoo db commands)
#   admin-user-password  password of the user admin, read once, when the first
#                        installation creates the database
#   smtp-password        optional, password of odoo.config.options.smtp_user
# Odoo reads them as environment variables; restart Odoo after a change
# (kubectl rollout restart deployment/<release>).
# Usage: examples/app-secret.example.sh NAMESPACE [NAME]
# Env: SMTP_PASSWORD (optional)
set -euo pipefail
namespace="${1:?usage: app-secret.example.sh NAMESPACE [NAME]}"
name="${2:-odoo-app}"
smtp=()
if [ -n "${SMTP_PASSWORD:-}" ]; then
    smtp=(--from-literal=smtp-password="$SMTP_PASSWORD")
fi
kubectl -n "$namespace" create secret generic "$name" \
    --from-literal=admin-passwd="$(openssl rand -hex 24)" \
    --from-literal=admin-user-password="$(openssl rand -hex 16)" \
    ${smtp[@]+"${smtp[@]}"}
echo "Secret $name created in $namespace; admin password:"
kubectl -n "$namespace" get secret "$name" -o go-template='{{index .data "admin-user-password" | base64decode}}{{"\n"}}'
