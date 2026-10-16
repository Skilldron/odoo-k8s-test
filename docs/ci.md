# CI et image de prod

La CI (GitHub Actions, runners hébergés par GitHub) vérifie le code, construit l'**image
de prod**, la teste et la publie sur GHCR. Elle s'arrête là : le **déploiement est à
faire soi-même** dans cette branche. Les moyens de déploiement (Docker, Kubernetes)
vivent dans des branches alternatives du dépôt modèle (`20.0-docker-deployment`,
`20.0-k8s-deployment`).

Plans : [plans/ci-github-actions.md](plans/ci-github-actions.md) (v1),
[plans/ci-v2-image-base.md](plans/ci-v2-image-base.md) (v2, en place). Modèle de
branches : [gitflow.md](gitflow.md).

## Pipeline

Trois groupes de jobs (workflows réutilisables appelés par `.github/workflows/ci.yml`) :

```
Qualité    quality.yml   lint (pre-commit)
Image      image.yml     plan ─► base ─► build ─┬─► tests ─┐
                                                └─► smoke ─┴─► publish
                         (PR de fork : un seul job « local », sans publication)
Promotion  promote.yml   tag vX.Y.Z : dernière X.Y.Z-rc.N ─► X.Y.Z
```

| Job       | Rôle                                                                                                 |
| --------- | ---------------------------------------------------------------------------------------------------- |
| `plan`    | Tags à publier selon l'événement ; refuse une `release/` ou `hotfix/` qui n'est pas `X.Y.Z`          |
| `base`    | Publie `base:<clé>` si elle n'existe pas encore (environ une fois par semaine)                       |
| `build`   | Construit uniquement les modules sur `base:<clé>`, pousse `builds:run-<id>` (+ `-test`)              |
| `tests`   | Tests des modules de `addons/` + couverture, sur l'image tirée du registre                           |
| `smoke`   | Image prod en lecture seule, sans capacités : `/web/health`, `/web/login`, uid non root              |
| `publish` | Après tests **et** smoke test : pose les tags lisibles (même digest, sans rebuild) ; sortie `digest` |
| `promote` | Sur un tag git : promotion de la dernière release candidate ; sortie `digest`                        |

Autres workflows :

| Workflow                                | Déclencheur                        | Rôle                                      |
| --------------------------------------- | ---------------------------------- | ----------------------------------------- |
| `.github/workflows/cleanup.yml`         | fermeture de PR, quotidien, manuel | Nettoyage des paquets `builds` et `base`  |
| `.github/workflows/odoo-image-bump.yml` | lundi 5 h, manuel                  | PR quand l'image officielle `odoo` change |
| `.github/dependabot.yml`                | hebdomadaire                       | PR de mise à jour (actions, pip, npm)     |

## Image de base : seuls les modules sont reconstruits

`base:<clé>` contient l'image officielle `odoo:20.0` figée, le venv et les modules OCA
de `requirements.txt`. Sa clé (`ci/base-key.sh`) est une empreinte de
`docker/Dockerfile` et de `requirements.txt` : elle ne change qu'avec une nouvelle image
Odoo, un module OCA ou une modification du Dockerfile.

Le job `build` remplace l'étape `base` du Dockerfile par cette image
(`--build-context base=docker-image://…/base:<clé>`) : il n'exécute que les étapes
`prod` (copie des modules) et `test`, et ne pousse que ces couches, quelques Mo.

Ce que ça n'évite pas : pour lancer les tests et le smoke test, le runner doit avoir
l'image **complète**. Les runners hébergés par GitHub étant éphémères, les jobs `tests`
et `smoke` la tirent de GHCR à chaque run (réseau GitHub, sans limite Docker Hub). Seul
un runner auto-hébergé, avec un cache Docker persistant, éviterait ce téléchargement.

## Paquets GHCR et tags

