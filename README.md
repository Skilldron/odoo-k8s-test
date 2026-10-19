# Odoo 20.0 Community — template repository

A template repository to develop Odoo addons in a VS Code **dev container**, with the
debugger, the Odoo language server, lint and formatting ready to use, and a CI that
builds, tests and publishes a hardened production image.

One branch per Odoo version (`20.0`, `19.0`, …), same layout.

## Getting started

Requirements: Docker, VS Code and the _Dev Containers_ extension.

1. Open the folder in VS Code → **Reopen in Container**.
2. Run **Odoo: server** (F5) → <http://localhost:8069>, database `odoo20` by default.
3. Mail sent by Odoo shows up in Mailpit: <http://localhost:8025>.

Without VS Code: `docker compose up -d`, then `docker compose exec odoo odoo -d odoo20`.

## What the environment provides

| Need        | Tool                                                                  |
| ----------- | --------------------------------------------------------------------- |
| Image       | `docker/Dockerfile`, based on the official `odoo:20.0` image (pinned) |
| Services    | `compose.yaml`: Odoo, PostgreSQL 18, Mailpit                          |
| Odoo LSP    | `Odoo.odoo` extension (OdooLS), configured by `odools.toml`           |
| Python      | Pylance + ruff (lint, format, import sorting on save)                 |
| Debugger    | debugpy, configurations in `.vscode/launch.json`                      |
| Odoo lint   | pylint-odoo (`.pylintrc`), `oca-checks-odoo-module`                   |
| XML / JS    | prettier + `@prettier/plugin-xml`, eslint (`eslint.config.mjs`)       |
| Git hooks   | pre-commit (`.pre-commit-config.yaml`), the same locally and in CI    |
| Database UI | SQLTools (connection "Odoo DB" preconfigured)                         |

## Daily use

- **Debug**: F5 → _Odoo: server_, _Odoo: update a module_, _Odoo: test a module_, _Odoo:
  shell_. Odoo runs with `workers = 0` so that breakpoints are reliable.
- **Auto-reload without the debugger**: task _Odoo: run (auto-reload, no debugger)_.
- **Tests**: task or debug configuration _Odoo: test a module_ (database `odoo20_test`).
- **Quality**: the hooks run on every commit; `pre-commit run --all-files` checks the
  whole repository.

## Layout

```
.devcontainer/   dev container configuration
.github/         GitHub Actions workflows (CI, Odoo image updates), Dependabot
.vscode/         debug configurations (launch.json) and tasks
addons/          project addons (dev_sample is a sample module, delete it)
vendor/          purchased modules (Odoo Apps Store), unmodified
ci/              CI scripts, runnable locally
docker/          multi-stage Dockerfile, dev configuration, production configuration
docs/            CI and production image, branching model
requirements.txt        Python dependencies of the addons, OCA modules
requirements-dev.txt    developer tooling (dev image only)
```

## CI and production image

On every pull request and push, GitHub Actions runs pre-commit, builds the **production
image** (`prod` stage of the Dockerfile) on top of a published base image (`base:<key>`:
Odoo + OCA modules, rebuilt only when the Dockerfile or `requirements.txt` changes),
tests it (tests of the `addons/` modules, hardened smoke test) and publishes it to GHCR.
Builds (pull request previews, `develop`…) go to a disposable package, release
candidates and versions to the release package. The only promotion turns the last
`X.Y.Z-rc.N`, once validated, into `X.Y.Z` (same image) when `vX.Y.Z` is tagged. Each
environment configures the image with environment variables.

Deployment is not part of this branch: see the `20.0-docker-deployment` and
`20.0-k8s-deployment` branches, or deploy the image yourself.

- [docs/ci.md](docs/ci.md): pipeline, image tags, configuration variables, deployment
  example.
- [docs/gitflow.md](docs/gitflow.md): recommended Git Flow for projects, release cycle,
  branch protection.

## Third-party modules

| Origin          | Where                              | CI lint / tests |
| --------------- | ---------------------------------- | --------------- |
| Project         | `addons/`                          | yes             |
| Odoo Apps Store | `vendor/` (see `vendor/README.md`) | no              |
| OCA             | `requirements.txt` (pip)           | no              |

Odoo looks for modules in this order: `addons` → `vendor` → modules installed by pip →
core.

### OCA modules (pip)

