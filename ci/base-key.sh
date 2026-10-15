#!/usr/bin/env bash
# Key of the base image (<IMAGE>/base:<key>): changes only with docker/Dockerfile or
# requirements.txt (new official Odoo image, OCA module, Dockerfile step), so the base
# is rebuilt about once a week and every other build only adds the project modules.
# Usage: ci/base-key.sh
set -euo pipefail
cd "$(dirname "$0")/.."

cat docker/Dockerfile requirements.txt |
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])'
