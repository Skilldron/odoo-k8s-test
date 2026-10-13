# syntax=docker/dockerfile:1
#
# Odoo 20.0 Community — basée sur l'image officielle Odoo, figée par digest
#   base : image officielle + venv projet (deps Python des addons), user odoo uid 1000
#   dev  : outillage développeur (debugpy, ruff, pylint-odoo, pre-commit, node)
#   (prod: ajouté à l'étape CD)
#
# Mettre à jour Odoo : changer le tag daté ET le digest (docker buildx imagetools inspect odoo:20.0)

ARG ODOO_IMAGE=odoo:20.0-20260926@sha256:cdd83e8359b3e8c357895d476396c05021fed9975bf420f353bab25fcaed1533

########################################################################
FROM ${ODOO_IMAGE} AS base

USER root
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

# - uid/gid 1000 (au lieu de 100/101) : droits cohérents avec les bind mounts sur Linux
# - home dans /home/odoo : l'image officielle utilise /var/lib/odoo (volume de données)
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupmod -g 1000 odoo \
    && mkdir -p /home/odoo \
    && usermod -u 1000 -g 1000 -d /home/odoo -s /bin/bash odoo \
    && chown -R odoo:odoo /home/odoo /etc/odoo /var/lib/odoo /mnt/extra-addons

# Odoo et ses dépendances sont des paquets apt (PEP 668 : pip bloqué sur le Python
# système) ; les dépendances du projet vont dans un venv qui voit les paquets système.
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv --system-site-packages /opt/venv \
    && /usr/bin/python3 -m pip freeze > /opt/venv/constraints.txt \
    # pip du venv (seulement lui : pas les environnements pre-commit) respecte toujours
    # les versions apt fournies par l'image Odoo
    && printf '[install]\nconstraint = /opt/venv/constraints.txt\n' > /opt/venv/pip.conf \
    # /usr/bin/odoo utilise le Python système (sans le venv) : lanceur équivalent dans
    # le venv, prioritaire dans le PATH (aussi pour l'entrypoint officiel)
    && printf '#!/opt/venv/bin/python\nimport odoo.cli\n\nif __name__ == "__main__":\n    odoo.cli.main()\n' \
        > /opt/venv/bin/odoo \
    && chmod 755 /opt/venv/bin/odoo

COPY requirements.txt /tmp/project-requirements.txt
RUN pip install --no-cache-dir -r /tmp/project-requirements.txt

USER odoo

########################################################################
FROM base AS dev

USER root

# Node LTS récent pour l'outillage (eslint 10 exige Node >= 20.19)
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
