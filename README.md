# Odoo 20.0 Community — dépôt modèle

Dépôt modèle pour développer des addons Odoo dans un **dev container** VS Code, avec
debugger, LSP Odoo, lint et formatage prêts à l'emploi.

Une branche par version d'Odoo (`20.0`, `19.0`, …), même architecture.

## Démarrage

Prérequis : Docker, VS Code et l'extension _Dev Containers_.

1. Ouvrir le dossier dans VS Code → **Reopen in Container**.
2. Lancer **Odoo : serveur** (F5) → <http://localhost:8069>, base `odoo20` par défaut.
3. Les e-mails envoyés par Odoo sont visibles dans Mailpit : <http://localhost:8025>.

Hors VS Code : `docker compose up -d` puis `docker compose exec odoo odoo -d odoo20`.

## Ce que contient l'environnement

| Besoin             | Outil                                                                 |
| ------------------ | --------------------------------------------------------------------- |
| Image              | `docker/Dockerfile`, basé sur l'image officielle `odoo:20.0` (digest) |
| Services           | `compose.yaml` : Odoo, PostgreSQL 16, Mailpit                         |
| LSP Odoo           | Extension `Odoo.odoo` (OdooLS), configurée par `odools.toml`          |
| Python             | Pylance + ruff (lint, format, tri des imports à l'enregistrement)     |
| Debugger           | debugpy — configurations dans `.vscode/launch.json`                   |
| Lint Odoo          | pylint-odoo (`.pylintrc`), `oca-checks-odoo-module`                   |
| XML / JS           | prettier + `@prettier/plugin-xml`, eslint (`eslint.config.mjs`)       |
| Hooks Git          | pre-commit (`.pre-commit-config.yaml`), identique en local et en CI   |
| Base de données UI | SQLTools (connexion « Odoo DB » préconfigurée)                        |

## Usage quotidien

- **Debug** : F5 → _Odoo : serveur_, _mettre à jour un module_, _tests d'un module_,
  _shell_. Odoo tourne avec `workers = 0` pour que les breakpoints soient fiables.
- **Auto-reload sans debugger** : tâche _Odoo : lancer (auto-reload, sans debug)_.
- **Tests** : tâche ou config de debug _tests d'un module_ (base `odoo20_test`).
- **Qualité** : les hooks tournent à chaque commit ; `pre-commit run --all-files` pour
  tout le dépôt.

## Arborescence

```
.devcontainer/   configuration du dev container
.vscode/         debug (launch.json) et tâches
addons/          addons du projet (dev_sample = module d'exemple, supprimable)
vendor/          modules achetés (Odoo Apps Store), tels quels
docker/          Dockerfile multi-stage et odoo.conf de dev
requirements.txt        dépendances Python des addons et modules OCA
requirements-dev.txt    outillage développeur (image dev uniquement)
```

## Modules tiers

| Origine         | Où                                  | Lint / tests CI |
| --------------- | ----------------------------------- | --------------- |
| Projet          | `addons/`                           | oui             |
| Odoo Apps Store | `vendor/` (voir `vendor/README.md`) | non             |
| OCA             | `requirements.txt` (pip)            | non             |

Ordre de recherche d'Odoo : `addons` → `vendor` → modules installés par pip → cœur.

### Modules OCA (pip)

Les modules OCA sont des paquets pip `odoo-addon-<module>`, installés dans `/opt/venv`
au build de l'image : même mécanisme en dev, en CI et en prod, sans `.git` dans l'image.
Odoo les trouve sans modifier `addons_path` (namespace `odoo.addons`) ; OdooLS via
`/opt/venv/odoo-addons` (`odools.toml`). Les dépendances OCA et Python du module sont
résolues par pip, contraintes par les versions apt de l'image.

1. Ajouter la ligne dans `requirements.txt`, **version figée** :
   - publié sur PyPI : `odoo-addon-<module>==20.0.x.y.z` ;
   - pas encore publié pour 20.0 :
     `odoo-addon-<module> @ git+https://github.com/OCA/<repo>@<sha>#subdirectory=<module>`
     (un sha de commit, pas une branche). Les dépendances OCA non publiées doivent aussi
     être listées.
2. Ajouter le module dans `depends` du manifest de votre module.
3. _Dev Containers : Rebuild Container_, puis installer le module (`-i <module>`).

Quand le module paraît sur PyPI, remplacer la ligne `git+…` par `==version`.

**Corriger ou déboguer un module OCA** : le code est dans le venv
(`/opt/venv/odoo-addons/<module>`), les breakpoints y fonctionnent. Pour le modifier,
cloner le dépôt dans `third-party/` (ignoré par git) et l'installer en éditable :

```sh
git clone -b 20.0 https://github.com/OCA/<repo> third-party/<repo>
pip install -e third-party/<repo>/<module>
```

Odoo utilise alors la copie clonée. Pour qu'OdooLS la voie aussi, ajouter
`"third-party/<repo>"` à `addons_paths` dans `odools.toml` (sans le committer).
L'installation éditable dure jusqu'au prochain rebuild. Proposer le correctif en PR à
l'OCA, puis figer `requirements.txt` sur le sha de la PR ou d'un fork de l'organisation
(un sha de PR non fusionnée peut disparaître).

## Spécificités Odoo 20.0

- Python 3.12 à 3.14, PostgreSQL 16 minimum.
- Droits d'accès : `security/ir.access.csv` (colonnes
  `id,name,model_id,group_id/id,operation,domain`, `model_id` = nom technique du modèle,
  `operation` = `crud`) remplace `ir.model.access.csv`.
- Données de démo désactivées par défaut (`with_demo = True` dans la conf de dev).
- Écoute par défaut sur `127.0.0.1` : la conf de dev force `http_interface = 0.0.0.0`.

## Image Odoo

L'image part de l'image officielle `odoo:20.0`, figée par **tag daté + digest** dans
`docker/Dockerfile` (`ARG ODOO_IMAGE`) : même base en dev et en prod, builds
reproductibles.

- Odoo est installé par paquet `.deb` : sources dans
  `/usr/lib/python3/dist-packages/odoo` (tous les addons dans `odoo/addons`).
- Les dépendances Python d'Odoo sont des paquets apt. Les dépendances du projet et
  l'outillage vont dans un venv `/opt/venv` (`--system-site-packages`) ;
  `/opt/venv/pip.conf` (contraintes) empêche pip de remplacer une version apt.
- Lancer Odoo avec `odoo` (= `/opt/venv/bin/odoo`, qui voit le venv), pas
  `/usr/bin/odoo` (Python système).

### Mettre à jour Odoo

```sh
docker buildx imagetools inspect odoo:20.0   # digest courant du tag 20.0
```

Reporter le tag daté (`20.0-AAAAMMJJ`) et le digest dans `ARG ODOO_IMAGE`, puis _Dev
Containers : Rebuild Container_.
