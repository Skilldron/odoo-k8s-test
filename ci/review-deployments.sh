#!/usr/bin/env bash
# Removes the GitHub deployments of a removed review app: those of the environment review
# whose ref is the branch of the pull request. GitHub keeps them active otherwise, with
# the URL of the app. A deployment must be inactive before it can be deleted.
# Usage: ci/review-deployments.sh N
# Env: GH_TOKEN (deployments: write, pull-requests: read), GITHUB_REPOSITORY,
#      DRY_RUN=true (print only)
set -euo pipefail

number="${1:?usage: ci/review-deployments.sh N}"
[[ "$number" =~ ^[0-9]+$ ]] || {
    echo "review-deployments: N must be a pull request number: $number" >&2
    exit 1
}
repo="repos/$GITHUB_REPOSITORY"
branch="$(gh api "$repo/pulls/$number" --jq .head.ref)"
ids="$(gh api -X GET --paginate "$repo/deployments" -f environment=review -f ref="$branch" \
    -f per_page=100 --jq '.[].id')"

removed=0
for id in $ids; do
    if [ "${DRY_RUN:-}" = true ]; then
        echo "review-deployments: would delete deployment $id ($branch)"
        continue
    fi
    gh api -X POST "$repo/deployments/$id/statuses" -f state=inactive >/dev/null
    gh api -X DELETE "$repo/deployments/$id"
    removed=$((removed + 1))
done
echo "review-deployments: $removed deployment(s) of pull request $number ($branch) deleted${DRY_RUN:+ (dry run)}"
