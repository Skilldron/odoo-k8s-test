# CI et image de prod

La CI (GitHub Actions) vérifie le code, construit l'**image de prod**, la teste et la
publie sur GHCR. Elle s'arrête là : le **déploiement est à faire soi-même** dans cette
branche. Les moyens de déploiement (Docker, Kubernetes) vivent dans des branches
alternatives du dépôt modèle (`20.0-docker-deployment`, `20.0-k8s-deployment`).

Plan d'origine : [plans/ci-github-actions.md](plans/ci-github-actions.md). Modèle de
branches : [gitflow.md](gitflow.md).

## Pipeline

```
pull_request / push ──► lint ──► image ───────────────────────────────────────┐
                        pre-commit   build (ou réutilisation du tree)          │
                                     tests (image test, PostgreSQL jetable)    │
                                     smoke test (image prod durcie)            │
                                     publication GHCR + tags                   │
tag vX.Y.Z ─────────────────────────► promote : retag X.Y.Z, sans rebuild ◄────┘
```

| Workflow                                | Déclencheur                                                               | Rôle                                       |
| --------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------ |
| `.github/workflows/ci.yml`              | PR ; push `main`, `develop`, `release/**`, `hotfix/**`, `*.0` ; tags `v*` | lint, image, tests, publication, promotion |
| `.github/workflows/odoo-image-bump.yml` | lundi 5 h et manuel                                                       | PR quand l'image officielle `odoo` change  |
| `.github/dependabot.yml`                | hebdomadaire                                                              | PR de mise à jour (actions, pip, npm)      |

Chaque job n'est qu'une fine couche au-dessus des scripts `ci/`, qui tournent à
l'identique en local :

| Script                     | Rôle                                                                                                      |
| -------------------------- | --------------------------------------------------------------------------------------------------------- |
| `ci/image-build.sh`        | Construit `prod` et `test` pour le tree git courant, ou réutilise l'image déjà publiée                    |
| `ci/run-tests.sh <image>`  | Tests des modules de `addons/` + couverture ; échoue sur un test KO ou une ligne ERROR/CRITICAL           |
| `ci/smoke.sh <image>`      | Démarre l'image prod en lecture seule, sans capacités ; vérifie `/web/health`, `/web/login`, uid non root |
| `ci/image-publish.sh TAG…` | Pousse l'image du tree (si construite par ce run) et ajoute des tags sur le même digest                   |
| `ci/odoo-image-latest.sh`  | Nouveau digest de l'image officielle Odoo, s'il y en a un                                                 |

```sh
# En local (Docker requis) :
IMAGE=localhost:5050/mon-projet ci/image-build.sh
ci/run-tests.sh localhost:5050/mon-projet:tree-<hash>-test
ci/smoke.sh localhost:5050/mon-projet:tree-<hash>
```

## Une image par version

L'identité d'une image est le **tree git** du commit (`git rev-parse HEAD^{tree}`) : son
contenu, indépendamment de l'historique.

- Le tag `tree-<hash>` n'est poussé **qu'après** les tests et le smoke test : une image
  présente dans le registre a toujours été testée.
- Si le tree a déjà son image (merge en `--no-ff` d'une `release/x.y.z` dans `main`,
  re-run…), elle est **réutilisée** : pas de rebuild, pas de nouveaux tests.
- Un tag git `vX.Y.Z` ne construit rien : `promote` ajoute le tag `X.Y.Z` au digest du
  tree, et échoue si ce tree n'a pas d'image.

| Événement                  | Tags ajoutés (`ghcr.io/<org>/<dépôt>`) | Environnement visé |
| -------------------------- | -------------------------------------- | ------------------ |
| tout run publié            | `tree-<hash>`, `sha-<7>`               | —                  |
| pull request               | `pr-<n>`                               | review             |
| push `develop`             | `develop`                              | testing            |
| push `release/x.y.z`       | `x.y.z-rc.<run>`                       | recette            |
| push `main`                | `main`                                 | —                  |
| push `20.0` (dépôt modèle) | `20.0`                                 | —                  |
| tag `vX.Y.Z`               | `X.Y.Z`                                | prod               |

Pour déployer, utiliser de préférence le **digest** (`image@sha256:…`, affiché dans le
résumé du job) plutôt qu'un tag mobile.

