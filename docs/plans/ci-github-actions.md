# Plan — CI GitHub Actions, Git Flow et image de prod unique configurable par environnement

> **Écart lors de la mise en œuvre** : build, tests, smoke test et publication sont
> regroupés dans un seul job `image` (au lieu de jobs séparés), pour ne pas transférer
> l'image entre jobs. Le tag `tree-<hash>` n'est poussé qu'après les tests : une image
> réutilisée a donc toujours été testée. Les scripts sont ceux prévus, plus `ci/lib.sh`
> et `ci/odoo-image-latest.sh`. Documentation finale : `docs/ci.md`.

## Contexte

Le dépôt modèle Odoo 20.0 Community a déjà son environnement de dev :

- Dockerfile multi-stage `runtime` → `builder` → `base` → `dev`, sur l'image officielle
  `odoo:20.0` figée par digest ;
- modules OCA installés par pip, modules achetés dans `vendor/` ;
- pre-commit en place.

Il n'a ni CI (`.github/` absent) ni remote GitHub.

Objectif : une CI GitHub Actions qui s'arrête au **build et à la publication de l'image
de prod**. Il y a une **image unique par version**, construite une fois puis retaguée
sans rebuild. La configuration propre à chaque environnement (review, testing, recette,
prod) est injectée au démarrage du conteneur.

Le **déploiement est hors périmètre** dans cette branche : chacun le fait soi-même. Les
moyens de déploiement viendront dans des branches alternatives
(`20.0-docker-deployment`, `20.0-k8s-deployment`). Il n'y aura donc pas de dossier
`deploy/`, ni de jobs de déploiement, ni de nettoyage des reviews.

Décisions validées :

- Le modèle garde ses branches par version Odoo. La doc recommande Git Flow aux projets
  réels.
- Versions SemVer `v1.2.3` (`v1.2.3-rc.N` pour la recette).
- Vérification locale seulement : pas de remote, `gh`, `act` et `actionlint` absents de
  la machine. Les workflows restent de fines couches au-dessus de scripts `ci/`
  exécutables en local.

Skills :

- `ecc:docker-patterns` : étape `prod`.
- `ecc:github-ops` : workflows et releases. Les commandes `gh` sont documentées ; aucune
  n'est exécutée, faute de remote.
- `ecc:verification-loop` : pendant et à la fin du développement.

## Approche

### 1. Image de prod — `docker/Dockerfile`

Nouvelles étapes après `dev`, sans toucher aux étapes existantes :

- **`prod`** (FROM `base`) :
  - copie `addons/` et `vendor/` dans `/opt/odoo/{addons,vendor}` ;
  - copie `docker/odoo.conf.template`, `docker/render-config.py` et
    `docker/entrypoint.sh` ;
  - `USER odoo` (uid 1000) ;
  - `HEALTHCHECK` par `curl -fsS http://localhost:8069/web/health` (route vérifiée dans
    Odoo 20, `curl` présent dans l'image) ;
  - labels OCI `version` et `revision` (build-args), plus `odoo.version=20.0` ;
  - aucun secret dans les couches ;
  - compatible avec un système de fichiers racine en lecture seule (conf rendue dans
    `/tmp`).
- **`test`** (FROM `prod`) : ajoute seulement `coverage` (pin de
  `requirements-dev.txt`). La CI teste cette image ; l'image publiée est `prod`.

Fichier `.dockerignore` : exclure `.github`, `docs`, `.devcontainer`, `.vscode`,
`node_modules` et `ci`.

### 2. Configuration par environnement (contrat de l'image)

- **`docker/odoo.conf.template`** : valeurs par défaut sûres pour la prod (`proxy_mode`,
  `list_db = False`, `workers`, limites) et placeholders `${VAR}` / `${VAR:-défaut}`
  (`ODOO_ADMIN_PASSWD` requis, `ODOO_WORKERS`, `ODOO_LOG_LEVEL`, SMTP…).
  `dbfilter = ^${PGDATABASE}$`.
- **Connexion à la base** : variables `PG*` natives d'Odoo 20 (`PGHOST`, `PGUSER`,
  `PGPASSWORD`, `PGDATABASE`…, vérifiées dans `odoo/tools/config.py`). L'entrypoint
  officiel les respecte déjà (`check_config`).
- **`docker/render-config.py`** (environ 30 lignes, sans dépendance) : rend le template
  dans `/tmp/odoo.conf` et échoue explicitement si une variable requise manque.
