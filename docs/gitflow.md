# Branching model

## Projects created from the template: Git Flow

Recommended for a real project. Each branch maps to an environment, and the CI
([ci.md](ci.md)) publishes the matching image.

| Branch / event         | Role                           | Published image       | Environment |
| ---------------------- | ------------------------------ | --------------------- | ----------- |
| `feature/<topic>` → PR | development, review            | `builds:pr-<n>`       | review      |
| `develop`              | integration                    | `builds:develop`      | —           |
| `release/X.Y.Z`        | stabilization, user acceptance | `X.Y.Z-rc.<N>`        | staging     |
| `hotfix/X.Y.Z`         | urgent fix of production       | `X.Y.Z-rc.<N>`        | preprod     |
| `main` + tag `vX.Y.Z`  | production                     | `X.Y.Z` (rc promoted) | production  |

### Rules

- **SemVer versions.** A release prepares the next version (`release/1.3.0`), a hotfix
  fixes the version in production by bumping its patch (`hotfix/1.2.1`). The CI refuses
  a `release/` or `hotfix/` branch that is not `X.Y.Z`.
- **Everything is validated before production.** `release/*` and `hotfix/*` publish a
  release candidate on every push. A release is validated in staging, a hotfix in
  preprod, the mirror of production. The last rc is promoted to production when `vX.Y.Z`
  is tagged, without a rebuild.
- **The tag must carry exactly the code of the last rc.** Otherwise the promotion is
  refused (check of the `odoo.template.tree` label). The merge method (merge commit,
  squash) does not matter: only the content counts.
- `main` and `develop` only receive pull requests, with a green CI (protection below).
- After a release or a hotfix: **back-merge** into `develop` (or into the release in
  progress, see case 2).
- A hotfix does not disturb the release under test: staging keeps the release while
  preprod validates the hotfix.

### Release cycle

```sh
git switch develop && git pull
git switch -c release/1.3.0 && git push -u origin release/1.3.0   # → 1.3.0-rc.N in staging
# fixes on release/1.3.0, if any: each push publishes a new rc
gh pr create --base main --head release/1.3.0 --title "Release 1.3.0"
gh pr merge release/1.3.0 --merge
git switch main && git pull
gh release create v1.3.0 --target main --title "v1.3.0" --generate-notes   # → image 1.3.0
gh pr create --base develop --head main --title "Back-merge v1.3.0"
```

`gh release create` creates the `v1.3.0` tag; the `promote` job publishes the `1.3.0`
image.

### Hotfix, case 1: no release in progress

Production runs `1.2.0`.

```
main      ──●(v1.2.0)─────────────────────●(v1.2.1)──►
             \                            /    \
hotfix/1.2.1  ●── fix ──●── fix ──────────●     \ (back-merge)
                        │         │               \
                     1.2.1-rc.N  1.2.1-rc.N+1      ▼
                     (preprod)   (preprod)      develop
```

1. `git switch -c hotfix/1.2.1 main`, fix, push → `1.2.1-rc.N` in preprod.
2. Further fixes, if any: each push publishes a new rc.
3. Validated: merge into `main`, `gh release create v1.2.1` → the last rc is promoted to
   `1.2.1`.
4. Back-merge the hotfix into `develop`.

### Hotfix, case 2: release 1.3.0 is in staging

Production runs `1.2.0`, `release/1.3.0` has published `1.3.0-rc.1`.

```
main         ──●(v1.2.0)──────────────●(v1.2.1)─────────────●(v1.3.0)──►
                \                     /                     /
hotfix/1.2.1     ●── fix ── 1.2.1-rc ●─────┐               /
                                            ▼ (merge)       /
release/1.3.0  ●── 1.3.0-rc.1 ──────────────●── 1.3.0-rc.2 ●
               ↑                                          \
develop ───────●                                            ▼ (back-merge)
```

1. `hotfix/1.2.1` starts from `main` (production), not from the release. Push →
   `1.2.1-rc.N`.
2. Validation in preprod; staging keeps `1.3.0-rc.1` under test.
3. Merge into `main`, tag `v1.2.1` → `1.2.1-rc.N` promoted to `1.2.1`, deployed to
   production.
4. Merge the hotfix **into `release/1.3.0`** (the Git Flow rule while a release is in
   progress, instead of `develop`) → `1.3.0-rc.2` includes the fix and replaces the
   previous rc in staging.
5. Staging validated: merge `release/1.3.0` into `main`, tag `v1.3.0` → `1.3.0-rc.2`
   promoted to **`1.3.0`** (the release keeps its number).
6. Back-merge into `develop`: the fix arrives there with the release.

**Safety net**: if step 4 is forgotten, `main` holds the hotfix but not the last rc of
1.3.0; on the `v1.3.0` tag, the promotion is **refused** instead of sending a version
without the fix to production. Merge the hotfix into the release (new rc), validate,
then tag again.

### Protecting the branches (once, when the project is created)

```sh
gh api repos/{owner}/{repo}/rulesets --method POST --input - <<'EOF'
{
  "name": "main and develop",
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
        {"context": "quality / lint"}, {"context": "image / tests"},
        {"context": "image / smoke"}, {"context": "image / publish"}]}}
  ]
}
EOF
```

Checks are named `<group> / <job>`. A pull request from a fork goes through
`image / local` and publishes nothing: it does not satisfy these checks, and a
maintainer must take it over in a branch of the repository.

## The template repository itself

One long-lived branch per Odoo version and per deployment method, without Git Flow:

| Branch                   | Content                                       |
| ------------------------ | --------------------------------------------- |
| `20.0`, `19.0`, …        | development environment, CI, production image |
| `20.0-docker-deployment` | `20.0` + Docker deployment (planned)          |
| `20.0-k8s-deployment`    | `20.0` + Kubernetes deployment (planned)      |

Changes go through a work branch and a pull request to the version branch (CI: quality,
image, tests). A change to `20.0` is then merged into its deployment branches.

A project starts from the branch that fits it ("Use this template" with "Include all
branches", or a copy of the branch), then renames it to `main` and creates `develop`.