OCA modules are the pip packages `odoo-addon-<module>`, installed in `/opt/venv` when
the image is built: the same mechanism in development, CI and production, with no `.git`
in the image. Odoo finds them without changing `addons_path` (namespace `odoo.addons`),
and OdooLS through `/opt/venv/odoo-addons` (`odools.toml`). pip resolves the OCA and
Python dependencies of the module, constrained by the apt versions of the image.

1. Add the line to `requirements.txt`, with a **pinned version**:
   - published on PyPI: `odoo-addon-<module>==20.0.x.y.z`;
   - not yet published for 20.0:
     `odoo-addon-<module> @ git+https://github.com/OCA/<repo>@<sha>#subdirectory=<module>`
     (a commit sha, not a branch). Unpublished OCA dependencies must be listed too.
2. Add the module to the `depends` of your module's manifest.
3. _Dev Containers: Rebuild Container_, then install the module (`-i <module>`).

Once the module is on PyPI, replace the `git+…` line with `==version`.

**Fixing or debugging an OCA module**: the code is in the venv
(`/opt/venv/odoo-addons/<module>`), and breakpoints work there. To change it, clone the
repository into `third-party/` (ignored by git) and install it as editable:

```sh
git clone -b 20.0 https://github.com/OCA/<repo> third-party/<repo>
pip install -e third-party/<repo>/<module>
```

Odoo then uses the clone. For OdooLS to see it too, add `"third-party/<repo>"` to
`addons_paths` in `odools.toml` (do not commit it). The editable install lasts until the
next rebuild. Submit the fix to the OCA, then pin `requirements.txt` to the sha of the
pull request or of a fork in your organization (the sha of an unmerged pull request can
disappear).

## Odoo 20.0 specifics

- Python 3.12 to 3.14, PostgreSQL 16 or later.
- Access rights: `security/ir.access.csv` (columns
  `id,name,model_id,group_id/id,operation,domain`, `model_id` = technical model name,
  `operation` = `crud`) replaces `ir.model.access.csv`.
- Demo data is off by default (`with_demo = True` in the dev configuration).
- Odoo listens on `127.0.0.1` by default: the dev configuration sets
  `http_interface = 0.0.0.0`.

## Odoo image

The image starts from the official `odoo:20.0` image, pinned by **dated tag + digest**
in `docker/Dockerfile` (`ARG ODOO_IMAGE`): the same base in development and production,
reproducible builds.

- Odoo is installed from a `.deb` package: sources in
  `/usr/lib/python3/dist-packages/odoo` (all addons in `odoo/addons`).
- Odoo's Python dependencies are apt packages. The project dependencies and the tooling
  go to a venv, `/opt/venv` (`--system-site-packages`); `/opt/venv/pip.conf`
  (constraints) prevents pip from replacing an apt version.
- Run Odoo with `odoo` (`/opt/venv/bin/odoo`, which sees the venv), not `/usr/bin/odoo`
  (system Python).

### Updating Odoo

```sh
docker buildx imagetools inspect odoo:20.0   # current digest of the 20.0 tag
```

Copy the dated tag (`20.0-YYYYMMDD`) and the digest into `ARG ODOO_IMAGE`, then _Dev
Containers: Rebuild Container_. On GitHub, the `odoo-image-bump.yml` workflow opens this
pull request every week (`ci/odoo-image-latest.sh` runs the same check locally).

## PostgreSQL

The template uses PostgreSQL 18 (Odoo 20 needs 16 or later), in development
(`compose.yaml`) and in CI (`ci/lib.sh`, variable `POSTGRES_IMAGE`). The PostgreSQL
clients of the Odoo image (`pg_dump`, `pg_restore`) are version 18 too.

Since version 18, the `postgres` image keeps its data in
`/var/lib/postgresql/<version>/docker`: the `pg-data` volume is mounted on
`/var/lib/postgresql`. This mount requires `POSTGRES_VERSION` 18 or later.

**Moving a PostgreSQL 16 development database** (old `<project>_db-data` volume, left
untouched by the move to 18): the filestore (`odoo-data`) does not change, only the
database has to be transferred.

```sh
docker volume ls | grep db-data                       # exact name of the old volume
docker run -d --name pg16 -e POSTGRES_PASSWORD=odoo \
  -v <project>_db-data:/var/lib/postgresql/data postgres:16
docker exec pg16 pg_dumpall -U odoo > dump.sql
docker rm -f pg16
docker compose up -d db
docker compose exec -T db psql -U odoo -d postgres < dump.sql
```

Once the database is checked: `docker volume rm <project>_db-data`, and delete
`dump.sql`.
