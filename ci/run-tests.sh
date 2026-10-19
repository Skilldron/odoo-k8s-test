#!/usr/bin/env bash
# Runs the tests of the project addons in the test image (prod + coverage) on a
# throwaway database. Fails on a test failure (Odoo exit code) or on any ERROR /
# CRITICAL log line (e.g. a module that does not install).
# Usage: ci/run-tests.sh <test-image>
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh

image="${1:?usage: ci/run-tests.sh <test-image>}"
modules="$(ci/list-addons.sh)"
if [ -z "$modules" ]; then
    echo "No addon in addons/: nothing to test."
    exit 0
fi
tags="/${modules//,/,/}"
log="$(mktemp)"
coverage_md="$(mktemp)"

ci_start_postgres
ci_odoo_env odoo_test

echo "Testing: $modules"
set +e
docker run --rm "${CI_ODOO_ENV[@]}" -e ODOO_WORKERS=0 "$image" bash -c '
    python -m coverage run --data-file=/tmp/.coverage --source=/opt/odoo/addons \
        --omit="*/tests/*,*/__manifest__.py" /opt/venv/bin/odoo -i "$1" --test-enable --test-tags "$2" \
        --stop-after-init --log-level=test
    rc=$?
    echo "=== coverage ==="
    python -m coverage report --data-file=/tmp/.coverage --format=markdown
    exit $rc
' _ "$modules" "$tags" >"$log" 2>&1
rc=$?
set -e

sed '/^=== coverage ===$/,$d' "$log"
sed '1,/^=== coverage ===$/d' "$log" >"$coverage_md"
errors="$(sed '/^=== coverage ===$/,$d' "$log" | grep -cE ' (ERROR|CRITICAL) ' || true)"
result="$(grep -E 'failed, [0-9]+ error\(s\) of [0-9]+ tests' "$log" | tail -1 | sed 's/.*odoo.tests.result: //')"

echo
echo "Coverage:"
cat "$coverage_md"
{
    echo "### Odoo tests"
    echo
    echo "- Modules: \`$modules\`"
    echo "- Result: ${result:-no test result}"
    echo "- ERROR/CRITICAL lines: $errors"
    echo
    echo "#### Coverage"
    echo
    cat "$coverage_md"
} | ci_summary

if [ "$rc" -ne 0 ] || [ "$errors" -ne 0 ]; then
    echo "Tests FAILED (exit code $rc, $errors ERROR/CRITICAL line(s))" >&2
    exit 1
fi
echo "Tests passed."
