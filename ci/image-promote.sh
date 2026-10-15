#!/usr/bin/env bash
# Promotes the last release candidate X.Y.Z-rc.N to X.Y.Z: same digest, no rebuild. This
# is the only promotion: what goes to production is exactly what was validated in recette.
# Refused when the candidate was not built from exactly the tagged sources (label
# odoo.template.tree != tree of HEAD), e.g. main received a hotfix after the last rc.
#
# Env:   IMAGE (required, release package, e.g. ghcr.io/org/repo),
#        REGISTRY_USER / REGISTRY_PASSWORD (registry API, e.g. GITHUB_TOKEN on GHCR)
# Usage: ci/image-promote.sh X.Y.Z
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IMAGE:?IMAGE is required, e.g. ghcr.io/org/repo}"
version="${1:?usage: ci/image-promote.sh X.Y.Z}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version '$version' is not X.Y.Z (SemVer)." >&2
    exit 1
fi

rc="$(ci/registry-tags.py "$IMAGE" | python3 -c '
import re, sys
version = sys.argv[1]
numbers = [int(m.group(1)) for line in sys.stdin
           if (m := re.fullmatch(re.escape(version) + r"-rc\.(\d+)", line.strip()))]
print(f"{version}-rc.{max(numbers)}" if numbers else "")
' "$version")"
if [ -z "$rc" ]; then
    echo "No release candidate $version-rc.N in $IMAGE: push release/$version or" \
        "hotfix/$version first, validate it in recette, then tag." >&2
    exit 1
fi

expected="$(git rev-parse 'HEAD^{tree}')"
built="$(docker buildx imagetools inspect "$IMAGE:$rc" --format '{{json .Image}}' |
    python3 -c '
import json, sys
image = json.load(sys.stdin)
if "config" not in image:  # multi-platform index: platform -> image
    image = next(iter(image.values()))
print((image["config"].get("Labels") or {}).get("odoo.template.tree", ""))
')"
if [ "$built" != "$expected" ]; then
    {
        echo "Refused: $rc was not built from the tagged sources."
        echo "  tree of the tag : $expected"
        echo "  tree of $rc : ${built:-none}"
        echo "The tagged commit differs from the last release candidate (e.g. a hotfix"
        echo "merged into main but not into the release). Merge what is missing into the"
        echo "release/hotfix branch, validate the new rc in recette, then tag again."
    } >&2
    exit 1
fi

echo "Promoting $IMAGE:$rc -> $IMAGE:$version"
ci/image-tag.sh "$IMAGE:$rc" "$IMAGE:$version"
