#!/usr/bin/env python3
"""List the tags of an image repository through the OCI distribution API.

Works with GHCR (token obtained with REGISTRY_USER / REGISTRY_PASSWORD, e.g. the
GITHUB_TOKEN) and with a local registry (plain http for localhost). Prints one tag per
line, nothing when the repository does not exist yet.

Usage: registry-tags.py REGISTRY/NAME      e.g. ghcr.io/org/repo
"""

import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


def fetch(url, headers):
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response), response.headers.get("Link")


def bearer_token(challenge):
    """Token for a 'Bearer realm=...,service=...,scope=...' challenge."""
    params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
    query = {k: params[k] for k in ("service", "scope") if k in params}
    url = params["realm"] + "?" + urllib.parse.urlencode(query)
    headers = {}
    user, password = (
        os.environ.get("REGISTRY_USER"),
        os.environ.get("REGISTRY_PASSWORD"),
    )
    if user and password:
        credentials = base64.b64encode(f"{user}:{password}".encode()).decode()
        headers["Authorization"] = f"Basic {credentials}"
    data, _ = fetch(url, headers)
    return data.get("token") or data["access_token"]


def list_tags(reference):
    registry, _, name = reference.partition("/")
    local = registry.split(":")[0] in ("localhost", "127.0.0.1")
    base = f"{'http' if local else 'https'}://{registry}"
    url, headers, tags = f"{base}/v2/{name}/tags/list?n=1000", {}, []
    while url:
        try:
            data, link = fetch(url, headers)
        except urllib.error.HTTPError as error:
            if error.code == 401 and "Authorization" not in headers:
                challenge = error.headers.get("WWW-Authenticate", "")
                headers["Authorization"] = f"Bearer {bearer_token(challenge)}"
                continue
            if error.code == 404:
                return tags
            raise
        tags += data.get("tags") or []
        # Pagination: Link: </v2/<name>/tags/list?last=...&n=...>; rel="next"
        match = re.match(r"<([^>]+)>", link or "")
        url = urllib.parse.urljoin(base, match.group(1)) if match else None
    return tags


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__.strip().splitlines()[-1] + "\n")
        return 2
    for tag in list_tags(argv[1]):
        sys.stdout.write(tag + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
