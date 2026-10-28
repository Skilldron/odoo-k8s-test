#!/usr/bin/env bash
# Marks the earlier GitHub deployments of a persistent environment inactive, once the
# deployment of this run succeeded: GitHub keeps them all active otherwise. They stay in
# the history. Newest first: those of later runs (waiting for approval) are skipped, the
# walk stops at the first one already inactive (done by an earlier run).
# Usage: ci/deployments-inactive.sh ENV
# Env: GH_TOKEN (deployments: write), GITHUB_REPOSITORY, GITHUB_RUN_ID, DRY_RUN=true
#      (print only)
set -euo pipefail

env="${1:?usage: ci/deployments-inactive.sh ENV}"
repo="repos/$GITHUB_REPOSITORY"
ids="$(gh api -X GET --paginate "$repo/deployments" -f environment="$env" -f per_page=100 \
    --jq '.[].id')"

current=""
count=0
for id in $ids; do
    status="$(gh api "$repo/deployments/$id/statuses?per_page=1" --jq '.[0] | "\(.state) \(.log_url)"')"
    if [ -z "$current" ]; then
        # The deployment of this run: its status links to the run
        [[ "$status" == *"/actions/runs/$GITHUB_RUN_ID/"* ]] && current="$id"
        continue
    fi
    [ "${status%% *}" != inactive ] || break
    if [ "${DRY_RUN:-}" = true ]; then
        echo "deployments-inactive: would mark deployment $id inactive (${status%% *})"
        continue
    fi
    gh api -X POST "$repo/deployments/$id/statuses" -f state=inactive >/dev/null
    count=$((count + 1))
done
[ -n "$current" ] || echo "deployments-inactive: no deployment of run $GITHUB_RUN_ID in $env" >&2
echo "deployments-inactive: $count earlier deployment(s) of $env marked inactive${DRY_RUN:+ (dry run)}"
