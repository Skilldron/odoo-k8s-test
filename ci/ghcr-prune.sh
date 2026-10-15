#!/usr/bin/env bash
# Deletes versions of a GHCR package through the GitHub API. Only for the disposable
# packages (builds, base); the release package is never pruned.
#
# Usage: ci/ghcr-prune.sh PACKAGE RULE
#   PACKAGE           package name, e.g. myrepo/builds
#   RULE  tag:<TAG>   delete the versions carrying TAG (preview of a closed pull request)
#         keep:<N>[:<REGEX>]
#                     delete untagged versions, keep the N most recent tagged ones and
#                     those with a tag matching REGEX, delete the others
# Env:   GH_TOKEN (packages: write), OWNER (default: owner of $GITHUB_REPOSITORY),
#        DRY_RUN=true (list only), VERSIONS_FILE (JSON lines instead of the API, tests)
set -euo pipefail

package="${1:?usage: ci/ghcr-prune.sh PACKAGE RULE}"
rule="${2:?usage: ci/ghcr-prune.sh PACKAGE RULE}"
encoded="${package//\//%2F}"

if [ -n "${VERSIONS_FILE:-}" ]; then
    versions="$(cat "$VERSIONS_FILE")"
    api=""
else
    owner="${OWNER:-${GITHUB_REPOSITORY%%/*}}"
    if [ "$(gh api "users/$owner" --jq .type)" = Organization ]; then
        api="orgs/$owner/packages/container/$encoded/versions"
    else
        api="users/$owner/packages/container/$encoded/versions"
    fi
    versions="$(gh api --paginate "$api?per_page=100" \
        --jq '.[] | {id, created_at, tags: .metadata.container.tags} | @json')"
fi

# One line per version to delete: "<id> <tags>"
to_delete="$(printf '%s\n' "$versions" | python3 -c '
import json, re, sys
rule = sys.argv[1]
versions = [json.loads(line) for line in sys.stdin if line.strip()]
versions.sort(key=lambda v: v["created_at"], reverse=True)
if rule.startswith("tag:"):
    tag = rule[4:]
    doomed = [v for v in versions if tag in v["tags"]]
elif rule.startswith("keep:"):
    count, _, pattern = rule[5:].partition(":")
    protected = re.compile(pattern) if pattern else None
    tagged = [v for v in versions if v["tags"]]
    keep = {v["id"] for v in tagged[: int(count)]}
    if protected:
        keep |= {v["id"] for v in tagged if any(protected.fullmatch(t) for t in v["tags"])}
    doomed = [v for v in versions if v["id"] not in keep]
else:
    sys.exit(f"unknown rule: {rule}")
for v in doomed:
    print(v["id"], ",".join(v["tags"]) or "untagged")
' "$rule")"

if [ -z "$to_delete" ]; then
    echo "$package: nothing to delete."
    exit 0
fi
while read -r id tags; do
    if [ "${DRY_RUN:-false}" = true ] || [ -z "$api" ]; then
        echo "would delete $package version $id ($tags)"
    else
        gh api --method DELETE "$api/$id" >/dev/null
        echo "deleted $package version $id ($tags)"
    fi
done <<<"$to_delete"
