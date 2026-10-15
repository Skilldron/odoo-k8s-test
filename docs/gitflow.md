# Modèle de branches

## Projets créés depuis le modèle : Git Flow

Recommandé pour un vrai projet. Chaque branche correspond à un environnement, et la CI
([ci.md](ci.md)) publie l'image correspondante.

| Branche / événement            | Rôle                             | Image publiée    | Environnement |
| ------------------------------ | -------------------------------- | ---------------- | ------------- |
| `feature/<sujet>` → PR         | développement, revue             | `pr-<n>`         | review        |
| `develop`                      | intégration continue             | `develop`        | testing       |
| `release/x.y.z`                | stabilisation, validation métier | `x.y.z-rc.<run>` | recette       |
| `main` + tag `vX.Y.Z`          | production                       | `X.Y.Z`          | prod          |
| `hotfix/x.y.z` → PR sur `main` | correctif urgent de la prod      | `pr-<n>`         | review        |

```
feature/a ─┐   feature/b ─┐
develop ───●───────────────●──────────────●─────────────●──────►
                            \            / (back-merge)  ↑
release/1.2.0                ●──●──●────●                │
                                         \               │
main ─────────────────────────────────────●(v1.2.0)──●(v1.2.1)
                                                    ↑
hotfix/1.2.1 ───────────────────────────────────────●
```

### Règles

- **Merges en `--no-ff`** de `release/*` et `hotfix/*` vers `main` (« Create a merge
  commit » dans GitHub, pas de squash ni de rebase). Le commit de merge a alors le même
  tree que la branche testée en recette : la CI réutilise **la même image** et le tag
  `vX.Y.Z` ne fait que la promouvoir. Avec un squash, le tree diffère et la promotion
  échoue volontairement.
- `main` et `develop` ne reçoivent que des PR (règles de protection ci-dessous), CI
  verte obligatoire.
- Après une release ou un hotfix, **back-merge** de `main` dans `develop`.
- Versions SemVer : `vX.Y.Z` en prod ; la recette publie `X.Y.Z-rc.<run>` à chaque push
  sur `release/X.Y.Z`.

### Cycle d'une release

```sh
git switch develop && git pull
git switch -c release/1.2.0 && git push -u origin release/1.2.0   # → recette (1.2.0-rc.N)
# corrections éventuelles sur release/1.2.0, validation en recette
gh pr create --base main --head release/1.2.0 --title "Release 1.2.0"
gh pr merge release/1.2.0 --merge            # merge commit (--no-ff), pas --squash
git switch main && git pull
gh release create v1.2.0 --target main --title "v1.2.0" --generate-notes   # → image 1.2.0
gh pr create --base develop --head main --title "Back-merge v1.2.0"
```

`gh release create` crée le tag `v1.2.0` ; le job `promote` publie l'image `1.2.0`.

### Protéger les branches (une fois, à la création du projet)

```sh
gh api repos/{owner}/{repo}/rulesets --method POST --input - <<'EOF'
{
  "name": "main et develop",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/main", "refs/heads/develop"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1, "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false, "require_last_push_approval": false,
      "required_review_thread_resolution": true,
      "allowed_merge_methods": ["merge"]}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "required_status_checks": [{"context": "lint"}, {"context": "image"}]}}
  ]
}
EOF
```

`allowed_merge_methods: ["merge"]` impose le merge commit, condition de la promotion
sans rebuild.

## Le dépôt modèle lui-même

Une branche longue par version d'Odoo et par moyen de déploiement, sans Git Flow :

| Branche                  | Contenu                                   |
| ------------------------ | ----------------------------------------- |
| `20.0`, `19.0`, …        | environnement de dev, CI, image de prod   |
| `20.0-docker-deployment` | `20.0` + déploiement Docker (à venir)     |
| `20.0-k8s-deployment`    | `20.0` + déploiement Kubernetes (à venir) |

Les évolutions passent par une branche de travail et une PR vers la branche de version
(CI : lint, image, tests). Une évolution de `20.0` est ensuite fusionnée dans ses
branches de déploiement.

Un projet démarre depuis la branche qui lui convient (« Use this template » avec «
Include all branches », ou copie de la branche), puis la renomme en `main` et crée
`develop`.