| Paquet                         | Tags                                                                         | Durée de vie         |
| ------------------------------ | ---------------------------------------------------------------------------- | -------------------- |
| `ghcr.io/<org>/<dépôt>/base`   | `<clé>`                                                                      | 5 dernières versions |
| `ghcr.io/<org>/<dépôt>/builds` | `run-<id>-<essai>` (transit), `pr-<n>`, `develop`, `main`, `20.0`, `sha-<7>` | jetable (nettoyage)  |
| `ghcr.io/<org>/<dépôt>`        | `X.Y.Z-rc.N`, `X.Y.Z`                                                        | conservé             |

| Événement            | Tags publiés                          | Environnement visé |
| -------------------- | ------------------------------------- | ------------------ |
| pull request         | `builds:pr-<n>`                       | review (preview)   |
| push `develop`       | `builds:develop`, `builds:sha-<7>`    | testing            |
| push `main`, `20.0`  | `builds:<branche>`, `builds:sha-<7>`  | —                  |
| push `release/X.Y.Z` | `X.Y.Z-rc.<n° de run>`                | recette            |
| push `hotfix/X.Y.Z`  | `X.Y.Z-rc.<n° de run>`                | recette            |
| tag `vX.Y.Z`         | `X.Y.Z` (promotion de la dernière rc) | prod               |

Le `N` de `-rc.N` est le numéro de run de la CI : il croît toujours, sans être continu.
Pour déployer, utiliser de préférence le **digest** (`image@sha256:…`, affiché dans le
résumé du job) plutôt qu'un tag mobile.

## Une seule promotion : recette → prod

Avant la recette, chaque événement reconstruit son image (ce qui ne coûte presque rien)
: on a encore le temps de corriger. La seule garantie forte est à la fin : **la prod
reçoit exactement l'image validée en recette**.

Sur un tag `vX.Y.Z`, `ci/image-promote.sh` :

1. retient la release candidate `X.Y.Z-rc.N` de plus grand N (`rc.63` avant `rc.9`) ;
   échec s'il n'y en a aucune ;
2. **contrôle** que la rc a été construite à partir du code tagué : son label
   `odoo.template.tree` (empreinte du contenu du code, posée au build) doit être égal à
   celle du commit tagué. Sinon refus, par exemple si `main` a reçu un hotfix après la
   dernière rc : fusionner ce qui manque dans la release, valider la nouvelle rc, puis
   re-taguer ;
3. ajoute le tag `X.Y.Z` au digest de la rc : **même digest**, sans rebuild.

Toutes les copies de tags (`builds` → release, rc → prod) gardent le digest d'origine
(`imagetools create --prefer-index=false`).

## Nettoyage (`cleanup.yml`)

- Fermeture d'une PR : la version taguée `builds:pr-<n>` est supprimée.
- Chaque nuit : dans `builds`, suppression des versions non taguées et de tout ce qui
  dépasse les 30 plus récentes, sauf `develop`, `main`, `20.0` et les previews `pr-<n>`
  (supprimées à la fermeture de leur PR) ; dans `base`, on garde les 5 dernières.
- Le paquet de release n'est **jamais** nettoyé automatiquement.

Les images sont publiées sans attestations (`--provenance=false`) : chaque image est un
manifeste unique, et une version non taguée est toujours une image remplacée, donc
supprimable sans risque.

**Pré-requis GitHub** (une fois, après le premier push qui crée les paquets) : dans les
paramètres de chaque paquet (`<dépôt>`, `<dépôt>/builds`, `<dépôt>/base`), donner au
dépôt l'accès Actions avec le rôle **Admin**, nécessaire pour supprimer des versions
avec `GITHUB_TOKEN`. Les paquets privés consomment le quota de stockage GitHub Packages
: le nettoyage de `builds` le maintient bas.

## Scripts `ci/`

Chaque job n'est qu'une fine couche au-dessus de ces scripts, qui tournent à l'identique
en local :

