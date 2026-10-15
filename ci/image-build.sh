#!/usr/bin/env bash
# Builds the prod and test images of the current git tree, unless the registry already
# holds the prod image of this tree (tag tree-<hash>). That image was built and tested by
# an earlier run on the same content (e.g. release/x.y.z merged into main with --no-ff)
# and is reused as is: one image per version, never rebuilt.
#
# Env:     IMAGE (required, e.g. ghcr.io/org/repo), VERSION (label, default: commit),
#          CACHE_FROM / CACHE_TO (optional buildx cache, e.g. type=gha)
# Outputs: tree=<hash>, reused=true|false (stdout and $GITHUB_OUTPUT)
# Usage:   ci/image-build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IMAGE:?IMAGE is required, e.g. ghcr.io/org/repo}"
tree="$(git rev-parse 'HEAD^{tree}')"
revision="$(git rev-parse HEAD)"
ref="$IMAGE:tree-$tree"

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: uncommitted changes are built but not part of tree $tree" >&2
fi

if docker buildx imagetools inspect "$ref" >/dev/null 2>&1; then
    reused=true
    echo "Reusing $ref (already built and tested)."
else
    reused=false
    cache_args=()
    [ -n "${CACHE_FROM:-}" ] && cache_args+=(--cache-from "$CACHE_FROM")
    [ -n "${CACHE_TO:-}" ] && cache_args+=(--cache-to "$CACHE_TO")
    for target in prod test; do
        tag="$ref"
        [ "$target" = test ] && tag="$ref-test"
        docker buildx build --load --target "$target" \
            --build-arg VERSION="${VERSION:-$revision}" --build-arg REVISION="$revision" \
            ${cache_args[@]+"${cache_args[@]}"} -f docker/Dockerfile -t "$tag" .
    done
fi

echo "tree=$tree"
echo "reused=$reused"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "tree=$tree"
        echo "reused=$reused"
    } >>"$GITHUB_OUTPUT"
fi
