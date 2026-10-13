# syntax=docker/dockerfile:1
#
# Odoo 20.0 Community — image multi-stage
#   builder : compile le virtualenv Python (deps Odoo + deps projet)
#   base    : runtime minimal (sources Odoo + venv), socle commun dev / prod
#   dev     : outillage développeur (debugpy, ruff, pylint-odoo, pre-commit, node)
#   (prod   : ajouté à l'étape CD)

ARG UBUNTU_VERSION=24.04

########################################################################
FROM ubuntu:${UBUNTU_VERSION} AS builder

# Commit Odoo 20.0 figé pour des builds reproductibles. Mettre à jour volontairement.
ARG ODOO_COMMIT=d1597b052b0eff61faf69a5b7e70d18130a9eaa0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates git \
        python3 python3-dev python3-venv \
        libpq-dev libldap2-dev libsasl2-dev libxml2-dev libxslt1-dev \
        libjpeg-dev zlib1g-dev libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Sources Odoo Community, embarquées dans l'image
RUN git init -q /opt/odoo \
    && git -C /opt/odoo remote add origin https://github.com/odoo/odoo.git \
    && git -C /opt/odoo fetch -q --depth 1 origin "${ODOO_COMMIT}" \
    && git -C /opt/odoo checkout -q FETCH_HEAD \
    && rm -rf /opt/odoo/.git

RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN pip install --no-cache-dir --upgrade pip wheel \
    && pip install --no-cache-dir -r /opt/odoo/requirements.txt \
    # rend `import odoo` disponible (pylint, pylance, pytest, shell)
    && python -c "import site; open(site.getsitepackages()[0] + '/odoo.pth', 'w').write('/opt/odoo\n')"

# Dépendances Python spécifiques aux addons du projet
COPY requirements.txt /tmp/project-requirements.txt
RUN pip install --no-cache-dir -r /tmp/project-requirements.txt -c /opt/odoo/requirements.txt

########################################################################
FROM ubuntu:${UBUNTU_VERSION} AS base

ARG WKHTMLTOX_VERSION=0.12.6.1-3
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH \
    ODOO_RC=/etc/odoo/odoo.conf

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
        python3 python3-venv \
        libpq5 libldap2 libsasl2-2 libxml2 libxslt1.1 libjpeg-turbo8 libmagic1 \
        fonts-noto-cjk fonts-dejavu-core fonts-inconsolata fonts-font-awesome \
        fonts-roboto-unhinted gsfonts xfonts-75dpi xfonts-base \
        postgresql-client nodejs npm \
    && curl -fsSL -o /tmp/wkhtmltox.deb \
        "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/wkhtmltox_${WKHTMLTOX_VERSION}.jammy_${TARGETARCH}.deb" \
    && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
    && npm install -g rtlcss \
    && rm -rf /tmp/wkhtmltox.deb /var/lib/apt/lists/* /root/.npm

# L'image ubuntu fournit un user `ubuntu` (uid 1000) : on le remplace par `odoo`
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd --create-home --uid 1000 --shell /bin/bash odoo \
    && mkdir -p /etc/odoo /var/lib/odoo /mnt/extra-addons \
    && chown -R odoo:odoo /etc/odoo /var/lib/odoo /mnt/extra-addons

COPY --from=builder /opt/odoo /opt/odoo
COPY --from=builder /opt/venv /opt/venv

EXPOSE 8069 8072

########################################################################
FROM base AS dev

# Node LTS récent pour l'outillage (eslint 10 exige Node >= 20.19)
ARG NODE_VERSION=22.23.3
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-client sudo less vim make jq xz-utils \
        build-essential python3-dev libpq-dev \
    && rm -rf /var/lib/apt/lists/* \
    && echo "odoo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/odoo \
    && NODE_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm64 || echo x64) \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE

COPY requirements-dev.txt /tmp/requirements-dev.txt
# Les versions figées par Odoo servent de contraintes : l'outillage ne doit pas les modifier
RUN pip install --no-cache-dir -r /tmp/requirements-dev.txt -c /opt/odoo/requirements.txt \
    && chown -R odoo:odoo /opt/venv

COPY docker/odoo.dev.conf /etc/odoo/odoo.conf
RUN chown odoo:odoo /etc/odoo/odoo.conf

USER odoo
WORKDIR /workspace