- **`docker/entrypoint.sh`** : fait le rendu, exporte `ODOO_RC`, puis
  `exec /entrypoint.sh "$@"` (on garde l'entrypoint officiel et `wait-for-psql.py`).
- **Option de montage** : on peut aussi fournir sa propre conf (montée, `ODOO_RC` pointé
  dessus), auquel cas l'entrypoint ne fait pas le rendu.
- Le tableau des variables (requises ou optionnelles, valeurs par défaut) est documenté.
  C'est ce que fournira chaque méthode de déploiement.

### 3. Une image par version, publiée sur GHCR

Identité de l'image : tag `tree-<git tree hash>`. Avec Git Flow en `--no-ff`, le commit
de merge sur `main` a le même tree que `release/x.y.z`.

- `ci/image-build-or-reuse.sh` : si `tree-<T>` existe déjà, on réutilise son digest,
  sinon on construit `prod` et on pousse (cache `type=gha`). Tags lisibles pour les
  déploiements faits à la main :
  - `sha-<court>` ;
  - `pr-<n>` (review) ;
  - `develop` (testing) ;
  - `<x.y.z>-rc.<N>` sur `release/**` (recette).
- `ci/image-promote.sh <version>`, sur un tag git `v1.2.3` :
  `docker buildx imagetools create` retague le même digest en `1.2.3`, sans rebuild. Il
  échoue si l'image du tree n'existe pas.

### 4. Workflows — `.github/workflows/`

| Fichier                  | Déclencheur                                                                               | Jobs                                                                                                                                                                                                                                                 |
| ------------------------ | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci.yml`                 | `pull_request` ; push sur `main`, `develop`, `release/**`, `hotfix/**`, `*.0` ; tags `v*` | `lint` (pre-commit, Python 3.12, Node 22, cache) → `build` (étape `test` + `prod`) → `test` (Postgres 16 en service, `ci/run-tests.sh`) et `smoke` (`ci/smoke.sh`) → `publish` (push GHCR et tags, hors PR de fork) → `promote` (tag `v*` seulement) |
| `odoo-image-bump.yml`    | cron hebdomadaire et manuel                                                               | Digest courant de `odoo:20.0` (`imagetools inspect`) ; s'il a changé, PR via `gh pr create` qui met à jour `ARG ODOO_IMAGE`                                                                                                                          |
| `.github/dependabot.yml` | —                                                                                         | `github-actions` et `pip` (`requirements*.txt`)                                                                                                                                                                                                      |

Garde-fous :

- Permissions minimales par job (`packages: write` seulement pour `publish` et
  `promote`).
- Actions épinglées par sha.
- Pas de publication pour les PR venant de forks.

### 5. Scripts CI — `ci/`, exécutables à l'identique en local

- **`ci/list-addons.sh`** : les modules de `addons/` qui ont un `__manifest__.py`.
- **`ci/run-tests.sh <image>`** :
  - base jetable, `-i <addons> --test-enable --test-tags /<addon>… --stop-after-init` ;
  - échoue sur un code retour non nul (Odoo 20 incrémente `rc` en cas d'échec des tests,
    vérifié dans `odoo/service/server.py`) ou sur une ligne `ERROR`/`CRITICAL` ;
  - rapport de couverture dans le résumé du job, sans seuil bloquant au départ.
- **`ci/smoke.sh <image>`** : `docker run` de l'image `prod` avec un Postgres jetable,
  en `--read-only --tmpfs /tmp --cap-drop ALL`, avec les variables minimales du contrat.
  Attend `/web/health` = 200, puis vérifie que le conteneur tourne avec un utilisateur
  non root.

### 6. Documentation

- **`docs/ci.md`** :
  - schéma du pipeline ;
  - tags d'image produits et environnement auquel chacun sert ;
  - promotion sans rebuild ;
  - contrat de configuration de l'image ;
  - déploiement à faire soi-même, avec un exemple minimal en `docker run` et un renvoi
    vers les futures branches `20.0-docker-deployment` et `20.0-k8s-deployment` ;
  - mise à jour de l'image Odoo.
- **`docs/gitflow.md`** :
  - **pour les projets réels** : `main` = prod (tags `vX.Y.Z`), `develop` = testing,
    `feature/*` → PR (review), `release/x.y.z` = recette, `hotfix/x.y.z` ; merges en
    `--no-ff` (nécessaire à la promotion par tree) ; commandes `gh`
    (`gh release create v1.2.3 --generate-notes`, rulesets via `gh api`, `gh run watch`)
    ;
  - **pour le dépôt modèle** : une branche par version et par moyen de déploiement
    (`20.0`, `20.0-docker-deployment`…), CI uniquement.
- **`README.md`** : une courte section CI avec liens, et l'arborescence mise à jour
  (`.github/`, `ci/`, `docs/`).

### Fichiers critiques

- À modifier : `docker/Dockerfile`, `.dockerignore`, `README.md`.
- À créer : `docker/odoo.conf.template`, `docker/render-config.py`,
  `docker/entrypoint.sh`, `ci/*.sh`, `.github/workflows/{ci,odoo-image-bump}.yml`,
  `.github/dependabot.yml`, `docs/ci.md`, `docs/gitflow.md`.
- À réutiliser : les étapes `runtime`/`base` du Dockerfile (venv, `pip.conf` de
  contraintes, `/opt/venv/odoo-addons`), l'entrypoint officiel `/entrypoint.sh` et
  `wait-for-psql.py`, `.pre-commit-config.yaml` (même configuration en local et en CI),
  `compose.yaml` de dev, inchangé.

## Mise en œuvre

Dans un worktree dédié. Commits depuis l'image de dev, car le hook git échoue sur le
Mac. Pas de push : pas de remote.

**Première étape** : enregistrer ce plan dans le projet,
`docs/plans/ci-github-actions.md`. Il est référencé depuis `docs/ci.md` et commité avec
le reste.

## Vérification (`ecc:verification-loop`)

1. `actionlint` sur `.github/workflows/`, via une image Docker épinglée, sans rien
   installer.
2. Build des étapes `prod` et `test` ; `docker history` sans secret ; utilisateur
   `odoo`.
3. `render-config.py` : rendu correct avec des variables d'exemple ; échec explicite si
   `ODOO_ADMIN_PASSWD` manque ; une conf montée est respectée.
4. `ci/run-tests.sh` en local : `dev_sample` vert. Puis un test cassé volontairement
   doit faire échouer le script.
5. `ci/smoke.sh` en local : `/web/health` = 200 en lecture seule et avec `cap_drop`.
6. `ci/image-build-or-reuse.sh` et `ci/image-promote.sh` contre un registre local
   `registry:2` : la réutilisation par tree évite un second build, et le retag `1.2.3`
   garde le même digest.
7. `pre-commit run --all-files`.
8. Rapport `verification-loop` : build, lint, tests, sécurité, revue du diff.

Limite connue : les exécutions réelles sur GitHub (GHCR, tags, PR de bump) ne pourront
être vérifiées qu'après création du remote. `act` est optionnel ; je demanderai avant de
l'installer.
