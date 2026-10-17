#!/usr/bin/env bash
# Static checks of the Helm chart (deploy/chart), without a cluster:
# helm lint and kubeconform for the three environments, the generated odoo.conf compared
# with an expected file, odoo.modules compared with addons/, and the guards of §6.3 of
# docs/plans/k8s-deployment.md (refused values, no destructive command in any render).
# Requires helm and kubeconform (KUBECONFORM to override the binary).
# Usage: ci/chart-lint.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh

chart=deploy/chart
kubeconform="${KUBECONFORM:-kubeconform}"
digest="sha256:$(printf '0123456789abcdef%.0s' 1 2 3 4)"
short="${digest#sha256:}"
short="${short:0:12}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*" >&2
    failures=$((failures + 1))
}

render() { # render <env> [helm args...] > manifest
    local env="$1"
    shift
    local release=odoo
    [ "$env" = review ] && release=pr-1
    helm template "$release" "$chart" -f "deploy/values/$env.yaml" \
        --set image.digest="$digest" "$@"
}

# 1. helm lint and kubeconform, every step of every environment
for env in review recette production; do
    if helm lint --quiet "$chart" -f "deploy/values/$env.yaml" \
        --set image.digest="$digest" >"$work/lint" 2>&1; then
        pass "helm lint $env"
    else
        cat "$work/lint" >&2
        fail "helm lint $env"
    fi
    render "$env" --set odoo.replicas=1 --set jobs.migrate.run=true >"$work/$env.yaml"
    if "$kubeconform" -strict -summary -kubernetes-version 1.34.0 \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
        "$work/$env.yaml" >"$work/kc" 2>&1; then
        pass "kubeconform $env ($(tail -1 "$work/kc"))"
    else
        cat "$work/kc" >&2
        fail "kubeconform $env"
    fi
done
render recette --set state.generation=2 --set state.filestore=fs-snap \
    --set state.databaseSecret=odoo-db-2-app >"$work/rollback.yaml"
if grep -q "name: odoo-odoo-data-2" "$work/rollback.yaml" &&
    grep -q "name: fs-snap" "$work/rollback.yaml" &&
    grep -q "name: odoo-db-2-app" "$work/rollback.yaml"; then
    pass "rollback render (filestore generation 2 from its snapshot, restored database)"
else
    fail "rollback render"
fi
render production --set jobs.dbInit.run=true >"$work/first.yaml"
# shellcheck disable=SC2016 # $(VAR) is expanded by Kubernetes, not by the shell
if grep -q 'name: odoo-db-init-1$' "$work/first.yaml" &&
    grep -qF 'args: [odoo, db, init, --password, $(ODOO_INIT_ADMIN_PASSWORD), $(PGDATABASE)]' \
        "$work/first.yaml" && grep -q 'key: admin-user-password' "$work/first.yaml"; then
    pass "first deployment render (db-init Job without demo, admin password of the application Secret)"
else
    fail "first deployment render"
fi

# 2. odoo.conf generated from deploy/chart/tests/config-values.yaml
helm template t "$chart" -f "$chart/tests/config-values.yaml" --set image.digest="$digest" \
    --show-only templates/configmap-config.yaml |
    awk '/^  odoo.conf: \|/ {f = 1; next} f {sub(/^    /, ""); print}' |
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' >"$work/odoo.conf"
if diff -u "$chart/tests/odoo.conf.expected" "$work/odoo.conf"; then
    pass "odoo.conf matches tests/odoo.conf.expected"
else
    fail "odoo.conf differs from tests/odoo.conf.expected"
fi

# 3. odoo.modules matches the folders of addons/
modules="$(grep -o 'args: \[odoo, -i, [^,]*' "$work/recette.yaml" | sed 's/.*-i, //')"
addons="$(ci/list-addons.sh)"
if [ "$(tr , '\n' <<<"$modules" | sort)" = "$(tr , '\n' <<<"$addons" | sort)" ]; then
    pass "odoo.modules = addons/ ($addons)"
else
    fail "odoo.modules ($modules) differs from addons/ ($addons)"
fi

# 4. Values refused by the schema or by the templates
refused() { # refused <description> <env> [helm args...]
    local description="$1"
    shift
    if render "$@" >/dev/null 2>"$work/err"; then
        fail "accepted: $description"
    else
        pass "refused: $description ($(grep -m1 -oE "(at '[^']*'.*|execution error.*)" "$work/err" | cut -c1-90))"
    fi
}
refused "ephemeral database in recette" recette --set database.type=ephemeral
refused "ephemeral database in production" production --set database.type=ephemeral
refused "review without ephemeral database" review --set database.type=external \
    --set database.external.secret=x
refused "database managed by the chart in recette" recette --set database.type=cnpg
refused "external database without Secret" production --set database.external.secret=
refused "production without application Secret" production --set secrets.existingSecret=
refused "password in odoo.conf" recette --set odoo.config.options.db_password=x
refused "secret in a module section" recette --set odoo.config.queue_job.http_auth_password=x
refused "option imposed by the chart" recette --set odoo.config.options.data_dir=/x
refused "SMTP overridden while Mailpit is enabled" review --set odoo.config.options.smtp_server=x
refused "option also set by secrets.env" recette --set odoo.config.queue_job.http_auth_user=u \
    --set-json 'secrets.env=[{"name":"ODOO_QUEUE_JOB_HTTP_AUTH_USER","secret":"s","key":"k"}]'
refused "image referenced by tag" recette --set image.digest=latest
refused "restored state in review" review --set state.filestore=x
refused "db-init Job in review" review --set jobs.dbInit.run=true

# 5. No destructive command in any render; reviews only reset through their volumes
if grep -nEw 'dropdb|rm' "$work"/*.yaml || grep -nE 'DROP DATABASE|--force' "$work"/*.yaml; then
    fail "destructive command in a render"
else
    pass "no dropdb, DROP DATABASE, rm or --force in any render"
fi
for env in recette production; do
    if grep -q 'name: db-init' "$work/$env.yaml" ||
        grep -qE "(claimName: |name: ).*-(pgdata|odoo-data)-$short" "$work/$env.yaml"; then
        fail "$env: db-init step or volume named after the digest"
    else
        pass "$env: no db-init step, no volume named after the digest"
    fi
done
if grep -q 'name: db-init' "$work/review.yaml" && grep -q "pgdata-$short" "$work/review.yaml"; then
    pass "review: db-init step and volumes named after the digest"
else
    fail "review: db-init step or digest volumes missing"
fi

{
    echo "### Chart Helm"
    echo
    echo "- échecs : $failures"
} | ci_summary
if [ "$failures" -gt 0 ]; then
    echo "chart-lint: $failures check(s) FAILED" >&2
    exit 1
fi
echo "chart-lint: all checks passed."
