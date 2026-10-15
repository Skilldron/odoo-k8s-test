#!/usr/bin/env bash
# Adds references to an image already in the registry: same digest, no rebuild, possibly
# in another package (builds -> release). Prints the digest.
#
# Usage: ci/image-tag.sh SRC DEST [DEST...]
#        e.g. ci/image-tag.sh ghcr.io/org/repo/builds:run-42-1 ghcr.io/org/repo:1.2.0-rc.42
set -euo pipefail

src="${1:?usage: ci/image-tag.sh SRC DEST [DEST...]}"
shift
[ "$#" -gt 0 ] || { echo "usage: ci/image-tag.sh SRC DEST [DEST...]" >&2; exit 2; }

digest="$(docker buildx imagetools inspect "$src" --format '{{json .Manifest}}' |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["digest"])')"
repository="${src%:*}"
for dest in "$@"; do
    # --prefer-index=false: exact copy (same digest), not a new index wrapping the image
    docker buildx imagetools create --prefer-index=false --tag "$dest" "$repository@$digest"
    echo "$dest -> $digest"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Image publiée"
        echo
        echo "Digest : \`$digest\`"
        echo
        # shellcheck disable=SC2016 # literal backticks (Markdown)
        printf -- '- `%s`\n' "$@"
    } >>"$GITHUB_STEP_SUMMARY"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "digest=$digest" >>"$GITHUB_OUTPUT"
fi
