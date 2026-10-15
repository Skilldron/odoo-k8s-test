#!/usr/bin/env bash
# Builds the prod and test images. By default on top of the published base image
# (<IMAGE>/base:<key>, see ci/base-ensure.sh): the "base" stage is replaced by that image,
# so only the project modules are built. BASE=local builds everything from the official
# image instead (pull requests from forks, which cannot use the registry).
#
# Env:     IMAGE (required, release package, e.g. ghcr.io/org/repo)
#          TAG (required): images <IMAGE>/builds:<TAG> (prod) and <TAG>-test
#          PUSH=true: push to the registry; otherwise (default) load into local Docker
#          BASE: base image (default <IMAGE>/base:<key>), "local" = build it here
#          VERSION: image label (default: commit)
#          CACHE_FROM / CACHE_TO: buildx cache, used with BASE=local
# Outputs: prod=<ref>, test=<ref> (stdout and $GITHUB_OUTPUT)
# Usage:   ci/image-build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IMAGE:?IMAGE is required, e.g. ghcr.io/org/repo}"
: "${TAG:?TAG is required, e.g. run-123-1}"
base="${BASE:-$IMAGE/base:$(ci/base-key.sh)}"
revision="$(git rev-parse HEAD)"
tree="$(git rev-parse 'HEAD^{tree}')"
prod="$IMAGE/builds:$TAG"
test="$IMAGE/builds:$TAG-test"

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: uncommitted changes are built but not part of tree $tree" >&2
fi

args=(-f docker/Dockerfile --provenance=false --sbom=false
    --build-arg VERSION="${VERSION:-$revision}" --build-arg REVISION="$revision"
    --build-arg TREE="$tree")
if [ "$base" = local ]; then
    [ -n "${CACHE_FROM:-}" ] && args+=(--cache-from "$CACHE_FROM")
    [ -n "${CACHE_TO:-}" ] && args+=(--cache-to "$CACHE_TO")
else
    args+=(--build-context "base=docker-image://$base")
fi
if [ "${PUSH:-false}" = true ]; then
    args+=(--push)
else
    args+=(--load)
fi

docker buildx build "${args[@]}" --target prod -t "$prod" .
docker buildx build "${args[@]}" --target test -t "$test" .

echo "prod=$prod"
echo "test=$test"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "prod=$prod"
        echo "test=$test"
    } >>"$GITHUB_OUTPUT"
fi
