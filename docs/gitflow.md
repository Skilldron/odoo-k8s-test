# Modèle de branches

## Projets créés depuis le modèle : Git Flow

Recommandé pour un vrai projet. Chaque branche correspond à un environnement, et la CI
([ci.md](ci.md)) publie l'image correspondante.

| Branche / événement    | Rôle                             | Image publiée       | Environnement |
| ---------------------- | -------------------------------- | ------------------- | ------------- |
| `feature/<sujet>` → PR | développement, revue             | `builds:pr-<n>`     | review        |
| `develop`              | intégration continue             | `builds:develop`    | testing       |
| `release/X.Y.Z`        | stabilisation, validation métier | `X.Y.Z-rc.<N>`      | recette       |
| `hotfix/X.Y.Z`         | correctif urgent de la prod      | `X.Y.Z-rc.<N>`      | recette       |
| `main` + tag `vX.Y.Z`  | production                       | `X.Y.Z` (rc promue) | prod          |

### Règles

- **Versions SemVer.** Une release prépare la version suivante (`release/1.3.0`), un
  hotfix corrige la version en prod en incrémentant son patch (`hotfix/1.2.1`). La CI
  refuse une branche `release/` ou `hotfix/` qui n'est pas `X.Y.Z`.
- **Tout passe par la recette.** `release/*` et `hotfix/*` publient une release
  candidate à chaque push ; c'est la dernière rc, validée en recette, qui est promue en
  prod au tag `vX.Y.Z`, sans rebuild.
- **Le tag doit porter exactement le code de la dernière rc.** Sinon la promotion est
  refusée (contrôle du label `odoo.template.tree`). Le mode de merge (merge commit,
  squash) n'a pas d'importance : seul le contenu compte.
- `main` et `develop` ne reçoivent que des PR, CI verte obligatoire (protection
  ci-dessous).
- Après une release ou un hotfix : **back-merge** dans `develop` (ou dans la release en
  cours, voir cas 2).
- La recette est **partagée** : quand une release et un hotfix sont en cours en même
  temps, le dernier déployé occupe l'environnement.

### Cycle d'une release

```sh
git switch develop && git pull
git switch -c release/1.3.0 && git push -u origin release/1.3.0   # → 1.3.0-rc.N en recette
# corrections éventuelles sur release/1.3.0 : chaque push publie une nouvelle rc
gh pr create --base main --head release/1.3.0 --title "Release 1.3.0"
gh pr merge release/1.3.0 --merge
git switch main && git pull
gh release create v1.3.0 --target main --title "v1.3.0" --generate-notes   # → image 1.3.0
gh pr create --base develop --head main --title "Back-merge v1.3.0"
```

`gh release create` crée le tag `v1.3.0` ; le job `promote` publie l'image `1.3.0`.

### Hotfix, cas 1 : aucune release en cours

La prod tourne en `1.2.0`.

```
main      ──●(v1.2.0)─────────────────────●(v1.2.1)──►
             \                            /    \
hotfix/1.2.1  ●── fix ──●── fix ──────────●     \ (back-merge)
                        │         │               \
                     1.2.1-rc.N  1.2.1-rc.N+1      ▼
                     (recette)   (recette)      develop
```

1. `git switch -c hotfix/1.2.1 main`, correctif, push → `1.2.1-rc.N` en recette.
2. Corrections éventuelles : chaque push publie une nouvelle rc.
3. Validé : merge dans `main`, `gh release create v1.2.1` → dernière rc promue en
   `1.2.1`.
4. Back-merge du hotfix dans `develop`.

### Hotfix, cas 2 : la release 1.3.0 est en recette

La prod tourne en `1.2.0`, `release/1.3.0` a publié `1.3.0-rc.1`.

```
main         ──●(v1.2.0)──────────────●(v1.2.1)─────────────●(v1.3.0)──►
                \                     /                     /
hotfix/1.2.1     ●── fix ── 1.2.1-rc ●─────┐               /
                                            ▼ (merge)       /
release/1.3.0  ●── 1.3.0-rc.1 ──────────────●── 1.3.0-rc.2 ●
               ↑                                          \
develop ───────●                                            ▼ (back-merge)
```

1. `hotfix/1.2.1` part de `main` (la prod), pas de la release. Push → `1.2.1-rc.N`.
2. Validation en recette : le hotfix y remplace temporairement `1.3.0-rc.1`.
3. Merge dans `main`, tag `v1.2.1` → `1.2.1-rc.N` promue en `1.2.1`, déployée en prod.
4. Merge du hotfix **dans `release/1.3.0`** (règle Git Flow quand une release est en
   cours, à la place de `develop`) → `1.3.0-rc.2` contient le correctif ; la recette
   repasse sur la release.
5. Recette validée : merge de `release/1.3.0` dans `main`, tag `v1.3.0` → `1.3.0-rc.2`
   promue en **`1.3.0`** (la release garde son numéro).
6. Back-merge dans `develop` : le correctif y arrive avec la release.

**Filet de sécurité** : si l'étape 4 est oubliée, `main` contient le hotfix mais pas la
dernière rc de 1.3.0 ; au tag `v1.3.0`, la promotion est **refusée** au lieu d'envoyer
en prod une version sans le correctif. Fusionner le hotfix dans la release (nouvelle
rc), valider, puis re-taguer.

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
      "required_review_thread_resolution": true}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "required_status_checks": [
        {"context": "quality / lint"}, {"context": "quality / chart"},
        {"context": "image / tests"},
        {"context": "image / smoke"}, {"context": "image / publish"}]}}
  ]
}
EOF
```

Les contrôles portent le nom `<groupe> / <job>`. Une PR de fork passe par
`image / local` et ne publie rien : elle ne satisfait pas ces contrôles et doit être
reprise dans une branche du dépôt par un mainteneur.

## Le dépôt modèle lui-même

Une branche longue par version d'Odoo et par moyen de déploiement, sans Git Flow :

| Branche                  | Contenu                                   |
| ------------------------ | ----------------------------------------- |
| `20.0`, `19.0`, …        | environnement de dev, CI, image de prod   |
| `20.0-docker-deployment` | `20.0` + déploiement Docker (à venir)     |
| `20.0-k8s-deployment`    | `20.0` + déploiement Kubernetes (à venir) |

Les évolutions passent par une branche de travail et une PR vers la branche de version
(CI : qualité, image, tests). Une évolution de `20.0` est ensuite fusionnée dans ses
branches de déploiement.

Un projet démarre depuis la branche qui lui convient (« Use this template » avec «
Include all branches », ou copie de la branche), puis la renomme en `main` et crée
`develop`.
