#!/usr/bin/env bash
# Checks whether the official Odoo image of the series pinned in docker/Dockerfile
# (ARG ODOO_IMAGE=odoo:<series>-<date>@sha256:...) has a newer digest.
# Prints the new value ("odoo:<series>-<date>@sha256:...") or nothing when up to date.
# Usage: ci/odoo-image-latest.sh
set -euo pipefail
cd "$(dirname "$0")/.."

current="$(sed -n 's/^ARG ODOO_IMAGE=//p' docker/Dockerfile)"
tag="${current#odoo:}"
tag="${tag%%@*}"
series="${tag%%-*}"

digest="$(docker buildx imagetools inspect "odoo:$series" --format '{{json .Manifest}}' |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["digest"])')"
if [ "${current##*@}" = "$digest" ]; then
    echo "odoo:$series is up to date ($tag)." >&2
    exit 0
fi

# Dated tag (<series>-YYYYMMDD) published with the same digest, from Docker Hub
dated="$(curl -fsS "https://hub.docker.com/v2/repositories/library/odoo/tags?page_size=100&name=$series-" |
    python3 -c '
import json, re, sys
digest, series = sys.argv[1], sys.argv[2]
for tag in json.load(sys.stdin)["results"]:
    if tag.get("digest") == digest and re.fullmatch(re.escape(series) + r"-\d{8}", tag["name"]):
        print(tag["name"])
        break
' "$digest" "$series")"
if [ -z "$dated" ]; then
    echo "No dated tag found for odoo:$series@$digest (yet)." >&2
    exit 1
fi
echo "odoo:$dated@$digest"
