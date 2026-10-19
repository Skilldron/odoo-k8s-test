# Odoo Helm chart

Runs Odoo 20 on Kubernetes, either as disposable review apps or as persistent instances
on a [CloudNativePG](https://cloudnative-pg.io) cluster. Updates are safe by design: the
chart stops Odoo, takes a cold restore point, updates the modules, then restarts Odoo. A
failed update never serves a half-migrated database.

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Update sequence](#update-sequence)
- [Restore points](#restore-points)
- [Values](#values)
- [Operations](docs/operations.md): restoring, rolling back, recovering from a disaster,
  copying production

## Features

- **Two modes.** `ephemeral: true` is a review app: the chart creates its own PostgreSQL
  and Secrets, and every new image starts from an empty database with demo data.
  `ephemeral: false` (default) is a persistent instance whose data is kept, on a
  CloudNativePG cluster installed separately.
- **Updates in Helm hooks.** `helm upgrade` stops Odoo, takes the restore point, updates
  the modules with [`click-odoo-update`](https://github.com/acsone/click-odoo-contrib)
  (changed modules only), then starts the new image. Nothing can start Odoo between the
  snapshot and the module update, even a `helm upgrade` run by hand.
- **Cold restore points.** A CloudNativePG volume snapshot backup of the database, taken
  with Odoo stopped, and a snapshot of the filestore volume. Old points are purged
  automatically.
- **Configuration from values.** `odoo.conf` is generated from `odoo.config`, without
  any secret; passwords come from Kubernetes Secrets as environment variables, which
  Odoo 20 reads natively.
- **Image by digest only.** The image is always `repository@sha256:…`: what runs is what
  was tested.
- **Hardened pods.** Non-root, read-only root filesystem, no capabilities, no service
  account token in the Odoo pods; NetworkPolicies.
- **Gateway API.** One `HTTPRoute` for HTTP and, with `workers > 0`, the websocket
  (`/websocket`), and optionally [Mailpit](https://mailpit.axllent.org) to catch
  outgoing mail.

## Requirements

The chart installs no cluster component. It needs:

| Requirement                                                                                                            | Used for                | Tested with                                    |
| ---------------------------------------------------------------------------------------------------------------------- | ----------------------- | ---------------------------------------------- |
| Kubernetes and Helm 4                                                                                                  | everything              | Kubernetes 1.37, Helm 4.3                      |
| An Odoo 20 image following the [image contract](#image-contract)                                                       | Odoo and its Jobs       |                                                |
| A Gateway API implementation (`route.parentRefs`)                                                                      | public access, optional | Gateway API 1.6                                |
| A storage class for the filestore volume                                                                               | `odoo.persistence`      |                                                |
| **Persistent instances only:**                                                                                         |                         |                                                |
| CloudNativePG, with the database cluster installed separately                                                          | the database            | CloudNativePG 1.30, `cnpg/cluster` chart 0.9.0 |
| The Barman Cloud plugin and an S3-compatible object store, for the nightly backups and the write-ahead log archive     | disaster recovery       | plugin-barman-cloud 0.15                       |
| A CSI driver with volume snapshots, the snapshot controller, and a `VolumeSnapshotClass` with `deletionPolicy: Delete` | restore points          | csi-driver-host-path 1.18                      |
| A stable `Service` in front of the primary of the active database cluster                                              | the database connection |                                                |
| An application Secret (`secrets.existingSecret`)                                                                       | Odoo passwords          |                                                |

Several Odoo instances (`odoo.replicas > 1`) need a shared filestore: a `ReadWriteMany`
volume, or no volume with the filestore on S3.

### Image contract

The chart runs the image with uid 1000 and a read-only root filesystem, and expects:

- `/opt/odoo/entrypoint.sh`, which waits for PostgreSQL and runs its arguments;
- the addons in `/opt/odoo/addons` and `/opt/odoo/vendor`, the data directory
  `/var/lib/odoo`;
- `odoo` (Odoo 20 command line, with `odoo db init`) and `click-odoo-update` in the
  `PATH`;
- `psql`, used to name the restore point in the PostgreSQL write-ahead log.

## Install

A review app, for a quick look (the chart creates the database):

```sh
helm upgrade --install pr-42 ./deploy/chart -n odoo-review \
  --set ephemeral=true \
  --set image.repository=ghcr.io/acme/odoo/builds \
  --set image.digest=sha256:<digest> \
  --set 'route.parentRefs[0].name=gateway' --set route.reviewDomain=review.example.com
kubectl -n odoo-review rollout status deploy/pr-42
```

The commands use the chart from a local checkout (`./deploy/chart`); adapt the reference
to where you get it from. The review app above expects a Gateway named `gateway` in its
namespace; set `route.parentRefs[0].namespace` otherwise.

A persistent instance, in its own namespace:

1. Create the database credentials
   ([examples/database-credentials.example.sh](examples/database-credentials.example.sh)):
   the database cluster declares the role `odoo` with them, `CREATEDB` included, since
   Odoo creates its own database.
2. Install the database with the `cnpg/cluster` chart (with the Barman Cloud plugin and
   the Secret of its object store), then apply the volume snapshot settings it cannot
   set yet ([examples/cnpg-cluster.values.yaml](examples/cnpg-cluster.values.yaml)). The
   `VolumeSnapshotClass` must exist
   ([examples/longhorn-volumesnapshotclass.yaml](examples/longhorn-volumesnapshotclass.yaml)
   for Longhorn).
3. Create the stable Service
   ([examples/database-service.yaml](examples/database-service.yaml)) and the
   application Secret
   ([examples/app-secret.example.sh](examples/app-secret.example.sh)).
4. Write the values of the instance. The minimum:

   ```yaml
   environment: production
   image:
     repository: ghcr.io/acme/odoo
     pullSecrets: [ghcr]
   odoo:
     modules: [sale_management, acme_custom]
   secrets:
     existingSecret: odoo-app
   database:
     external: {host: odoo-db, secret: odoo-db-credentials}
   restorePoints:
     volumeSnapshotClass: csi-snapclass
   route:
     parentRefs: [{name: gateway, namespace: gateway-system}]
     host: odoo.example.com
   ```

5. Install Odoo. The first installation creates the database, so do not use `--wait`:
   the Odoo pods wait for the database, which a `post-install` Job creates.

   ```sh
   helm upgrade --install odoo ./deploy/chart -n odoo-prod -f values.yaml \
     --set image.digest=sha256:<digest>
   kubectl -n odoo-prod rollout status deploy/odoo --timeout=30m
   ```

6. Update with `--wait`, so that the release only succeeds once Odoo serves the new
   version:

   ```sh
   helm upgrade odoo ./deploy/chart -n odoo-prod -f values.yaml \
     --set image.digest=sha256:<new digest> --wait --timeout 60m
   ```

## Update sequence

| Step | Hook           | What happens                                                                                                                                |
| ---- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | `pre-upgrade`  | Job `stop-snapshot`: Odoo scaled to 0, restore point named in the write-ahead log, cold `Backup` of the database, snapshot of the filestore |
| 2    | `pre-upgrade`  | Job `migrate`: `odoo -i` installs the listed modules that are missing, then `click-odoo-update` updates the changed ones                    |
| 3    | —              | Helm applies the Deployments: new image, Odoo starts                                                                                        |
| 4    | `post-upgrade` | Job `validate`: the restore point becomes `validated`, old points are purged                                                                |

The first installation and review apps run `migrate` in `post-install` (and
`post-upgrade` for review apps): it creates the database with `odoo db init`, then
installs the modules. The Odoo pods wait for it in an init container.

**When an update fails**, Odoo stays stopped and the restore point stays `pending`.
Retrying the update reuses that point, if it is complete, instead of taking a new one;
an incomplete point (failed snapshot) is replaced, and deleted by the next successful
update. To go back, restore the point
([operations](docs/operations.md#restore-after-a-failed-update)): the module update
commits module by module, so the previous image cannot run on the half-migrated
database.

## Restore points

A restore point is a CloudNativePG `Backup` (method `volumeSnapshot`, offline), named
`<cluster>-preupgrade-r<revision>`, with labels under `labelPrefix`:

| Label                    | Values                                                                                             |
| ------------------------ | -------------------------------------------------------------------------------------------------- |
| `<prefix>/backup-type`   | `pre-upgrade`                                                                                      |
| `<prefix>/upgrade-state` | `pending` (update not validated yet), `validated` (update succeeded), `restored` (used to restore) |

The filestore snapshot is named in the annotation `<prefix>/filestore` and owned by the
`Backup`: deleting the `Backup` deletes the whole point. After each successful update,
`validate` keeps the `restorePoints.keep` newest `validated` and `restored` points and
deletes the others. It never deletes a complete `pending` point, and a purge error never
fails the update.

The database cluster must allow offline volume snapshots, which the `cnpg/cluster` chart
cannot set yet:

```sh
kubectl -n odoo-prod patch cluster odoo-db --type merge -p \
  '{"spec":{"backup":{"volumeSnapshot":{"className":"<VolumeSnapshotClass>","online":false,"snapshotOwnerReference":"backup"}}}}'
```

## Values

| Value                                                        | Default                | Description                                                                                                                                           |
| ------------------------------------------------------------ | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ephemeral`                                                  | `false`                | Disposable review app: own PostgreSQL and Secrets, demo data, reset with every image, no restore points                                               |
| `neutralize`                                                 | `false`                | Neutralize the database (`odoo neutralize`) before the module update; only on the command line, for the update that follows a copy of production data |
| `environment`                                                | `""`                   | Name of the environment, set as a label                                                                                                               |
| `project`                                                    | `odoo`                 | Prefix of the review app hosts                                                                                                                        |
| `labelPrefix`                                                | `odoo.haroldd.dev`     | Prefix of the chart's labels and annotations. Changing it hides the existing restore points from the chart                                            |
| `image.repository`, `image.digest`                           |                        | Odoo image, by digest (`sha256:…`)                                                                                                                    |
| `image.pullSecrets`                                          | `[]`                   | Registry Secrets                                                                                                                                      |
| `odoo.replicas`                                              | `1`                    | Odoo instances                                                                                                                                        |
| `odoo.modules`                                               | `[]`                   | Modules installed by the `migrate` Job; `base` when empty                                                                                             |
| `odoo.config.<section>.<option>`                             | see `values.yaml`      | `odoo.conf`. The chart sets `addons_path`, `data_dir` and `http_interface`; no option name may contain `passw` (password), `secret` or `token`        |
| `odoo.persistence.*`                                         | `ReadWriteOnce`, `5Gi` | Filestore volume; `enabled: false` for a filestore on S3; `existingClaim` to use a restored volume                                                    |
| `secrets.existingSecret`                                     |                        | Application Secret: `admin-passwd`, `admin-user-password` (first installation), optional `smtp-password`. Required unless `ephemeral`                 |
| `secrets.env`                                                | `[]`                   | More environment variables from Secrets: `{name, secret, key}`                                                                                        |
| `database.name`                                              | `odoo`                 | Odoo database                                                                                                                                         |
| `database.external.host`, `.port`, `.secret`                 |                        | Stable Service of the database cluster, and the Secret with `username` and `password`. Required unless `ephemeral`                                    |
| `database.ephemeral.*`                                       | `postgres:18`, `2Gi`   | PostgreSQL of a review app                                                                                                                            |
| `restorePoints.keep`                                         | `3`                    | Restore points kept after an update                                                                                                                   |
| `restorePoints.volumeSnapshotClass`                          |                        | Class of the filestore snapshot (`deletionPolicy: Delete`)                                                                                            |
| `restorePoints.timeoutSeconds`                               | `900`                  | Delay for the snapshots to be ready                                                                                                                   |
| `jobs.migrate.activeDeadlineSeconds`                         | `1800`                 | Maximum duration of the module update                                                                                                                 |
| `mailpit.enabled`                                            | `false`                | Catch outgoing mail in Mailpit                                                                                                                        |
| `route.parentRefs`, `.host`, `.mailpitHost`, `.reviewDomain` |                        | `HTTPRoute`; review apps are served at `<project>-<release>.<reviewDomain>`                                                                           |
| `networkPolicy.ingressFrom`                                  | `[]`                   | Sources allowed to reach Odoo (the Gateway); empty: any                                                                                               |

`values.schema.json` and the templates refuse inconsistent values: an image by tag, a
password in `odoo.conf`, several instances on a `ReadWriteOnce` volume, a missing
Secret…
