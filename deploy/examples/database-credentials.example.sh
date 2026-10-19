#!/usr/bin/env bash
# Secret odoo-db-credentials (§4): user and password of the role odoo, declared in the CNPG
# cluster (cnpg-cluster.values.yaml) and read by Odoo (database.external.secret). Created
# once, before the database, and kept: every restored cluster declares the same role with
# it. Any tool can produce it instead (Sealed Secrets, SOPS, External Secrets...).
# Usage: deploy/examples/database-credentials.example.sh NAMESPACE
set -euo pipefail
namespace="${1:?usage: database-credentials.example.sh NAMESPACE}"
kubectl -n "$namespace" create secret generic odoo-db-credentials \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=odoo \
    --from-literal=password="$(openssl rand -hex 24)"
