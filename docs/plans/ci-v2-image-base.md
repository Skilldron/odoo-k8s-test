# Plan v2 — image de base en cache, paquets GHCR séparés, jobs groupés, promotion rc → prod

> **Implémenté.** Écarts lors de la mise en œuvre :
>
> - le remplacement de l'étape `base` par `--build-context` fonctionne : le repli
>   `ARG BASE_IMAGE` n'a pas été nécessaire ;
> - copies de tags avec `imagetools create --prefer-index=false` : sans cette option,
>   copier une image vers un autre paquet l'emballait dans un index et changeait le
>   digest ;
> - nettoyage par `ci/ghcr-prune.sh` (API GitHub) au lieu de
>   `actions/delete-package-versions`, dont le filtre porte sur le nom de version (le
>   digest) et non sur les tags ; les previews `pr-<n>` sont protégées de la règle
>   `keep` et supprimées seulement à la fermeture de leur PR.
>
> Documentation finale : `docs/ci.md`, `docs/gitflow.md`.

Fait suite à [ci-github-actions.md](ci-github-actions.md) (implémenté sur
`worktree-ci`). Décisions prises avec l'utilisateur :

- runners **hébergés par GitHub** ;
- image `base:<clé>` sur GHCR : un build ne reconstruit que les modules ;
- paquets GHCR séparés : **builds** (jetables, nettoyés) et **release** (rc + prod) ;
- jobs groupés (workflows réutilisables) ;
- **une seule promotion** : dernière `X.Y.Z-rc.N` → `X.Y.Z`, avec contrôle de contenu.
  L'identité par tree git (`tree-<hash>`) et la réutilisation d'images disparaissent ;
- `hotfix/x.y.z` suit la même logique que `release/x.y.z` (rc en recette, puis tag).

## 1. Dockerfile — `docker/Dockerfile`

- Étapes `runtime` → `builder` → `base` → `dev` : inchangées (le dev container construit
  toujours sa base en local).
