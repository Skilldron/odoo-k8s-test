#!/usr/bin/env bash
# Smoke test of the prod image, run hardened like a production container (read-only
# root filesystem, all capabilities dropped, no privilege escalation):
# initializes a throwaway database, starts Odoo, then checks /web/health,
# /web/login and that the process does not run as root.
# Usage: ci/smoke.sh <prod-image>
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh

image="${1:?usage: ci/smoke.sh <prod-image>}"
app="$CI_RUN_ID-odoo"
data="$CI_RUN_ID-data"
CI_CONTAINERS+=("$app")
CI_VOLUMES+=("$data")

ci_start_postgres
ci_odoo_env odoo_smoke
hardening=(--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true
    -v "$data:/var/lib/odoo")

echo "Initializing the database..."
init_log="$(mktemp)"
if ! docker run --rm "${CI_ODOO_ENV[@]}" "${hardening[@]}" "$image" \
    odoo -i base --stop-after-init --no-http >"$init_log" 2>&1; then
    tail -50 "$init_log" >&2
    echo "Smoke test FAILED: database initialization" >&2
    exit 1
fi

echo "Starting Odoo..."
docker run -d --name "$app" "${CI_ODOO_ENV[@]}" "${hardening[@]}" "$image" >/dev/null

check() {
    docker exec "$app" curl -fsS -o /dev/null -w '%{http_code}' "http://localhost:8069$1"
}
health=""
for _ in $(seq 1 60); do
    health="$(check /web/health 2>/dev/null || true)"
    [ "$health" = 200 ] && break
    sleep 2
done
login="$(check /web/login || true)"
uid="$(docker exec "$app" id -u)"

echo "/web/health: $health, /web/login: $login, uid: $uid"
{
    echo "### Smoke test (hardened production image)"
    echo
    echo "- \`/web/health\`: $health"
    echo "- \`/web/login\`: $login"
    echo "- process uid: $uid"
} | ci_summary

if [ "$health" != 200 ] || [ "$login" != 200 ] || [ "$uid" = 0 ]; then
    echo "Smoke test FAILED" >&2
    docker logs --tail 50 "$app" >&2
    exit 1
fi
echo "Smoke test passed."