| Script                          | Rôle                                                                               |
| ------------------------------- | ---------------------------------------------------------------------------------- |
| `ci/base-key.sh`                | Clé de l'image de base                                                             |
| `ci/base-ensure.sh`             | Publie `base:<clé>` si absente                                                     |
| `ci/image-build.sh`             | Images `prod` et `test` sur la base (`PUSH=true`) ; `BASE=local` : tout construire |
| `ci/run-tests.sh <image>`       | Tests + couverture ; échoue sur un test KO ou une ligne ERROR/CRITICAL             |
| `ci/smoke.sh <image>`           | Smoke test durci                                                                   |
| `ci/image-tag.sh SRC DEST…`     | Ajoute des tags (même digest), éventuellement dans un autre paquet                 |
| `ci/image-promote.sh X.Y.Z`     | Dernière rc → `X.Y.Z`, avec contrôle du contenu                                    |
| `ci/registry-tags.py IMAGE`     | Liste les tags d'un dépôt d'images (API OCI)                                       |
| `ci/ghcr-prune.sh PAQUET RÈGLE` | Nettoyage d'un paquet GHCR (`tag:<tag>` ou `keep:<n>[:<regex>]`)                   |
| `ci/odoo-image-latest.sh`       | Nouveau digest de l'image officielle Odoo, s'il y en a un                          |

```sh
# En local, avec un registre jetable :
docker run -d --name registry -p 5050:5000 registry:2
export IMAGE=localhost:5050/mon-projet
ci/base-ensure.sh
PUSH=true TAG=local-1 ci/image-build.sh
ci/run-tests.sh "$IMAGE/builds:local-1-test"
ci/smoke.sh "$IMAGE/builds:local-1"
ci/image-tag.sh "$IMAGE/builds:local-1" "$IMAGE:1.0.0-rc.1"
ci/image-promote.sh 1.0.0          # depuis le commit construit
```

## Étapes de l'image (`docker/Dockerfile`)

| Étape     | Contenu                                                                                        |
| --------- | ---------------------------------------------------------------------------------------------- |
| `runtime` | Image officielle `odoo:20.0` figée par digest, utilisateur `odoo` (uid 1000), venv `/opt/venv` |
| `builder` | `git` et outils de compilation pour installer `requirements.txt` (modules OCA)                 |
| `base`    | `runtime` + venv construit, sans `git` — publiée en CI comme `base:<clé>`                      |
| `dev`     | Outillage du dev container                                                                     |
| `prod`    | `base` + `addons/`, `vendor/`, configuration par variables, `HEALTHCHECK` ; l'image déployée   |
| `test`    | `prod` + `coverage`, uniquement pour la CI                                                     |