- `prod` : toujours `FROM base`. En CI, l'étape `base` est **remplacée** par l'image
  GHCR via un contexte nommé :
  `docker buildx build --build-context base=docker-image://ghcr.io/<org>/<dépôt>/base:<clé> --target prod`.
  Ainsi rien n'est reconstruit ni rejoué sous `base`, seule la couche des modules est
  produite. **À vérifier en premier** (remplacement d'une étape par un contexte nommé) ;
  repli : `ARG BASE_IMAGE=base` global puis `FROM ${BASE_IMAGE} AS prod`.
- Nouveau label sur `prod` : `odoo.template.tree=<git tree hash>` (build-arg `TREE`),
  utilisé par le contrôle de promotion. Labels OCI `version` / `revision` conservés.
- `test` : inchangée (`prod` + `coverage`).

## 2. Paquets GHCR

| Paquet                         | Tags                                                                                                         | Durée de vie         |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------ | -------------------- |
| `ghcr.io/<org>/<dépôt>/base`   | `<clé>`                                                                                                      | 5 dernières versions |
| `ghcr.io/<org>/<dépôt>/builds` | `run-<id>`, `run-<id>-test` (transit entre jobs), `pr-<n>`, `develop`, `main`, `<série>` (`20.0`), `sha-<7>` | nettoyé (voir §5)    |
| `ghcr.io/<org>/<dépôt>`        | `x.y.z-rc.<N>` (recette), `x.y.z` (prod)                                                                     | conservé             |

- **Clé de base** (`ci/base-key.sh`) : 12 premiers caractères du sha256 de
  `docker/Dockerfile` + `requirements.txt`. Toute modification de l'un des deux
  (nouvelle image Odoo, module OCA, étape du Dockerfile) produit une nouvelle base ;
  c'est rare (≈ 1 fois par semaine) et ça évite d'extraire une partie du Dockerfile.
- `run-<id>` sert à passer l'image entre jobs. Elle est poussée avant les tests, ce qui
  ne pose pas de problème : `builds` est jetable. Les tags lisibles (`pr-<n>`,
  `develop`, rc…) ne sont posés qu'**après** tests et smoke test.

## 3. Workflows — groupés par workflows réutilisables

```
ci.yml (orchestrateur)
├─ Qualité     quality.yml   lint (pre-commit)
├─ Image       image.yml     base ─► build ─┬─► tests          ┐
│                                           └─► smoke          ├─► publication
│                                     (fork : build+tests+smoke en un job, sans push)
└─ Promotion   promote.yml   tag vX.Y.Z : dernière rc ─► X.Y.Z
cleanup.yml    planifié + fermeture de PR : nettoyage de builds et base
odoo-image-bump.yml, dependabot.yml : inchangés
```

`ci.yml` — déclencheurs inchangés (PR ; push `main`, `develop`, `release/**`,
`hotfix/**`, `*.0` ; tags `v*`). Jobs :

- `quality` → `quality.yml` (sauf tag).
- `image` → `image.yml`, `needs: quality` (sauf tag). Entrée `publish` (false pour une
  PR de fork).
- `promote` → `promote.yml` (tag `v*` uniquement).

`image.yml` (`workflow_call`), jobs :

| Job       | Rôle                                                                                          |
| --------- | --------------------------------------------------------------------------------------------- |
| `base`    | `ci/base-ensure.sh` : si `base:<clé>` absent, build `--target base` + push (cache `type=gha`) |
| `build`   | `ci/image-build.sh` : `prod` et `test` depuis `base:<clé>`, push `builds:run-<id>[-test]`     |
| `tests`   | pull `run-<id>-test`, `ci/run-tests.sh` (inchangé)                                            |
| `smoke`   | pull `run-<id>`, `ci/smoke.sh` (inchangé)                                                     |
| `publish` | `needs: [tests, smoke]` ; `ci/image-tag.sh` selon l'événement (tableau ci-dessous)            |
| `local`   | PR de fork seulement : build complet `--load` + tests + smoke, sans push                      |

| Événement            | Publication (`publish`)              |
| -------------------- | ------------------------------------ |
| PR                   | `builds:pr-<n>`                      |
| push `develop`       | `builds:develop`, `builds:sha-<7>`   |
| push `main` / `*.0`  | `builds:<branche>`, `builds:sha-<7>` |
| push `release/x.y.z` | **release** `x.y.z-rc.<run_number>`  |
| push `hotfix/x.y.z`  | **release** `x.y.z-rc.<run_number>`  |

`release/*` et `hotfix/*` : la CI refuse un nom qui n'est pas `x.y.z` (SemVer).

`promote.yml` (`workflow_call`, tag `vX.Y.Z`) — `ci/image-promote.sh X.Y.Z` :

1. liste les tags du paquet release (API OCI `tags/list`) et retient la rc `X.Y.Z-rc.N`
   de plus grand N (comparaison numérique : `rc.63` > `rc.9`) ; échec si aucune ;
2. **contrôle** : label `odoo.template.tree` de la rc == `git rev-parse HEAD^{tree}` du
   commit tagué, sinon refus avec la marche à suivre (fusionner ce qui manque dans la
   release / le hotfix, nouvelle rc, re-taguer) ;
3. `imagetools create -t …:X.Y.Z …@<digest de la rc>` : même digest, sans rebuild ;
4. résumé du job : digest à déployer.

Permissions : `packages: write` seulement pour `base`, `build`, `publish`, `promote`,
`cleanup` ; actions épinglées par sha ; valeurs non fiables passées par `env` (skill
`github-ops`).

## 4. Scripts `ci/`

| Script                                                                                        | Statut    | Rôle                                                                       |
| --------------------------------------------------------------------------------------------- | --------- | -------------------------------------------------------------------------- |
| `ci/base-key.sh`                                                                              | nouveau   | clé de la base                                                             |
| `ci/base-ensure.sh`                                                                           | nouveau   | construit et pousse `base:<clé>` si absent                                 |
| `ci/image-build.sh`                                                                           | réécrit   | `prod` + `test` sur `base:<clé>` ; `--push` (CI) ou `--load` (local, fork) |
| `ci/image-tag.sh SRC TAG…`                                                                    | nouveau   | ajoute des tags (éventuellement dans un autre paquet) au digest de SRC     |
| `ci/image-promote.sh X.Y.Z`                                                                   | nouveau   | dernière rc → `X.Y.Z` avec contrôle du label `tree`                        |
| `ci/registry-tags.py IMAGE`                                                                   | nouveau   | liste les tags via l'API OCI (GHCR avec jeton, ou registre local)          |
| `ci/image-publish.sh`                                                                         | supprimé  | remplacé par `image-tag.sh` / `image-promote.sh`                           |
| `ci/run-tests.sh`, `ci/smoke.sh`, `ci/lib.sh`, `ci/list-addons.sh`, `ci/odoo-image-latest.sh` | inchangés |                                                                            |

## 5. Nettoyage — `.github/workflows/cleanup.yml`

- **Fermeture d'une PR** (`pull_request: closed`) : suppression de la version portant
  `pr-<n>` dans `builds` (`gh api`, paquet `<dépôt>%2Fbuilds`).
- **Quotidien** (`schedule` + manuel), avec `actions/delete-package-versions` :
  - `builds` : versions non taguées supprimées ; garder les 30 plus récentes, en
    ignorant `develop`, `main` et `<série>` ;
  - `base` : garder les 5 plus récentes.
- Le paquet release n'est **jamais** nettoyé automatiquement.
- Pré-requis documenté : dans les paramètres de chaque paquet, donner au dépôt l'accès
  Actions avec le rôle **Admin** (nécessaire pour supprimer des versions avec
  `GITHUB_TOKEN`).

## 6. Documentation

- `docs/ci.md` : nouveau pipeline (schéma par groupes), paquets et tags, `base:<clé>` et
  ce qu'elle évite (rebuild) / n'évite pas (téléchargement de l'image complète pour
  lancer les tests, runners éphémères), promotion unique et son contrôle, nettoyage et
  ses pré-requis, quota de stockage des paquets privés.
- `docs/gitflow.md` : hotfix via rc ; cas 1 (pas de release en cours) et cas 2 (release
  en cours : hotfix fusionné dans `release/*`, la release garde son numéro) avec les
  schémas validés ; recette partagée entre release et hotfix ; promotion refusée si
  `main` ≠ dernière rc ; la contrainte « merge commit obligatoire » disparaît (le
  contrôle porte sur le contenu).
- `README.md` : section CI mise à jour.
- Ce plan : note d'écarts éventuels en tête une fois implémenté.

## 7. Vérification (`ecc:verification-loop`)

En local, registre `registry:2` jetable (port 5050) :

1. `--build-context base=docker-image://…` remplace bien l'étape `base` : le build de
   `prod` ne rejoue aucune étape de base (logs BuildKit) ; repli `ARG` sinon.
2. `base-ensure.sh` : 1er run construit et pousse, 2e run ne fait rien ; une
   modification de `requirements.txt` change la clé.
3. `image-build.sh` en `--push` puis pull : `run-tests.sh` (4/4) et `smoke.sh` verts sur
   l'image tirée ; test volontairement cassé → échec.
4. `image-promote.sh` : choisit `rc.10` plutôt que `rc.9` ; même digest après promotion
   ; refus si le tree diffère ; refus si aucune rc.
5. Validation de nom de branche (`release/1.2` refusé).
6. `actionlint`, `shellcheck`, `pre-commit run --all-files`.
7. Rapport `verification-loop`.

**Non vérifiable en local** (à valider au premier push sur GitHub) : workflows
réutilisables dans l'interface, permissions GHCR des paquets imbriqués, suppression de
versions par `cleanup.yml`, chemin fork, cache `type=gha`.

## Mise en œuvre

Sur la branche `worktree-ci` (suite directe de la v1, pas encore fusionnée dans `20.0`).
Commits depuis l'image de dev. Pas de push (pas de remote).
