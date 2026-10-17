#!/usr/bin/env bash
# Nightly sweep of the review apps (§3.1 of docs/plans/k8s-deployment.md): removes those of
# the pull requests that are no longer open (closed or merged), missed by the cleanup job.
# Only the releases pr-<n> of the namespace are considered.
# Usage: ci/review-sweep.sh
# Env: NAMESPACE (default: namespace of the kubeconfig context), GH_TOKEN and
#      GITHUB_REPOSITORY (GitHub API), DRY_RUN=true (print only),
#      PR_STATES_FILE (lines "<number> <open|closed>" instead of the API, tests)
set -euo pipefail
cd "$(dirname "$0")/.."

namespace="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}')}"
[ -n "$namespace" ] || {
    echo "review-sweep: no namespace (NAMESPACE or the kubeconfig context)" >&2
    exit 1
}

pr_state() { # pr_state <number> → open | closed
    if [ -n "${PR_STATES_FILE:-}" ]; then
        awk -v n="$1" '$1 == n {print $2; found = 1} END {if (!found) print "closed"}' \
            "$PR_STATES_FILE"
    else
        gh api "repos/$GITHUB_REPOSITORY/pulls/$1" --jq .state
    fi
}

removed=0
for release in $(helm list -n "$namespace" -q --filter '^pr-[0-9]+$'); do
    number="${release#pr-}"
    if ! state="$(pr_state "$number")"; then
        echo "review-sweep: $release kept (state of the pull request unknown)"
        continue
    fi
    if [ "$state" = open ]; then
        echo "review-sweep: $release kept (pull request open)"
        continue
    fi
    echo "review-sweep: $release, pull request $state"
    NAMESPACE="$namespace" ci/review-remove.sh "$number"
    removed=$((removed + 1))
done
echo "review-sweep: $removed review app(s) removed${DRY_RUN:+ (dry run)}"
