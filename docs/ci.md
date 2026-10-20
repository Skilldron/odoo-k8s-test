# CI and production image

The CI (GitHub Actions, GitHub-hosted runners) checks the code, builds the **production
image**, tests it and publishes it to GHCR. In this branch, it then **deploys** it to
Kubernetes with the [Odoo Helm chart](https://github.com/Skilldron/odoo-helm-chart)
([deployment.md](deployment.md)). Branching model: [gitflow.md](gitflow.md).

## Pipeline

Four groups of jobs (reusable workflows called by `.github/workflows/ci.yml`):

```
Quality     quality.yml   lint (pre-commit), chart (ci/values-lint.sh)
Image       image.yml     plan ─► base ─► build ─┬─► tests ─┐
                                                 └─► smoke ─┴─► publish
                          (pull request from a fork: a single "local" job, nothing published)
Promotion   promote.yml   tag vX.Y.Z: last X.Y.Z-rc.N ─► X.Y.Z
Deployment  deploy.yml    deploy ─► restore (when deploy fails, persistent environments)
                          called by the review, staging, preprod and production jobs
```

| Job       | Role                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------- |
| `plan`    | Tags to publish for the event; refuses a `release/` or `hotfix/` branch that is not `X.Y.Z`                 |
| `base`    | Publishes `base:<key>` when it does not exist yet (about once a week)                                       |
| `build`   | Builds only the modules on top of `base:<key>`, pushes `builds:run-<id>` (+ `-test`)                        |
| `tests`   | Tests of the `addons/` modules + coverage, on the image pulled from the registry                            |
| `smoke`   | Production image, read-only, no capabilities: `/web/health`, `/web/login`, non-root uid                     |
| `publish` | After the tests **and** the smoke test: adds the readable tags (same digest); output `digest`               |
| `promote` | On a git tag: promotes the last release candidate; output `digest`                                          |
| `chart`   | Deployment values against the pinned chart, no cluster (`ci/values-lint.sh`, pinned Helm 4 and kubeconform) |

Other workflows:

| Workflow                                | Trigger                            | Role                                                    |
| --------------------------------------- | ---------------------------------- | ------------------------------------------------------- |
| `.github/workflows/cleanup.yml`         | pull request closed, daily, manual | Cleans up the `builds` and `base` packages, review apps |
| `.github/workflows/odoo-image-bump.yml` | Monday 5:00, manual                | Pull request when the official image changes            |
| `.github/dependabot.yml`                | weekly                             | Update pull requests (actions, pip, npm)                |

## Base image: only the modules are rebuilt

`base:<key>` holds the pinned official `odoo:20.0` image, the venv and the OCA modules
of `requirements.txt`. Its key (`ci/base-key.sh`) is a hash of `docker/Dockerfile` and
`requirements.txt`: it changes only with a new Odoo image, an OCA module or a change to
the Dockerfile.

The `build` job replaces the `base` stage of the Dockerfile with this image
(`--build-context base=docker-image://…/base:<key>`): it runs only the `prod` (copy of
the modules) and `test` stages, and pushes only those layers, a few MB.

What it does not avoid: to run the tests and the smoke test, the runner needs the
**whole** image. GitHub-hosted runners are ephemeral, so the `tests` and `smoke` jobs
pull it from GHCR on every run (GitHub network, no Docker Hub limit). Only a self-hosted
runner with a persistent Docker cache would avoid this download.

## GHCR packages and tags

| Package                       | Tags                                                                           | Lifetime             |
| ----------------------------- | ------------------------------------------------------------------------------ | -------------------- |
| `ghcr.io/<org>/<repo>/base`   | `<key>`                                                                        | last 5 versions      |
| `ghcr.io/<org>/<repo>/builds` | `run-<id>-<attempt>` (transit), `pr-<n>`, `develop`, `main`, `20.0`, `sha-<7>` | disposable (cleanup) |
| `ghcr.io/<org>/<repo>`        | `X.Y.Z-rc.N`, `X.Y.Z`                                                          | kept                 |

| Event                | Published tags                      | Intended environment |
| -------------------- | ----------------------------------- | -------------------- |
| pull request         | `builds:pr-<n>`                     | review               |
| push `develop`       | `builds:develop`, `builds:sha-<7>`  | —                    |
| push `main`, `20.0`  | `builds:<branch>`, `builds:sha-<7>` | —                    |
| push `release/X.Y.Z` | `X.Y.Z-rc.<run number>`             | staging              |
| push `hotfix/X.Y.Z`  | `X.Y.Z-rc.<run number>`             | preprod              |
| tag `vX.Y.Z`         | `X.Y.Z` (promotion of the last rc)  | production           |

The `N` of `-rc.N` is the CI run number: it always grows, with gaps. To deploy, prefer
the **digest** (`image@sha256:…`, shown in the job summary) to a moving tag.

## A single promotion: release candidate → production

Before the release candidate, every event rebuilds its image, which costs almost
nothing: there is still time to fix things. The one strong guarantee comes at the end:
**production receives exactly the image that was validated**.

On a `vX.Y.Z` tag, `ci/image-promote.sh`:

1. picks the release candidate `X.Y.Z-rc.N` with the highest N (`rc.63` before `rc.9`);
   fails if there is none;
2. **checks** that the rc was built from the tagged code: its label `odoo.template.tree`
   (hash of the code content, set at build time) must equal that of the tagged commit.
   Otherwise it refuses, for instance when `main` received a hotfix after the last rc:
   merge what is missing into the release, validate the new rc, then tag again;
3. adds the `X.Y.Z` tag to the digest of the rc: **same digest**, no rebuild.

Every tag copy (`builds` → release, rc → version) keeps the original digest
(`imagetools create --prefer-index=false`).

## Deployment (`deploy.yml`)

Deployments are **enabled** by the repository variable `DEPLOY_ENVIRONMENTS`, which
lists the environments to deploy (`review staging preprod production`, or some of them).
Without it, no deployment job runs: the template repository and a project without a
cluster stay green.

| Job (check)           | Trigger                                                     | Image                              |
| --------------------- | ----------------------------------------------------------- | ---------------------------------- |
| `review / deploy`     | internal pull request, not a draft, after `image`           | `builds@<digest>` of the PR        |
| `staging / deploy`    | push `release/**`, after `image`                            | `X.Y.Z-rc.N` by its digest         |
| `preprod / deploy`    | push `hotfix/**` after `image`; tag `v*` after `production` | the rc, then the production digest |
| `production / deploy` | tag `v*`, after `promote`                                   | same digest as the rc              |
| `<env> / restore`     | persistent environments, only when `deploy` failed          | —                                  |

Each job runs in the GitHub environment of the same name, whose secret `KUBECONFIG`
gives a ServiceAccount limited to one namespace. One deployment runs at a time per
environment (per pull request for review apps). The setup, the steps of a deployment and
the operations are in [deployment.md](deployment.md).

## Cleanup (`cleanup.yml`)

- When a pull request closes, the version tagged `builds:pr-<n>` is deleted, and its
  review app (`ci/review-remove.sh`, after a running deployment of the same pull
  request).
- Every night: in `builds`, untagged versions and everything beyond the 30 most recent
  are deleted, except `develop`, `main`, `20.0` and the `pr-<n>` previews (deleted when
  their pull request closes); in `base`, the last 5 are kept.
- Every night, the review apps left over from closed pull requests are removed
  (`ci/review-sweep.sh`).
- The release package is **never** cleaned up automatically.

Images are published without attestations (`--provenance=false`): each image is a single
manifest, and an untagged version is always a replaced image, safe to delete.

**GitHub prerequisite** (once, after the first push creates the packages): in the
settings of each package (`<repo>`, `<repo>/builds`, `<repo>/base`), give the repository
Actions access with the **Admin** role, needed to delete versions with `GITHUB_TOKEN`.
Private packages use the GitHub Packages storage quota: the cleanup of `builds` keeps it
low.

## `ci/` scripts

Each job is a thin layer over these scripts, which run the same way locally:

| Script                          | Role                                                                           |
| ------------------------------- | ------------------------------------------------------------------------------ |
| `ci/base-key.sh`                | Key of the base image                                                          |
| `ci/base-ensure.sh`             | Publishes `base:<key>` when missing                                            |
| `ci/image-build.sh`             | `prod` and `test` images on the base (`PUSH=true`); `BASE=local`: build it all |
| `ci/run-tests.sh <image>`       | Tests + coverage; fails on a failing test or an ERROR/CRITICAL line            |
| `ci/smoke.sh <image>`           | Hardened smoke test                                                            |
| `ci/image-tag.sh SRC DEST…`     | Adds tags (same digest), possibly in another package                           |
| `ci/image-promote.sh X.Y.Z`     | Last rc → `X.Y.Z`, with the content check                                      |
| `ci/registry-tags.py IMAGE`     | Lists the tags of an image repository (OCI API)                                |
| `ci/ghcr-prune.sh PACKAGE RULE` | Cleans up a GHCR package (`tag:<tag>` or `keep:<n>[:<regex>]`)                 |
| `ci/odoo-image-latest.sh`       | New digest of the official Odoo image, if any                                  |
| `ci/values-lint.sh`             | Deployment values against the pinned chart, modules against `addons/`          |
| `ci/chart-e2e.sh`               | Deployment scenarios on kind (local, not in CI)                                |
| `ci/deploy.sh`                  | Deploys an image to an environment                                             |
| `ci/deploy-restore.sh`          | Restores after a failed update                                                 |
| `ci/review-remove.sh`           | Removes the review app of a pull request                                       |
| `ci/review-sweep.sh`            | Removes the review apps of closed pull requests                                |

```sh
# Locally, with a throwaway registry:
docker run -d --name registry -p 5050:5000 registry:2
export IMAGE=localhost:5050/my-project
ci/base-ensure.sh
PUSH=true TAG=local-1 ci/image-build.sh
ci/run-tests.sh "$IMAGE/builds:local-1-test"
ci/smoke.sh "$IMAGE/builds:local-1"
ci/image-tag.sh "$IMAGE/builds:local-1" "$IMAGE:1.0.0-rc.1"
ci/image-promote.sh 1.0.0          # from the commit that was built
```

## Image stages (`docker/Dockerfile`)

| Stage     | Content                                                                                      |
| --------- | -------------------------------------------------------------------------------------------- |
| `runtime` | Official `odoo:20.0` image pinned by digest, user `odoo` (uid 1000), venv `/opt/venv`        |
| `builder` | `git` and build tools to install `requirements.txt` (OCA modules)                            |
| `base`    | `runtime` + the built venv, without `git`; published by the CI as `base:<key>`               |
| `dev`     | Tooling of the dev container                                                                 |
| `prod`    | `base` + `addons/`, `vendor/`, configuration by variables, `HEALTHCHECK`; the deployed image |
| `test`    | `prod` + `coverage`, for the CI only                                                         |

The `prod` image has a base pinned by digest, a non-root user, no secret in its layers,
works with `--read-only` (static configuration, nothing written at startup), and a
`HEALTHCHECK` on `/web/health`. Labels: `org.opencontainers.image.version`,
`org.opencontainers.image.revision`, `odoo.template.tree`, `odoo.version`.

## Configuration per environment

The same image serves every environment; only the configuration changes. The image holds
a static configuration without secrets, `docker/odoo.conf` (`ODOO_RC`), which only sets
what differs from Odoo's defaults. The rest comes from the environment, read by Odoo 20
itself before the file:

- each option of the file has its `ODOO_<OPTION>` variable (upper case), for instance
  `ODOO_WORKERS` for `workers`;
- the database comes from the `PG*` variables.

Nothing is rendered at startup. `docker/entrypoint.sh` only checks the required
variables, stops the container with an explicit message when one is missing, then hands
over to the official entrypoint (which waits for PostgreSQL).

Common variables:

| Variable                 | Required | Default      | Odoo option               |
| ------------------------ | -------- | ------------ | ------------------------- |
| `PGHOST`                 | yes      | —            | `db_host`                 |
| `PGPORT`                 | no       | `5432`       | `db_port`                 |
| `PGUSER`                 | yes      | —            | `db_user`                 |
| `PGPASSWORD`             | yes      | —            | `db_password` (secret)    |
| `PGDATABASE`             | yes      | —            | `db_name` (only database) |
| `ODOO_ADMIN_PASSWD`      | yes      | —            | `admin_passwd` (secret)   |
| `ODOO_WORKERS`           | no       | `2`          | `workers`                 |
| `ODOO_MAX_CRON_THREADS`  | no       | `1`          | `max_cron_threads`        |
| `ODOO_LIST_DB`           | no       | `False`      | `list_db`                 |
| `ODOO_PROXY_MODE`        | no       | `True`       | `proxy_mode`              |
| `ODOO_LIMIT_MEMORY_SOFT` | no       | `2147483648` | `limit_memory_soft`       |
| `ODOO_LIMIT_MEMORY_HARD` | no       | `2684354560` | `limit_memory_hard`       |
| `ODOO_LIMIT_TIME_CPU`    | no       | `600`        | `limit_time_cpu`          |
| `ODOO_LIMIT_TIME_REAL`   | no       | `1200`       | `limit_time_real`         |
| `ODOO_SMTP_SERVER`       | no       | `localhost`  | `smtp_server`             |
| `ODOO_SMTP_PORT`         | no       | `25`         | `smtp_port`               |
| `ODOO_SMTP_SSL`          | no       | `False`      | `smtp_ssl`                |
| `ODOO_SMTP_USER`         | no       | empty        | `smtp_user`               |
| `ODOO_SMTP_PASSWORD`     | no       | empty        | `smtp_password` (secret)  |
| `ODOO_EMAIL_FROM`        | no       | empty        | `email_from`              |
| `ODOO_LOG_LEVEL`         | no       | `info`       | `log_level`               |

Without `dbfilter`, Odoo serves only the `db_name` database. Defaults come from
`docker/odoo.conf`, or from Odoo itself for SMTP and `log_level`.

**Another configuration file**: mount your own file and point `ODOO_RC` at it
(`-e ODOO_RC=/etc/odoo/odoo.conf -v ./odoo.conf:/etc/odoo/odoo.conf:ro`), for instance
for module sections (`[queue_job]`). Secrets stay in the environment: the file holds
none, and the required variables are still required.

## Deploying it yourself

A minimal example with Docker (adapt the network, reverse proxy, backups and secrets):

```sh
IMAGE=ghcr.io/<org>/<repo>@sha256:<digest>
ENV=(-e PGHOST=db.internal -e PGUSER=odoo -e PGPASSWORD=… -e PGDATABASE=prod
     -e ODOO_ADMIN_PASSWD=… -e ODOO_WORKERS=4)

# 1. Modules, with Odoo stopped
RUN=(docker run --rm "${ENV[@]}" -v odoo-data:/var/lib/odoo "$IMAGE")
#    first installation: the project modules, then the reference hashes
"${RUN[@]}" odoo -i <modules> --stop-after-init --no-http
"${RUN[@]}" click-odoo-update --only-compute-hashes
#    new version: only the changed modules are updated
"${RUN[@]}" click-odoo-update
# 2. Start, hardened
docker run -d --name odoo "${ENV[@]}" -v odoo-data:/var/lib/odoo -p 8069:8069 -p 8072:8072 \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
    --restart unless-stopped "$IMAGE"
```

Module updates: `click-odoo-update` (package `click-odoo-contrib`, in the image)
compares the hash of each module with the one stored in the database and updates only
the changed modules, including Odoo and OCA modules after a new base image
(`--update-all` forces a full update). Stop Odoo during the update and back up right
before it: Odoo records each module as it is updated, so a failed update leaves the
database half-migrated.

Plan for: `/var/lib/odoo` (filestore) on a persistent volume, backed up with the
database; port `8072` (websocket) behind the same reverse proxy as `8069`; secrets
injected by the deployment tool, never committed; on servers, a `read:packages` token if
the packages are private.

## Dependency updates

- **Odoo image**: `odoo-image-bump.yml` opens a pull request that updates
  `ARG ODOO_IMAGE` (dated tag + digest); the CI of that pull request publishes the new
  `base:<key>`. Pull requests created with `GITHUB_TOKEN` do not trigger the CI: set the
  secret `ODOO_BUMP_TOKEN` (fine-grained personal access token or GitHub App token) to
  get it. The schedule runs only on the default branch; run the workflow by hand for
  another version branch.
- **Actions, pip, npm**: Dependabot (weekly pull requests, never merged automatically).
- **pre-commit hooks**: `pre-commit autoupdate` in the dev container, then a pull
  request.

## Following the CI

```sh
gh run list --workflow ci.yml --limit 10   # latest runs
gh run watch                               # follow the current run
gh run view <id> --log-failed              # logs of a failed job
```
