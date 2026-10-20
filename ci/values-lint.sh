#!/usr/bin/env bash
# Checks of the deployment values (deploy/values.yaml, deploy/values/) against the chart
# of deploy/chart.env, without a cluster: helm lint and kubeconform for each environment (installation and
# update), and the odoo.modules of each environment compared with the folders of addons/.
# The chart's own checks run in its repository. Requires helm 4 and kubeconform
# (KUBECONFORM to override the binary). Env: CHART, a local chart directory instead of
# the version of deploy/chart.env.
# Usage: ci/values-lint.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh
# shellcheck source=deploy/chart.env
source deploy/chart.env

kubeconform="${KUBECONFORM:-kubeconform}"
digest="sha256:$(printf '0123456789abcdef%.0s' 1 2 3 4)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*" >&2
    failures=$((failures + 1))
}

if [ -n "${CHART:-}" ]; then
    chart="$CHART"
else
    helm pull "$CHART_REF" --version "$CHART_VERSION" --untar --untardir "$work/chart" >/dev/null
    chart="$work/chart/odoo"
fi
echo "chart: ${CHART:-$CHART_REF $CHART_VERSION}"

render() { # render <env> [helm args...] > manifest
    local env="$1"
    shift
    local release=odoo
    [ "$env" = review ] && release=pr-1
    helm template "$release" "$chart" -f deploy/values.yaml -f "deploy/values/$env.yaml" \
        --set image.digest="$digest" "$@"
}

environments=()
for file in deploy/values/*.yaml; do
    environments+=("$(basename "$file" .yaml)")
done

# 1. helm lint and kubeconform: first installation and update of each environment
mkdir -p "$work/renders"
for env in "${environments[@]}"; do
    if helm lint --quiet "$chart" -f deploy/values.yaml -f "deploy/values/$env.yaml" \
        --set image.digest="$digest" >"$work/lint" 2>&1; then
        pass "helm lint $env"
    else
        cat "$work/lint" >&2
        fail "helm lint $env"
    fi
    render "$env" >"$work/renders/$env.yaml"
    render "$env" --is-upgrade >"$work/renders/$env-upgrade.yaml"
done
if "$kubeconform" -strict -summary -kubernetes-version 1.34.0 \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$work"/renders/*.yaml >"$work/kc" 2>&1; then
    pass "kubeconform ($(tail -1 "$work/kc"))"
else
    cat "$work/kc" >&2
    fail "kubeconform"
fi

# 2. odoo.modules of every environment matches the folders of addons/
addons="$(ci/list-addons.sh | tr , '\n' | sort)"
for env in "${environments[@]}"; do
    modules="$(sed -n 's/.*args: \[odoo, -i, \(.*\), --stop-after-init.*/\1/p' "$work/renders/$env.yaml" |
        tr -d ' ' | tr , '\n' | sort)"
    if [ "$modules" = "$addons" ]; then
        pass "odoo.modules = addons/ ($env)"
    else
        fail "odoo.modules of $env ($(paste -sd, - <<<"$modules")) differs from addons/ ($(paste -sd, - <<<"$addons"))"
    fi
done

{
    echo "### Deployment values"
    echo
    echo "- chart: \`${CHART:-$CHART_REF $CHART_VERSION}\`"
    echo "- failures: $failures"
} | ci_summary
if [ "$failures" -gt 0 ]; then
    echo "values-lint: $failures check(s) FAILED" >&2
    exit 1
fi
echo "values-lint: all checks passed."
