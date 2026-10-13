# Odoo 20.0 Community — dépôt modèle

Dépôt modèle pour développer des addons Odoo dans un **dev container** VS Code, avec
debugger, LSP Odoo, lint et formatage prêts à l'emploi.

Une branche par version d'Odoo (`20.0`, `19.0`, …), même architecture.

## Démarrage

Prérequis : Docker, VS Code et l'extension _Dev Containers_.

1. Ouvrir le dossier dans VS Code → **Reopen in Container**.
2. Lancer **Odoo : serveur** (F5) → <http://localhost:8069>, base `odoo20` par défaut.
3. Les e-mails envoyés par Odoo sont visibles dans Mailpit : <http://localhost:8025>.

Hors VS Code : `docker compose up -d` puis
`docker compose exec odoo /opt/odoo/odoo-bin -d odoo20`.

## Ce que contient l'environnement

| Besoin             | Outil                                                                |
| ------------------ | -------------------------------------------------------------------- |
| Image              | `docker/Dockerfile` (Ubuntu 24.04, Python 3.12, Odoo figé au commit) |
| Services           | `compose.yaml` : Odoo, PostgreSQL 16, Mailpit                        |
| LSP Odoo           | Extension `Odoo.odoo` (OdooLS), configurée par `odools.toml`         |
| Python             | Pylance + ruff (lint, format, tri des imports à l'enregistrement)    |
| Debugger           | debugpy — configurations dans `.vscode/launch.json`                  |
| Lint Odoo          | pylint-odoo (`.pylintrc`), `oca-checks-odoo-module`                  |
| XML / JS           | prettier + `@prettier/plugin-xml`, eslint (`eslint.config.mjs`)      |
| Hooks Git          | pre-commit (`.pre-commit-config.yaml`), identique en local et en CI  |
| Base de données UI | SQLTools (connexion « Odoo DB » préconfigurée)                       |

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
docker/          Dockerfile multi-stage et odoo.conf de dev
requirements.txt        dépendances Python des addons
requirements-dev.txt    outillage développeur (image dev uniquement)
```

## Spécificités Odoo 20.0

- Python 3.12 à 3.14, PostgreSQL 16 minimum.
- Droits d'accès : `security/ir.access.csv` (colonnes
  `id,name,model_id,group_id/id,operation,domain`, `model_id` = nom technique du modèle,
  `operation` = `crud`) remplace `ir.model.access.csv`.
- Données de démo désactivées par défaut (`with_demo = True` dans la conf de dev).
- Écoute par défaut sur `127.0.0.1` : la conf de dev force `http_interface = 0.0.0.0`.

## Mettre à jour Odoo

Modifier `ODOO_COMMIT` dans `docker/Dockerfile`, puis _Dev Containers : Rebuild
Container_.
