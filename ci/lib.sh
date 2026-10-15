# shellcheck shell=bash
# Helpers shared by the ci/ scripts (sourced). Each run gets its own Docker network and
# a throwaway PostgreSQL, removed on exit: identical on a laptop and on GitHub Actions.

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16}"
CI_RUN_ID="ci-$$-${RANDOM}"
CI_NETWORK="$CI_RUN_ID"
CI_DB_HOST="$CI_RUN_ID-db"
CI_DB_PASSWORD="odoo-ci"
CI_CONTAINERS=("$CI_DB_HOST")
CI_VOLUMES=()

ci_cleanup() {
    docker rm -f "${CI_CONTAINERS[@]}" >/dev/null 2>&1 || true
    if [ "${#CI_VOLUMES[@]}" -gt 0 ]; then
        docker volume rm "${CI_VOLUMES[@]}" >/dev/null 2>&1 || true
    fi
    docker network rm "$CI_NETWORK" >/dev/null 2>&1 || true
}

ci_start_postgres() {
    trap ci_cleanup EXIT
    docker network create "$CI_NETWORK" >/dev/null
    docker run -d --name "$CI_DB_HOST" --network "$CI_NETWORK" \
        -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD="$CI_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    for _ in $(seq 1 60); do
        if docker exec "$CI_DB_HOST" pg_isready -U odoo -h localhost >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "PostgreSQL did not start" >&2
    return 1
}

# docker run arguments of the image contract (see docs/ci.md) for a throwaway database
ci_odoo_env() {
    # shellcheck disable=SC2034 # used by the scripts sourcing this file
    CI_ODOO_ENV=(
        --network "$CI_NETWORK"
        -e PGHOST="$CI_DB_HOST" -e PGPORT=5432 -e PGUSER=odoo
        -e PGPASSWORD="$CI_DB_PASSWORD" -e PGDATABASE="$1"
        -e ODOO_ADMIN_PASSWD=ci-admin
    )
}

# Appends Markdown (stdin) to the GitHub job summary when running on GitHub Actions
ci_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat >>"$GITHUB_STEP_SUMMARY"
    else
        cat >/dev/null
    fi
}
