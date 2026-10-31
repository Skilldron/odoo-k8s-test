# Deployment on Kubernetes

The CI deploys the tested image to Kubernetes with the
[Odoo Helm chart](https://github.com/Skilldron/odoo-helm-chart): a review app for each
pull request, a staging instance for each release candidate, a preproduction mirror and
the production. This page covers the project side: environments, setup, and day-to-day
operations. The chart's own documentation covers its values, its update sequence and its
[operations](https://github.com/Skilldron/odoo-helm-chart/blob/main/docs/operations.md).

- [Environments](#environments)
- [How a deployment runs](#how-a-deployment-runs)
- [Setup](#setup)
- [Refresh staging from production](#refresh-staging-from-production)
- [Preproduction refreshed every night](#preproduction-refreshed-every-night)
- [Upgrading the chart](#upgrading-the-chart)
- [Rotating credentials](#rotating-credentials)

## Environments

| Environment  | Purpose                                                | Deployed image                                                  | Data                                                  |
| ------------ | ------------------------------------------------------ | --------------------------------------------------------------- | ----------------------------------------------------- |
| `review`     | try a pull request                                     | the pull request image                                          | empty database with demo data, reset with every image |
| `staging`    | user acceptance, configuration tests over several days | the last release candidate of `release/*`                       | copy of production, neutralized, refreshed on demand  |
| `preprod`    | mirror of production, hotfix validation                | the release candidates of `hotfix/*`, then the production image | copy of production, neutralized                       |
| `production` | live                                                   | `vX.Y.Z`, the promoted release candidate                        | real                                                  |

The branches follow [Git Flow](gitflow.md):

```
feature/* ──PR──► develop                        review app per pull request
release/X.Y.Z (from develop) ──push──► X.Y.Z-rc.N ──► staging
hotfix/X.Y.Z (from main)     ──push──► X.Y.Z-rc.N ──► preprod
tag vX.Y.Z on main ──► promotion of the last rc (same image) ──► production, then preprod
```

A release is tested in staging while `develop` moves on. A hotfix goes straight to
production, so its release candidate is tested on the production mirror, and staging
keeps the release under test. Production always receives exactly the image validated
before it.

Each environment is a values file, `deploy/values/<environment>.yaml` (hosts, resources,
Odoo options, Secret names), reviewed in pull requests like the code. No Odoo setting
and no secret goes through the workflows. `deploy/values.yaml`, loaded before it, holds
what depends on the image: its user (uid and gid 1000) and its addons directories. The
chart's defaults are those of the official `odoo` image: keep this file in step with
`docker/Dockerfile`.

## How a deployment runs

The `review`, `staging`, `preprod` and `production` jobs of `ci.yml` call the reusable
workflow `deploy.yml`, which runs:

1. **`deploy`** (`ci/deploy.sh`): preflight checks before any downtime (Secrets,
   database cluster, snapshot classes, no orphan restore point, cap of the review apps),
   then `helm upgrade --install`, then a smoke test through the Gateway. The chart's
   hooks stop Odoo, take a restore point, update the modules and validate the point. An
   image that is already deployed is left as it is. The pods carry the version of the
   image in the label `app.kubernetes.io/version`. The earlier entries of the
   environment in the repository's _Deployments_ become inactive and stay in the
   history.
2. **`restore`** (`ci/deploy-restore.sh`), persistent environments only, when `deploy`
   failed: restores the pending restore point into a new database cluster, switches the
   stable Service to it, and rolls the release back. Odoo is back on the previous image
   with the data it had when it was stopped. There is nothing to do without release or
   when the release is still deployed (the failure came from the preflight or the smoke
   test).

One deployment runs at a time per environment (per pull request for review apps); a
newer run waits, and only the newest waiting run is kept. The job summary shows the URL,
the restore points, and the logs of a failed hook Job. A cancelled run does not restore:
the next run finds the interrupted release, fails, and its `restore` job restores.

Review apps are removed when their pull request closes, with their entries in the
repository's _Deployments_, and a nightly sweep removes those missed (`cleanup.yml`).

## Setup

Once per project. The cluster requirements (Gateway API, CSI snapshots, CloudNativePG…)
are listed in the
[chart documentation](https://github.com/Skilldron/odoo-helm-chart#requirements).

1. **Namespaces**, one per environment, e.g. `acme-review`, `acme-staging`,
   `acme-preprod`, `acme-prod`.
2. **Persistent environments** (staging, preprod, production), in each namespace: the
   database cluster, its stable Service and the application Secret, configured as the
   chart requires
   ([database](https://github.com/Skilldron/odoo-helm-chart#database-of-a-persistent-instance),
   [application Secret](https://github.com/Skilldron/odoo-helm-chart#application-secret)),
   and once per cluster the `VolumeSnapshotClass` of the restore points, with
   `deletionPolicy: Delete`. The values files expect the Service `odoo-db`, the Secrets
   `odoo-db-credentials` and `odoo-app`, and the class `csi-snapclass`: adapt them to
   your names. Also install a recurring job that backs the filestore volume up outside
   the cluster, for example a Longhorn `RecurringJob` of task `backup`: the chart backs
   up the database only, and after a disaster the filestore comes from that backup
   ([Recover from a disaster](https://github.com/Skilldron/odoo-helm-chart/blob/main/docs/operations.md#recover-from-a-disaster)).
3. **Registry Secret** in every namespace, of type `docker-registry`, to pull the
   private images from GHCR, and its name in `image.pullSecrets` of the values files.
   GHCR needs a classic personal access token with `read:packages` (fine-grained tokens
   are not accepted), owned by a machine account that can read the packages; plan its
   rotation.

   ```sh
   kubectl -n <namespace> create secret docker-registry ghcr --docker-server=ghcr.io \
     --docker-username=<account> --docker-password=<token> \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

4. **CI access** in every namespace: a ServiceAccount limited to it, and its kubeconfig.

   ```sh
   kubectl -n acme-prod apply -f deploy/examples/ci-access.yaml
   deploy/examples/ci-kubeconfig.sh acme-prod > kubeconfig
   ```

   The cluster API must be reachable from the GitHub runners (or use self-hosted runners
   inside the cluster). The account can read every Secret of its namespace: Helm stores
   its releases in Secrets, which RBAC cannot tell apart from the others. The optional
   ClusterRole at the end of `ci-access.yaml` lets the preflight check the storage and
   snapshot classes; without it, those checks are skipped.

5. **GitHub environments** `review`, `staging`, `preprod` and `production`, each with
   the secret `KUBECONFIG` (`gh secret set KUBECONFIG --env production < kubeconfig`,
   then delete the file: it holds the token). Protect them: the code of any branch
   allowed to deploy to an environment can read its secret.
   - `staging`: deployment branches `release/*`;
   - `preprod`: branches `hotfix/*` and tags `v*`;
   - `production`: tags `v*`, with a ruleset that lets only maintainers create `v*`
     tags;
   - `review`: any internal branch can read its secret, so keep its namespace free of
     anything else. Its variable `REVIEW_MAX_APPS` caps the review apps (default 5).

   Required reviewers on `production` also hold its `restore` job: Odoo stays stopped
   until someone approves.

6. **Values**: set the hosts, the Gateway and the storage classes in
   `deploy/values/<environment>.yaml`.
7. **Enable** the deployments with the repository variable `DEPLOY_ENVIRONMENTS`,
   listing the environments to deploy, e.g. `review staging preprod production`. Without
   it, no deployment job runs.

The first deployment of a persistent environment creates the database, with the admin
password of the application Secret (`admin-user-password`).

## Refresh staging from production

Staging keeps its data between releases, so that configuration tests can last several
days. Refresh it from production on demand, when a test needs fresh data: recover the
latest production backup into a new database cluster of the staging namespace, copy the
filestore, switch the stable Service, then update staging with `neutralize=true`
([procedure](https://github.com/Skilldron/odoo-helm-chart/blob/main/docs/operations.md#copy-production-into-another-instance)).
The update hooks neutralize the copy (no outgoing mail, no scheduled actions, no calls
to external services) before Odoo starts, then update its modules from the production
version to the staging release candidate: the refresh also tests the real upgrade path.

## Preproduction refreshed every night

Not automated by this template: the steps below are the intended design, to run by hand
or to automate in a project. Rebuilding preproduction every night from the last
production backup proves every day that the backups can be restored:

1. a scheduled workflow recovers the nightly production backup from object storage into
   a new database cluster of the preprod namespace;
2. it copies the filestore, switches the stable Service and deploys the production image
   with `neutralize=true`;
3. a smoke test checks the result, and a failure raises an alert: the production backup
   may be unusable.

The filestore should be read from production and written to preprod's own storage: with
S3, a copy of the production bucket into the preprod bucket, or a storage module able to
read from one bucket and write to another; with a volume, a restore of the production
volume's backup taken to remote storage. When preprod or staging run in another
namespace or cluster, every copy comes from the remote backup storage chosen for
production.

## Upgrading the chart

The chart version is pinned in `deploy/chart.env` (`CHART_VERSION`), and its package is
pulled from `oci://ghcr.io/skilldron/charts/odoo`. To upgrade, read the
[release notes](https://github.com/Skilldron/odoo-helm-chart/releases), raise
`CHART_VERSION` in a pull request, and adapt the values files if needed:
`ci/values-lint.sh` (job `quality / chart`) renders every environment with the new
version. The next deployment of each environment applies it.

## Rotating credentials

| Credential                                | Rotation                                                                                                                 |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| CI access (`KUBECONFIG`)                  | delete the Secret `odoo-deploy-token`, apply `ci-access.yaml` again, run `ci-kubeconfig.sh` and update the GitHub secret |
| Registry token                            | run the `kubectl create secret docker-registry` command again in every namespace                                         |
| Application Secret                        | update the Secret, then `kubectl rollout restart deployment/odoo`                                                        |
| Database password (`odoo-db-credentials`) | update the Secret: CloudNativePG updates the password of the declared role; then restart Odoo                            |