L'image `prod` suit `docker-patterns` : base figée par digest, utilisateur non root,
aucun secret dans les couches, compatible `--read-only` (configuration statique, rien
n'est écrit au démarrage), `HEALTHCHECK` sur `/web/health`. Labels :
`org.opencontainers.image.version`, `org.opencontainers.image.revision`,
`odoo.template.tree`, `odoo.version`.

## Configuration par environnement

La même image sert tous les environnements ; seule la configuration change. L'image
contient une configuration statique sans secret, `docker/odoo.conf` (`ODOO_RC`), qui ne
fixe que ce qui diffère des défauts d'Odoo. Le reste vient de l'environnement, lu par
Odoo 20 lui-même avant le fichier :

- chaque option du fichier a sa variable `ODOO_<OPTION>` (en majuscules), par exemple
  `ODOO_WORKERS` pour `workers` ;
- la base vient des variables `PG*`.

Rien n'est rendu au démarrage. `docker/entrypoint.sh` vérifie seulement les variables
requises, arrête le conteneur avec un message explicite s'il en manque une, puis passe
la main à l'entrypoint officiel (attente de PostgreSQL).

Variables courantes :

| Variable                 | Requise | Défaut       | Option Odoo              |
| ------------------------ | ------- | ------------ | ------------------------ |
| `PGHOST`                 | oui     | —            | `db_host`                |
| `PGPORT`                 | non     | `5432`       | `db_port`                |
| `PGUSER`                 | oui     | —            | `db_user`                |
| `PGPASSWORD`             | oui     | —            | `db_password` (secret)   |
| `PGDATABASE`             | oui     | —            | `db_name` (seule base)   |
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

Sans `dbfilter`, Odoo ne sert que la base `db_name`. Les défauts viennent de
`docker/odoo.conf`, ou d'Odoo lui-même pour le SMTP et `log_level`.

**Autre fichier de configuration** : monter son propre fichier et pointer `ODOO_RC`
dessus (`-e ODOO_RC=/etc/odoo/odoo.conf -v ./odoo.conf:/etc/odoo/odoo.conf:ro`), par
exemple pour les sections de modules (`[queue_job]`). Les secrets restent dans
l'environnement : le fichier n'en contient aucun, et les variables requises le restent.

## Déployer soi-même

Exemple minimal avec Docker (à adapter : réseau, reverse proxy, sauvegardes, secrets) :

```sh
IMAGE=ghcr.io/<org>/<dépôt>@sha256:<digest>
ENV=(-e PGHOST=db.interne -e PGUSER=odoo -e PGPASSWORD=… -e PGDATABASE=prod
     -e ODOO_ADMIN_PASSWD=… -e ODOO_WORKERS=4)

# 1. Modules, Odoo arrêté
RUN=(docker run --rm "${ENV[@]}" -v odoo-data:/var/lib/odoo "$IMAGE")
#    première installation : modules du projet, puis référence des empreintes
"${RUN[@]}" odoo -i <modules> --stop-after-init --no-http
"${RUN[@]}" click-odoo-update --only-compute-hashes
#    nouvelle version : seuls les modules modifiés sont mis à jour
"${RUN[@]}" click-odoo-update
# 2. Démarrage, durci
docker run -d --name odoo "${ENV[@]}" -v odoo-data:/var/lib/odoo -p 8069:8069 -p 8072:8072 \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
    --restart unless-stopped "$IMAGE"
```

Mise à jour des modules : `click-odoo-update` (paquet `click-odoo-contrib`, dans
l'image) compare l'empreinte de chaque module à celle stockée en base et ne met à jour
que les modules modifiés, y compris les modules Odoo et OCA après une nouvelle image de
base (`--update-all` force une mise à jour complète). Arrêter Odoo pendant la mise à
jour et sauvegarder juste avant : Odoo enregistre chaque module mis à jour au fur et à
mesure, une mise à jour en échec laisse la base à moitié migrée.

Points à prévoir : `/var/lib/odoo` (filestore) sur un volume persistant et sauvegardé
avec la base ; le port `8072` (websocket) derrière le même reverse proxy que `8069` ;
les secrets injectés par l'outil de déploiement, jamais versionnés ; pour les serveurs,
un jeton `read:packages` si les paquets sont privés.

## Mises à jour des dépendances

- **Image Odoo** : `odoo-image-bump.yml` ouvre une PR qui met à jour `ARG ODOO_IMAGE`
  (tag daté + digest) ; la CI de cette PR publie la nouvelle `base:<clé>`. Les PR créées
  avec `GITHUB_TOKEN` ne déclenchent pas la CI : définir le secret `ODOO_BUMP_TOKEN`
  (PAT fine-grained ou token d'app GitHub) pour l'avoir. Le cron ne tourne que sur la
  branche par défaut ; lancer le workflow à la main pour une autre branche de version.
- **Actions, pip, npm** : Dependabot (PR hebdomadaires, jamais fusionnées
  automatiquement).
- **Hooks pre-commit** : `pre-commit autoupdate` dans le dev container, puis PR.

## Sur GitHub

Ce qui n'a pas pu être vérifié en local et est à contrôler au premier push : affichage
des groupes de jobs, droits des paquets imbriqués, suppression de versions par
`cleanup.yml`, chemin des PR de fork, cache `type=gha`.

```sh
gh run list --workflow ci.yml --limit 10   # derniers runs
gh run watch                               # suivre le run en cours
gh run view <id> --log-failed              # logs d'un job en échec
```
