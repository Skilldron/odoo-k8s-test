#!/usr/bin/env bash
# Prints the project addons (addons/*/__manifest__.py), comma separated.
# Usage: ci/list-addons.sh [addons_dir]
set -euo pipefail

dir="${1:-addons}"
modules=()
for manifest in "$dir"/*/__manifest__.py; do
    [ -e "$manifest" ] || continue
    modules+=("$(basename "$(dirname "$manifest")")")
done
(IFS=,; echo "${modules[*]}")