Les PR venant de forks sont construites et testées mais jamais publiées (pas de jeton
d'écriture).

## Étapes de l'image (`docker/Dockerfile`)

| Étape     | Contenu                                                                                        |
| --------- | ---------------------------------------------------------------------------------------------- |
| `runtime` | Image officielle `odoo:20.0` figée par digest, utilisateur `odoo` (uid 1000), venv `/opt/venv` |
| `builder` | `git` et outils de compilation pour installer `requirements.txt` (modules OCA)                 |
| `base`    | `runtime` + venv construit, sans `git`                                                         |
| `dev`     | Outillage du dev container                                                                     |
| `prod`    | `base` + `addons/`, `vendor/`, configuration par variables, `HEALTHCHECK` ; l'image déployée   |
| `test`    | `prod` + `coverage`, uniquement pour la CI (jamais publiée)                                    |

L'image `prod` suit `docker-patterns` : base figée par digest, utilisateur non root,
aucun secret dans les couches, compatible `--read-only` (configuration rendue dans
`/tmp`), `HEALTHCHECK` sur `/web/health`.

## Configuration par environnement

La même image sert tous les environnements ; seule la configuration change. Au
démarrage, `docker/entrypoint.sh` rend `docker/odoo.conf.template` dans `/tmp/odoo.conf`
à partir des variables d'environnement, puis passe la main à l'entrypoint officiel
(attente de PostgreSQL). Une variable requise manquante arrête le conteneur avec un
message explicite.

| Variable                 | Requise | Défaut       | Option Odoo              |
| ------------------------ | ------- | ------------ | ------------------------ |
| `PGHOST`                 | oui     | —            | `db_host`                |
| `PGPORT`                 | non     | `5432`       | `db_port`                |
| `PGUSER`                 | oui     | —            | `db_user`                |
| `PGPASSWORD`             | oui     | —            | `db_password` (secret)   |
| `PGDATABASE`             | oui     | —            | `db_name`, `dbfilter`    |
| `ODOO_ADMIN_PASSWD`      | oui     | —            | `admin_passwd` (secret)  |
| `ODOO_WORKERS`           | non     | `2`          | `workers`                |
| `ODOO_MAX_CRON_THREADS`  | non     | `1`          | `max_cron_threads`       |
| `ODOO_LIST_DB`           | non     | `False`      | `list_db`                |
| `ODOO_PROXY_MODE`        | non     | `True`       | `proxy_mode`             |
| `ODOO_LIMIT_MEMORY_SOFT` | non     | `2147483648` | `limit_memory_soft`      |
| `ODOO_LIMIT_MEMORY_HARD` | non     | `2684354560` | `limit_memory_hard`      |
| `ODOO_LIMIT_TIME_CPU`    | non     | `600`        | `limit_time_cpu`         |
| `ODOO_LIMIT_TIME_REAL`   | non     | `1200`       | `limit_time_real`        |
| `ODOO_SMTP_SERVER`       | non     | `localhost`  | `smtp_server`            |
| `ODOO_SMTP_PORT`         | non     | `25`         | `smtp_port`              |
| `ODOO_SMTP_SSL`          | non     | `False`      | `smtp_ssl`               |
| `ODOO_SMTP_USER`         | non     | vide         | `smtp_user`              |
| `ODOO_SMTP_PASSWORD`     | non     | vide         | `smtp_password` (secret) |
| `ODOO_EMAIL_FROM`        | non     | vide         | `email_from`             |
| `ODOO_LOG_LEVEL`         | non     | `info`       | `log_level`              |

**Configuration complète à la main** : monter son propre fichier et pointer `ODOO_RC`
dessus (`-e ODOO_RC=/etc/odoo/odoo.conf -v ./odoo.conf:/etc/odoo/odoo.conf:ro`) ; rien
n'est alors rendu.

## Déployer soi-même

Exemple minimal avec Docker (à adapter : réseau, reverse proxy, sauvegardes, secrets) :

```sh
IMAGE=ghcr.io/<org>/<dépôt>@sha256:<digest>
ENV=(-e PGHOST=db.interne -e PGUSER=odoo -e PGPASSWORD=… -e PGDATABASE=prod
     -e ODOO_ADMIN_PASSWD=… -e ODOO_WORKERS=4)

# 1. Mise à jour des modules (à chaque nouvelle version)
docker run --rm "${ENV[@]}" -v odoo-data:/var/lib/odoo "$IMAGE" \
    odoo -u all --stop-after-init --no-http
# 2. Démarrage, durci
docker run -d --name odoo "${ENV[@]}" -v odoo-data:/var/lib/odoo -p 8069:8069 -p 8072:8072 \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
    --restart unless-stopped "$IMAGE"
```

Points à prévoir : `/var/lib/odoo` (filestore) sur un volume persistant et sauvegardé
avec la base ; le port `8072` (websocket) derrière le même reverse proxy que `8069` ;
les secrets injectés par l'outil de déploiement, jamais versionnés.

## Mises à jour des dépendances

- **Image Odoo** : `odoo-image-bump.yml` ouvre une PR qui met à jour `ARG ODOO_IMAGE`
  (tag daté + digest). Les PR créées avec `GITHUB_TOKEN` ne déclenchent pas la CI :
  définir le secret `ODOO_BUMP_TOKEN` (PAT fine-grained ou token d'app GitHub) pour
  l'avoir. Le cron ne tourne que sur la branche par défaut ; lancer le workflow à la
  main pour une autre branche de version.
- **Actions, pip, npm** : Dependabot (PR hebdomadaires, jamais fusionnées
  automatiquement).
- **Hooks pre-commit** : `pre-commit autoupdate` dans le dev container, puis PR.

## Sur GitHub

- Rendre le paquet GHCR accessible aux serveurs qui déploient (paramètres du paquet), ou
  utiliser un jeton de lecture `read:packages`.
- Commandes utiles (`gh`) :

```sh
gh run list --workflow ci.yml --limit 10   # derniers runs
gh run watch                               # suivre le run en cours
gh run view <id> --log-failed              # logs d'un job en échec
```
