#!/usr/bin/env bash
# Publishes the base image (official Odoo + venv + OCA modules) as <IMAGE>/base:<key>
# when the registry does not have it yet. Every build then starts from it and only adds
# the project modules (ci/image-build.sh).
#
# Env:     IMAGE (required, release package, e.g. ghcr.io/org/repo),
#          CACHE_FROM / CACHE_TO (optional buildx cache, e.g. type=gha)
# Outputs: base=<IMAGE>/base:<key> (stdout and $GITHUB_OUTPUT)
# Usage:   ci/base-ensure.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IMAGE:?IMAGE is required, e.g. ghcr.io/org/repo}"
base="$IMAGE/base:$(ci/base-key.sh)"

if docker buildx imagetools inspect "$base" >/dev/null 2>&1; then
    echo "Base $base already published."
else
    cache_args=()
    [ -n "${CACHE_FROM:-}" ] && cache_args+=(--cache-from "$CACHE_FROM")
    [ -n "${CACHE_TO:-}" ] && cache_args+=(--cache-to "$CACHE_TO")
    # Single manifest (no attestation): untagged versions in the registry are then only
    # superseded images, which the cleanup can delete safely
    docker buildx build --push --provenance=false --sbom=false --target base \
        ${cache_args[@]+"${cache_args[@]}"} -f docker/Dockerfile -t "$base" .
fi

echo "base=$base"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "base=$base" >>"$GITHUB_OUTPUT"
fi
