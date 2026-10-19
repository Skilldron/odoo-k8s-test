# Official Odoo 20.0 Community
# user odoo uid 1000
# builder stage : installs requirements.txt (OCA addons from git need git, kept out of the image)
# dev stage for : developper tools (debugpy, ruff, pylint-odoo, pre-commit, node)
# prod stage : the deployed image (addons + vendor), configured at runtime ; test : prod + coverage


# Update Odoo : update the tag and add the digest (optionnal but recommanded) (docker buildx imagetools inspect odoo:20.0)

ARG ODOO_IMAGE=odoo:20.0-20260926@sha256:cdd83e8359b3e8c357895d476396c05021fed9975bf420f353bab25fcaed1533

########################################################################
FROM ${ODOO_IMAGE} AS runtime

USER root
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

# - uid/gid 1000 (instead 100/101) : match with default linux user
# - home in /home/odoo : odoo source code in /var/lib/odoo
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupmod -g 1000 odoo \
    && mkdir -p /home/odoo \
    && usermod -u 1000 -g 1000 -d /home/odoo -s /bin/bash odoo \
    && chown -R odoo:odoo /home/odoo /etc/odoo /var/lib/odoo /mnt/extra-addons

# /opt/venv/odoo-addons : stable path to the addons installed by pip (odoo.addons namespace),
# used by OdooLS (odools.toml) whatever the Python version
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv --system-site-packages /opt/venv \
    && /usr/bin/python3 -m pip freeze > /opt/venv/constraints.txt \
    && printf '[install]\nconstraint = /opt/venv/constraints.txt\n' > /opt/venv/pip.conf \
    && printf '#!/opt/venv/bin/python\nimport odoo.cli\n\nif __name__ == "__main__":\n    odoo.cli.main()\n' \
        > /opt/venv/bin/odoo \
    && chmod 755 /opt/venv/bin/odoo \
    && SITE=$(/opt/venv/bin/python -c 'import sysconfig; print(sysconfig.get_path("purelib"))') \
    && mkdir -p "$SITE/odoo/addons" \
    && ln -s "$SITE/odoo/addons" /opt/venv/odoo-addons

########################################################################
FROM runtime AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git build-essential python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

########################################################################
FROM runtime AS base

COPY --from=builder /opt/venv /opt/venv

USER odoo

########################################################################
FROM base AS dev

USER root

# Node LTS for local plugins (eslint, ...)
ARG NODE_VERSION=22.23.3
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-client sudo less vim make jq xz-utils \
        build-essential python3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && echo "odoo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/odoo \
    && NODE_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm64 || echo x64) \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE

COPY requirements-dev.txt /tmp/requirements-dev.txt
RUN pip install --no-cache-dir -r /tmp/requirements-dev.txt \
    && chown -R odoo:odoo /opt/venv

COPY --chown=odoo:odoo docker/odoo.dev.conf /etc/odoo/odoo.conf

USER odoo
WORKDIR /workspace

########################################################################
# prod: the deployed image; the release candidate validated in staging is promoted
# unchanged to production. In CI the "base" stage is the published base:<key> image.
# Environment specific values come at runtime (env variables, see docs/ci.md).
FROM base AS prod

ARG VERSION=dev
ARG REVISION=unknown
# git tree hash of the sources: checked when a release candidate is promoted (ci/image-promote.sh)
ARG TREE=unknown
LABEL org.opencontainers.image.title="odoo" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      odoo.template.tree="${TREE}" \
      odoo.version="20.0"

COPY --chown=odoo:odoo addons /opt/odoo/addons
COPY --chown=odoo:odoo vendor /opt/odoo/vendor
COPY docker/odoo.conf docker/entrypoint.sh /opt/odoo/

# Static, without secret: secrets and overrides come from the environment (ODOO_<OPTION>,
# PG*), read by Odoo itself; another file can be mounted and ODOO_RC pointed to it
ENV ODOO_RC=/opt/odoo/odoo.conf

USER odoo
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost:8069/web/health || exit 1
ENTRYPOINT ["/opt/odoo/entrypoint.sh"]
CMD ["odoo"]

########################################################################
# test: prod + coverage, used by the CI tests only (never published)
FROM prod AS test

USER root
COPY requirements-dev.txt /tmp/requirements-dev.txt
RUN grep -E '^coverage==' /tmp/requirements-dev.txt > /tmp/coverage.txt \
    && pip install --no-cache-dir -r /tmp/coverage.txt \
    && rm /tmp/requirements-dev.txt /tmp/coverage.txt
USER odoo
