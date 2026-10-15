#!/usr/bin/env bash
# Publishes the prod image of the current git tree under the given tags, all pointing to
# the same digest. Pushes tree-<hash> first when this run built it (after the tests),
# otherwise the image must already be in the registry: a release tag only promotes an
# image built and tested earlier, it never rebuilds.
#
# Env:   IMAGE (required, e.g. ghcr.io/org/repo)
# Usage: ci/image-publish.sh TAG [TAG...]     e.g. ci/image-publish.sh sha-1a2b3c4 develop
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IMAGE:?IMAGE is required, e.g. ghcr.io/org/repo}"
tree="$(git rev-parse 'HEAD^{tree}')"
ref="$IMAGE:tree-$tree"

if ! docker buildx imagetools inspect "$ref" >/dev/null 2>&1; then
    if docker image inspect "$ref" >/dev/null 2>&1; then
        docker push "$ref"
    else
        echo "No image for tree $tree: it must be built and tested first (ci/image-build.sh)." >&2
        exit 1
    fi
fi

digest="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["digest"])')"
for tag in "$@"; do
    docker buildx imagetools create --tag "$IMAGE:$tag" "$IMAGE@$digest"
done

echo "Published $IMAGE@$digest as: tree-$tree $*"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Image publiée"
        echo
        echo "\`$IMAGE@$digest\`"
        echo
        # shellcheck disable=SC2016 # literal backticks (Markdown)
        echo "Tags :\`tree-$tree\` $(printf '`%s` ' "$@")"
    } >>"$GITHUB_STEP_SUMMARY"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "digest=$digest" >>"$GITHUB_OUTPUT"
fi
