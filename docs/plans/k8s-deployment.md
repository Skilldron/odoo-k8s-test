# Plan — déploiement Kubernetes : review apps, CD recette et prod

Branche `20.0-k8s-deployment` : `20.0` + déploiement Kubernetes. Recherche préalable,
sources et alternatives écartées :
[k8s-deployment-recherche.md](k8s-deployment-recherche.md).

Décisions prises avec l'utilisateur (2026-10-16) :

- déploiement **poussé** par GitHub Actions avec un **chart Helm** fourni par le modèle
  ; runboat, Argo CD, Flux Operator et vCluster sont écartés (§1) ;
- **review app** pour chaque PR interne non draft (plafond 5) : la release reste en
  place, **la base repart de zéro à chaque nouvelle image** ;
- **recette** déployée automatiquement à chaque `X.Y.Z-rc.N`, **prod** au tag `vX.Y.Z`
  juste après la promotion ;
- recette et prod : **coupure courte** pendant la mise à jour, sans ancien pod en
  parallèle ; modules mis à jour par **`click-odoo-update`** (modules modifiés
  seulement) ;
- **point de restauration** avant chaque déploiement (snapshots à froid de la base et du
  filestore), **rollback automatique** si le déploiement échoue, sauvegardes nocturnes
  **hors cluster** ;
- stockage avec snapshots CSI, **Longhorn** en référence ; PostgreSQL par **CNPG** ;
- **`odoo.conf` produit par le chart** au démarrage du pod : réglages dans une
  ConfigMap, secrets dans des Secrets du cluster référencés par nom. La CI ne transmet
  que l'image ; la gestion des secrets peut passer à un outil dédié (External Secrets,
  Sealed Secrets, SOPS…) sans toucher à la CI ni au chart (§6.1) ;
- pas d'environnement `testing` (`develop`) pour l'instant ;
- **phase 0 sur `20.0`** : digest publié en sortie de la CI, `click-odoo-contrib` dans
  l'image.

## 1. Outillage retenu

| Option                                        | Verdict                                                                                                                                                                                                               |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| runboat (`sbidoul/runboat`)                   | Écarté : conçu pour les dépôts d'addons OCA (tarball GitHub anonyme, images oca-ci, installation au démarrage), pas de CD, API start/stop non authentifiée, un mainteneur. Sert de référence d'UX (plafond, Mailpit). |
| **GitHub Actions + Helm, déploiement poussé** | **Retenu** : déploie le digest testé au moment de l'événement, garde la règle « dernière rc poussée = recette », URL dans la PR, scripts exécutables en local.                                                        |
| Argo CD (ApplicationSet, générateur PR)       | Variante possible plus tard : composant à exploiter, polling de 30 min sans webhook, course avec la CI, tri semver incompatible avec la recette partagée.                                                             |
| Flux Operator (ResourceSet)                   | Écarté : mêmes coûts que le GitOps, cas d'une PR fermée sans merge non documenté.                                                                                                                                     |
| vCluster par PR                               | Écarté : environ 1 CPU et 2 GiB de control plane par PR.                                                                                                                                                              |

## 2. Workflow

```
PR interne non draft ─► quality ─► image (builds:pr-<n>) ─► review
    1er déploiement : helm install pr-<n> (namespace <projet>-review)
    image suivante  : helm upgrade ; prepare remet la base à zéro (démo + addons/)
    https://<projet>-pr-<n>.<REVIEW_DOMAIN>
PR fermée ─► cleanup : helm uninstall pr-<n>, suppression de builds:pr-<n>
Chaque nuit ─► sweep : review apps de PR fermées restantes

push release/X.Y.Z | hotfix/X.Y.Z ─► quality ─► image (X.Y.Z-rc.N) ─► recette
tag vX.Y.Z ─► promote (dernière rc ─► X.Y.Z, même digest) ─► production
    1. Odoo à 0 replica                                            ┐
    2. point de restauration : base (CNPG, à froid) + filestore    │ coupure
    3. helm upgrade : prepare ─► click-odoo-update                 │
    4. démarrage, smoke HTTPS                                      ┘
    échec en 3 ou 4 ─► rollback automatique (point de restauration + digest précédent)
```

|                      | review                                        | recette                                                 | production                      |
| -------------------- | --------------------------------------------- | ------------------------------------------------------- | ------------------------------- |
| Déclencheur          | PR interne non draft, après `image / publish` | push `release/*` ou `hotfix/*`, après `image / publish` | tag `v*`, après `promote`       |
| Contrôle GitHub      | `review / deploy`                             | `recette / deploy`                                      | `production / deploy`           |
| Environnement GitHub | `review`                                      | `recette` (branches `release/*`, `hotfix/*`)            | `production` (tags `v*`)        |
| Namespace            | `<projet>-review` (toutes les PR)             | `<projet>-recette`                                      | `<projet>-prod`                 |
| Release Helm         | `pr-<n>`                                      | `odoo`                                                  | `odoo`                          |
| Image                | `…/builds@sha256:…`                           | `…@sha256:…` (la rc)                                    | même digest que la rc           |
| PostgreSQL 18        | éphémère, dans la release                     | CNPG                                                    | CNPG                            |
| Données              | remises à zéro à chaque nouvelle image        | conservées                                              | conservées                      |
| Odoo                 | threadé (`workers=0`), Mailpit                | `workers=2`, Mailpit                                    | workers dimensionnés, vrai SMTP |

## 3. Comportement

### 3.1 Review apps

- **Contenu.** Une release `pr-<n>` par PR, dans le namespace partagé `<projet>-review`,
  avec :
  - Odoo, plus Mailpit en sidecar ;
  - un PostgreSQL 18 éphémère avec son volume ;
  - un volume `/var/lib/odoo` ;
  - des secrets générés une fois et conservés (mot de passe PostgreSQL, mot de passe
    maître, mot de passe admin) ;
  - les HTTPRoute d'Odoo et de Mailpit, et une NetworkPolicy.
- **Remise à zéro à chaque nouvelle image.** L'init container `prepare` compare le
  digest de l'image au marqueur stocké en base (`ir_config_parameter`). S'il diffère :
  1. suppression de la base et de son filestore ;
  2. création avec la démo (`--with-demo`) et installation des modules de `addons/` ;
  3. mot de passe admin, puis marqueur.

  Un champ supprimé ou renommé ne peut donc pas empêcher Odoo de démarrer, et chaque
  push revalide l'installation complète.

- **Redémarrage sans nouvelle image** (nœud drainé, crash). Le marqueur est identique,
  rien n'est réinitialisé : les saisies des testeurs restent jusqu'au push suivant.
- **Accès.**
  - Adresse : `https://<projet>-pr-<n>.<REVIEW_DOMAIN>`.
  - Identifiants (admin et mot de passe aléatoire de la PR) dans le résumé du job, le
    dépôt étant privé.
  - Filtre d'accès optionnel à la Gateway : liste d'IP ou basic auth, selon
    l'implémentation.
- **PR concernées.**
  - Uniquement les PR du dépôt : une PR de fork n'a pas les secrets.
  - Non draft : une PR est déployée au passage en « ready for review ».
  - Pas les branches `release/*` et `hotfix/*`, qui ont déjà la recette.
  - Au-delà de `REVIEW_MAX_APPS` (5) review apps, toute nouvelle review app est refusée
    avec un message explicite ; les existantes continuent d'être mises à jour.
  - Le ResourceQuota du namespace sert de filet.
- **Fin.**
  - Fermeture ou fusion de la PR : `helm uninstall pr-<n>`, qui supprime tout, volumes
    compris.
  - Le sweep nocturne rattrape les oublis.

### 3.2 Recette et prod : déploiement

`ci/deploy.sh` enchaîne :

1. **Vérification**, avant toute coupure : le Secret applicatif existe avec ses clés
   (§6.1), et le rendu Helm passe (`helm upgrade --dry-run=server`).
2. **Premier déploiement** (pas encore de release) :
   - installation ;
   - `prepare` initialise la base créée par CNPG (`-i` des modules de `addons/`, sans
     démo) et pose la référence d'empreintes de `click-odoo-update` ;
   - pas de point de restauration : il n'y a rien à protéger.
3. **Arrêt** : Odoo passe à 0 replica, et on attend la fin des pods. La coupure
   commence.
4. **Point de restauration**, étiqueté avec le digest en cours et le digest visé :
   - base : `Backup` CNPG `method: volumeSnapshot`, `online: false`. Le snapshot est à
     froid : Odoo est arrêté, donc le fencing ne gêne pas, et le snapshot ne dépend pas
     de l'archivage des WAL ;
   - filestore : `VolumeSnapshot` du volume `/var/lib/odoo` ;
   - attente de `readyToUse`. On garde les 3 derniers points (réglable).
5. **Mise à jour** :
   - `helm upgrade --wait` vers le nouveau digest (stratégie Recreate) ;
   - `prepare` lance `click-odoo-update` (modules dont l'empreinte a changé), puis pose
     le marqueur ;
   - Odoo démarre.
6. **Smoke test** : `/web/health` et `/web/login` en HTTPS sur l'hôte public. La coupure
   prend fin.
7. **Échec en 5 ou 6** : rollback automatique (§3.3). Le job échoue, avec le détail dans
   le résumé.

Pas de `--rollback-on-failure` Helm. Remettre l'ancienne image sur une base migrée
serait pire que l'échec, même si la migration n'est que partielle : Odoo committe après
chaque module, et `reset_modules_state()` ne fait que remettre les états des modules à
plat.

### 3.3 Rollback

Les restaurations CSI et CNPG créent de **nouveaux** volumes ; on ne remet pas un volume
en arrière sur place. Chaque environnement a donc une **génération** : un entier stocké
dans les valeurs de la release, qui suffixe le cluster CNPG (`<release>-pg-<g>`) et le
volume du filestore (`odoo-data-<g>`).

1. Odoo passe à 0 replica. On prend un snapshot de l'état en échec, gardé pour analyse.
2. Génération `g+1` :
   - un cluster CNPG restauré depuis le snapshot du point de restauration
     (`bootstrap.recovery.volumeSnapshots`) ;
   - un volume du filestore créé depuis son `VolumeSnapshot`.
3. `helm upgrade` avec la génération `g+1` et le **digest précédent**. Le marqueur est
   identique, donc `prepare` ne fait rien. Puis smoke test.
4. La génération `g`, en échec, reste en place pour analyse. Sa suppression est manuelle
   et documentée.

- **Automatique** seulement quand le déploiement échoue, avant la reprise du trafic :
  aucune saisie ne peut être perdue.
- **Manuel** ensuite, par le workflow `rollback` : choix de l'environnement et du point
  de restauration, avec une confirmation explicite. Les saisies faites depuis le point
  de restauration sont perdues, et le workflow le dit.
- **Filestore.** Il est adressé par contenu (SHA-1), et Odoo ne supprime un fichier
  qu'après un délai de grâce (GC quotidien). Une base restaurée retrouve donc ses
  fichiers ; le snapshot du filestore est le filet complet.

### 3.4 Sauvegardes et reprise après sinistre

Les snapshots restent dans le stockage du cluster : ils ne protègent pas d'une perte du
cluster. En plus, hors du cluster (bucket S3) :

- **base** : archivage continu des WAL et sauvegarde complète chaque nuit (CNPG, plugin
  Barman Cloud, `ScheduledBackup`). Cela permet une restauration à un instant donné.
  Rétention de 30 jours par défaut, réglable ;
- **filestore** : sauvegarde chaque nuit, par un job récurrent Longhorn vers sa cible
  S3, ou par Velero ;
- **secrets** : récupérables avec l'outil de l'équipe (Sealed Secrets, SOPS, External
  Secrets…) ; ils ne sont ni dans le dépôt ni dans GitHub (§6.1) ;
- **test de restauration** complet dans un namespace vierge, en phase 6 puis
  périodiquement (runbook).

Si les pièces jointes passent un jour sur S3 (`fs_attachment`, pas encore porté en
20.0), le versioning du bucket remplacera le snapshot du filestore.

## 4. Pré-requis

### Cluster(s)

1. Kubernetes **1.35 ou 1.36**.
   - La 1.34 arrive en fin de support le 2026-10-27, et CNPG 1.30 couvre 1.34 à 1.36.
   - Managé (Scaleway Kapsule, OVHcloud MKS…) ou auto-géré (k3s, Talos).
2. **Deux clusters recommandés**, l'un hors prod (review et recette), l'autre pour la
   prod. À défaut, un pool de nœuds dédié à la prod, car le code des PR tourne dans le
   cluster des reviews.
3. **Capacité** (estimation, mesurée en phase 6) :
   - review app : environ 0,4 vCPU et 1 GiB demandés, avec un pic de CPU à
     l'initialisation ;
   - recette : environ 1 vCPU et 3 GiB ;
   - prod : workers = CPU × 2 + 1, environ 6 utilisateurs par worker ;
   - exemple hors prod pour 5 review apps et la recette : 2 nœuds de 4 vCPU / 8 GiB.
4. Un plugin réseau qui applique les NetworkPolicy (Cilium, Calico ; k3s le fait
   nativement).
5. Pod Security Admission : namespaces `restricted`.
6. metrics-server.

### Stockage

7. **Longhorn** (référence du kit), ou un CSI qui gère les `VolumeSnapshot`.
   - CRD `snapshot.storage.k8s.io` et snapshot-controller.
   - Une `VolumeSnapshotClass` ; avec Longhorn, `type: snap` pour les points de
     restauration.
8. **StorageClasses :**
   - filestore : réplication Longhorn 2 ou 3, extension de volume ;
   - base : la doc CNPG conseille un seul réplica au niveau stockage (strict-local)
     quand PostgreSQL a ses propres réplicas. Avec une seule instance PostgreSQL, on
     garde la réplication Longhorn ;
   - reviews : `reclaimPolicy: Delete`.
9. Une cible de sauvegarde Longhorn (S3) pour le filestore.

### PostgreSQL

10. **CloudNativePG 1.30** et son **plugin Barman Cloud** ; la méthode de sauvegarde
    intégrée est dépréciée.
11. Un **bucket S3 hors du cluster** (WAL et sauvegardes complètes), avec ses
    identifiants.
12. PostgreSQL 18, base créée par CNPG, rôle Odoo non superutilisateur et propriétaire
    de la base.

Une base managée reste possible (mode `external` du chart), mais sans point de
restauration ni rollback automatique pour la base.

### Réseau, DNS, TLS

13. **Gateway API v1.6** (CRD du canal standard) et une implémentation conforme :
    Traefik, Envoy Gateway, Cilium, NGINX Gateway Fabric, Istio…
    - **Pas ingress-nginx**, qui est retiré.
    - Le `/websocket` d'Odoo doit passer.
14. Un LoadBalancer pour la Gateway : celui du fournisseur, ou ServiceLB / MetalLB.
15. **Une Gateway partagée** (exemple fourni) :
    - listeners HTTPS pour `*.<REVIEW_DOMAIN>` et pour les hôtes de recette et de prod ;
    - `allowedRoutes` filtré par label de namespace ;
    - redirection HTTP → HTTPS.
16. **cert-manager 1.21** avec le support Gateway API, et un ClusterIssuer Let's Encrypt
    :
    - DNS-01 pour le wildcard des reviews, ce qui demande un **jeton d'API du
      fournisseur DNS** ;
    - HTTP-01 suffit pour les hôtes fixes.
17. DNS : `*.<REVIEW_DOMAIN>` et les hôtes de recette et de prod pointent vers la
    Gateway.

### Registre et secrets

18. **Jeton GHCR** : un PAT **classique** `read:packages`, appartenant à un compte
    machine qui a accès aux paquets `<dépôt>` et `<dépôt>/builds`.
    - GHCR n'accepte pas les PAT fine-grained, et les jetons d'app expirent en 1 h.
    - Il est stocké en secret `docker-registry` `ghcr-pull` dans chaque namespace.
    - Sa rotation est à planifier.
19. **Secrets de recette et de prod**, créés dans le cluster, hors du dépôt et hors de
    GitHub, avec le nom et les clés attendus par le chart (§6.1) :
    - un Secret applicatif par namespace : `admin-passwd`, et `smtp-password` pour la
      prod ;
    - n'importe quel outil peut le produire : `kubectl`, Sealed Secrets, SOPS, External
      Secrets (Vault, gestionnaire du fournisseur cloud, Infisical…). Exemples dans
      `deploy/cluster/` ;
    - la connexion PostgreSQL vient du secret `<cluster>-app` de CNPG ;
    - pour les reviews, les secrets sont générés par le chart.

### Accès de la CI et GitHub

20. **API du cluster joignable depuis les runners GitHub.** Aucune IP fixe n'est
    documentée pour les runners standard. Sinon : runners « larger » à IP fixe, ou
    runners dans le cluster.
21. **Un ServiceAccount de déploiement par namespace**, avec un Role limité au namespace
    : ressources du chart, `deployments/scale`, `volumesnapshots`, et `backups` et
    `clusters` CNPG.
    - Son kubeconfig est produit par `deploy/cluster/ci-kubeconfig.sh`.
    - L'OIDC est un durcissement possible, selon le fournisseur.
22. **Environnements GitHub** `review`, `recette` et `production` :
    - secret `KUBECONFIG` dans chacun, seul secret côté GitHub ;
    - règles de branches et de tags (§2) ;
    - variable `REVIEW_MAX_APPS`. Les hôtes, le domaine des reviews, les namespaces et
      la Gateway sont dans `deploy/values/*.yaml`, versionnés et relus en PR.
23. **Ruleset sur les tags `v*`** : création réservée aux mainteneurs, puisqu'un tag
    déclenche une mise en prod.
24. Les pré-requis CI existants (rôle Admin sur les paquets). La CI v2 est verte sur
    GitHub (main, develop) depuis le 2026-10-16.

### Exploitation (recommandé, non fourni)

25. Logs, métriques et alertes : déploiement en échec, CrashLoopBackOff, sauvegarde
    manquée.
26. Une fenêtre de mise en prod : le tag coupe le service le temps de la mise à jour.

### Poste de dev

27. `kubectl`, Helm 4, kind et Docker. Le test de bout en bout installe en plus CNPG,
    csi-driver-host-path, snapshot-controller et MinIO dans kind (`ci/chart-e2e.sh`).

## 5. Phase 0 — sur `20.0`

- `image.yml` : le job `publish` expose `digest` (déjà écrit dans `$GITHUB_OUTPUT` par
  `ci/image-tag.sh`), remonté en sortie du workflow avec `refs` et `version`.
- `promote.yml` : même chose (`digest`, `version`).
- `requirements.txt` : `click-odoo-contrib`, version 1.24 ou plus (support d'Odoo 20).
- `docs/ci.md` : la section « Déployer soi-même » utilise `click-odoo-update` au lieu de
  `-u all`.

Vérification :

- actionlint ;
- image construite en local (`BASE=local`), puis `run-tests.sh` et `smoke.sh` ;
- `click-odoo-update` sur une base de test : le premier passage pose la référence, le
  deuxième ne fait rien, et un module modifié est le seul mis à jour.

## 6. Chart Helm — `deploy/chart/`

Un seul chart `odoo` pour les trois environnements, conforme à `kubernetes-patterns` :

- image référencée par digest ;
- non root (uid et gid 1000, `fsGroup`), seccomp `RuntimeDefault` ;
- racine en lecture seule, avec `/tmp` en `emptyDir` ;
- capabilities retirées, pas d'escalade de privilèges ;
- `automountServiceAccountToken: false` ;
- requests et limits partout ;
- sondes startup, liveness et readiness sur `/web/health` ;
- stratégie `Recreate`, 1 replica.

| Template                                        | Rôle                                                                                                                                                       |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deployment.yaml`                               | Odoo, init container `prepare` (même image), sidecar Mailpit (en option)                                                                                   |
| `service.yaml`                                  | 8069 ; 8072 (`appProtocol: kubernetes.io/ws`) si `workers` > 0 ; 8025 (Mailpit)                                                                            |
| `httproute.yaml`                                | Hôte Odoo (`/websocket` vers 8072 en multi-process), hôte Mailpit, filtres optionnels                                                                      |
| `pvc.yaml`                                      | `/var/lib/odoo` (filestore, sessions) : `odoo-data-<g>`, créé depuis un `VolumeSnapshot` au rollback ; `helm.sh/resource-policy: keep` hors review         |
| `postgres.yaml`                                 | Review : PostgreSQL 18 éphémère (Deployment, Service, volume monté sur `/var/lib/postgresql`)                                                              |
| `cnpg.yaml`                                     | Recette et prod : `Cluster` `<release>-pg-<g>` (PG 18, `keep`), `ScheduledBackup`, `ObjectStore` Barman Cloud ; bootstrap depuis les snapshots au rollback |
| `configmap-config.yaml`                         | `odoo.conf` complet généré depuis `odoo.config`, sans secret (§6.1)                                                                                        |
| `secrets.yaml`                                  | Review : mots de passe générés une fois, conservés via `lookup`                                                                                            |
| `networkpolicy.yaml`                            | Odoo joignable depuis la Gateway seulement ; PostgreSQL depuis l'Odoo de la release seulement                                                              |
| `serviceaccount.yaml`, `configmap-prepare.yaml` | Compte sans jeton ; script `prepare`                                                                                                                       |

**`values.yaml`** (avec `values.schema.json`) :

- image et digest ;
- `odoo.config` : sections et options d'`odoo.conf` (§6.1) ;
- `secrets` : nom du Secret applicatif, et variables `secrets.env` des modules ;
- modules à installer (par défaut tout `addons/`) et démo ;
- mode de `prepare` : `reset` ou `upgrade` ;
- base : `ephemeral`, `cnpg` ou `external` ;
- génération ;
- Gateway et hôtes (domaine des reviews), Mailpit, ressources.

Les valeurs par environnement sont dans
`deploy/values/{review,recette,production}.yaml`. La CI n'ajoute que le digest, et la
génération lors d'un rollback. L'hôte d'une review est déduit du nom de la release
(`<projet>-pr-<n>.<domaine des reviews>`).

### 6.1 Configuration d'Odoo et secrets

Le chart génère `odoo.conf`, pas la CI. Les réglages sont dans le dépôt et les secrets
dans le cluster. On peut donc confier les secrets à un outil dédié sans modifier la CI
ni le chart. Le pod ne fait aucun rendu au démarrage : Odoo 20 lit lui-même ses secrets
dans l'environnement.

- **Fichier généré par Helm.** `odoo.config` décrit le fichier **section par section** :
  chaque clé est une section INI, et sa valeur est la liste libre des options de cette
  section. `values.yaml` porte les valeurs par défaut, et chaque environnement les
  surcharge (les maps Helm fusionnent section par section).

  ```yaml
  odoo:
    config:
      options:
        workers: 4
        server_wide_modules: [base, web, queue_job]
      queue_job:
        channels: [root:2, root.channel1:1]
  ```

  donne, dans la ConfigMap `<release>-config` :

  ```ini
  [options]
  ; options imposées par le chart (voir plus bas), puis :
  server_wide_modules = base,web,queue_job
  workers = 4

  [queue_job]
  channels = root:2,root.channel1:1
  ```

  - Rendu : `[options]` d'abord, puis les autres sections par ordre alphabétique. Une
    liste devient une valeur séparée par des virgules, et un booléen devient
    `True`/`False`.
  - Odoo 20 ne lit que `[options]` : `config.misc` n'existe plus. Les modules qui ont
    leur propre section relisent le fichier eux-mêmes. Par exemple, queue_job (19.0 et
    20.0) ouvre `config["config"]` avec `ConfigParser(interpolation=None)` pour lire
    `[queue_job]`. Le chart écrit donc toutes les sections telles quelles, sans les
    valider.
  - Le chart impose dans `[options]` ce qui ne se règle pas : `addons_path`, `data_dir`,
    `http_interface`, `db_name` et `dbfilter` (nom de la base tiré des valeurs).
  - Le fichier est monté en lecture seule sur `/etc/odoo/odoo.conf`, avec
    `ODOO_RC=/etc/odoo/odoo.conf`. L'entrypoint de l'image ne rend alors rien (cas «
    configuration fournie » existant), et l'image ne change pas.
  - `values.schema.json` : noms de section et d'option en `[a-z0-9_.]`, valeurs
    scalaires ou listes de scalaires, sans retour à la ligne. Une option dont le nom
    contient `passw`, `secret` ou `token` est refusée dans toutes les sections : aucun
    secret ne finit dans le dépôt ni dans la ConfigMap.

- **Secrets en variables d'environnement** (`secretKeyRef`), lues nativement par
  Odoo 20. Chaque option du fichier a une variable `ODOO_<OPTION>`, et l'environnement
  passe avant le fichier. Vérifié dans l'image : `config.py` l.136, et un test avec
  `ODOO_WORKERS=5` qui l'emporte sur `workers = 3`.
  - `ODOO_ADMIN_PASSWD` et `ODOO_SMTP_PASSWORD` (optionnelle) depuis le Secret
    applicatif nommé dans `secrets.existingSecret` (clés `admin-passwd` et
    `smtp-password`) ;
  - `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` et `PGDATABASE` depuis le secret
    `<cluster>-app` de CNPG, ou depuis un Secret nommé en mode `external`. L'entrypoint
    officiel n'ajoute alors pas de `--db_*` ;
  - les secrets des modules, via `secrets.env` (`{name, secret, key}`). Par exemple
    `ODOO_QUEUE_JOB_HTTP_AUTH_PASSWORD`, que queue_job lit avant sa section.
    `ci/deploy.sh` vérifie aussi ces clés (§3.2) ;
  - le chart refuse qu'une option soit à la fois dans `odoo.config` et dans
    `secrets.env`. Sinon, la variable masquerait le fichier sans que ça se voie ;
  - en review, les Secrets sont générés par le chart (`secrets.yaml`, `randAlphaNum`
    conservé avec `lookup`). La CI ne transmet aucun mot de passe. Elle relit les
    identifiants dans le Secret pour le résumé du job.
- **Limite.** Pour un module qui lit **un secret** dans sa section, sans variable
  d'environnement de repli, ce secret devrait être écrit en clair dans le fichier, donc
  dans le dépôt. Le schéma l'interdit. Ce cas n'existe pas aujourd'hui (queue_job a ses
  variables) : on le traitera au cas par cas, et c'est documenté. Les réglages non
  secrets de ces modules passent sans problème par `odoo.config`.
- **Gestionnaire de secrets interchangeable.** Le chart a seulement besoin d'un Secret
  avec le bon nom et les bonnes clés. On peut le produire avec `kubectl create secret`,
  Sealed Secrets, SOPS ou un `ExternalSecret` (External Secrets Operator : Vault, AWS,
  GCP, Azure, Infisical…). Le chart ne crée pas d'`ExternalSecret` en v1 : un exemple
  est fourni dans `deploy/cluster/`.
- **Changements :**
  - quand la ConfigMap change, le pod redémarre (annotation `checksum/config`) ;
  - quand un secret change (rotation), le pod ne redémarre pas tout seul : il faut
    `kubectl rollout restart` ou Reloader (optionnel), et c'est documenté. En recette et
    en prod, le redémarrage coupe brièvement le service (Recreate).
- Le déploiement Docker garde les variables `ODOO_*` et le modèle de l'image, rendu par
  `render-config.py` (inchangé).

Écartés :

- rendre un modèle au démarrage du pod (`render-config.py`) : inutile, puisque Odoo 20
  lit ses secrets dans l'environnement ;
- mettre tout `odoo.conf` dans un Secret : les réglages et les secrets seraient
  mélangés, et on ne pourrait plus confier les secrets à un outil dédié ;
- un mot de passe de review aléatoire passé par la CI (`--set`) : le PostgreSQL de la
  review ne fixe son mot de passe qu'à la création de son volume, et la valeur serait
  copiée dans l'historique Helm.

**`deploy/chart/files/prepare.sh`** :

1. attend PostgreSQL ;
2. lit le marqueur ;
3. en mode `reset` (review), supprime et recrée la base avec la démo si le digest a
   changé ;
4. en mode `upgrade` (recette, prod), installe les modules si la base est vide, sinon
   lance `click-odoo-update` si le digest a changé ;
5. pose le marqueur.

Il s'arrête en erreur au moindre échec (aucun `|| true`).

L'image et le Dockerfile ne changent pas, à part l'ajout de `click-odoo-contrib` en
phase 0.

## 7. Scripts `ci/`

| Script                          | Rôle                                                                                                                                                                                                                                                                           |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ci/deploy.sh ENV IMAGE@DIGEST` | Valeurs de `deploy/values/ENV.yaml`, plus le digest. Review : plafond, puis `helm upgrade --install`. Recette et prod : arrêt, point de restauration, mise à jour, smoke HTTPS, rollback automatique en cas d'échec. Répare une release bloquée en « pending ». Résumé du job. |
| `ci/deploy-snapshot.sh`         | Point de restauration : création, attente, rétention                                                                                                                                                                                                                           |
| `ci/deploy-rollback.sh [POINT]` | Rollback (§3.3), appelé aussi par le workflow manuel                                                                                                                                                                                                                           |
| `ci/review-remove.sh N`         | `helm uninstall pr-<n>`                                                                                                                                                                                                                                                        |
| `ci/review-sweep.sh`            | Review apps des PR fermées (API GitHub) ; `DRY_RUN` et liste de PR factice pour les tests                                                                                                                                                                                      |
| `ci/chart-lint.sh`              | `helm lint`, rendu des trois environnements, kubeconform (avec les schémas des CRD), `odoo.conf` rendu comparé à un fichier attendu (sections, listes, booléens, secret en clair refusé)                                                                                       |
| `ci/chart-e2e.sh`               | kind avec CNPG, csi-driver-host-path et MinIO : scénarios de la phase 2, en local                                                                                                                                                                                              |

## 8. Workflows

- **`deploy.yml`** (nouveau, `workflow_call`) : job `deploy`.
  - `environment: {name, url}`.
  - Concurrence par environnement (et par PR pour les reviews), sans annulation.
  - Helm 4 épinglé, kubeconfig lu dans le secret d'environnement, puis `ci/deploy.sh`.
  - Aucune configuration d'Odoo ni aucun secret applicatif ne passe par le workflow ;
    l'URL de l'environnement GitHub est lue dans les valeurs.
- **`rollback.yml`** (nouveau, `workflow_dispatch`).
  - Entrées : environnement, point de restauration (le dernier par défaut),
    confirmation.
  - Pour la prod, on le lance sur un tag `v*`.
- **`ci.yml`** : trois nouveaux jobs, et le type `ready_for_review` est ajouté.
  - `review` : après `image`, pour une PR interne non draft, hors `release/*` et
    `hotfix/*`.
  - `recette` : après `image`, sur un push `release/**` ou `hotfix/**`.
  - `production` : après `promote`, sur un tag.
- **`cleanup.yml`** : job `review` à la fermeture d'une PR (`ci/review-remove.sh`), et
  `ci/review-sweep.sh` chaque nuit.
- **`quality.yml`** : job `chart` (`ci/chart-lint.sh`), ajouté aux contrôles requis dans
  `docs/gitflow.md`.
- **`.pre-commit-config.yaml`, `.prettierignore`** : les templates Helm sont exclus de
  prettier et de check-yaml (les `{{ }}` les cassent).

## 9. Kit d'amorçage — `deploy/cluster/`

Fichiers à appliquer une fois par cluster ou par projet. Ce sont des exemples, à adapter
:

- `namespaces.yaml` : namespaces, labels PSA `restricted`, label d'accès à la Gateway ;
- `review-quota.yaml` : ResourceQuota et LimitRange du namespace des reviews ;
- `ci-access.yaml` et `ci-kubeconfig.sh` : ServiceAccount, Role, RoleBinding, jeton, et
  kubeconfig pour GitHub ;
- `gateway.yaml` : Gateway partagée, listeners, redirection HTTPS ;
- `cert-manager.yaml` : ClusterIssuer (DNS-01 et HTTP-01), certificat wildcard des
  reviews ;
- `longhorn.yaml` : StorageClasses, `VolumeSnapshotClass`, job récurrent de sauvegarde
  du filestore ;
- `cnpg-objectstore.yaml` : `ObjectStore` Barman Cloud et identifiants S3 ;
- `app-secret.example.sh` : création du Secret applicatif avec `kubectl` (clés du §6.1)
  ;
- `external-secret.example.yaml` : le même Secret produit par External Secrets Operator
  ;
- `ghcr-pull-secret.sh` : crée le secret `ghcr-pull` dans un namespace.

## 10. Documentation

- `docs/deployment-kubernetes.md` :
  - pré-requis (§4), amorçage pas à pas, workflow ;
  - runbooks : rollback manuel, restauration après sinistre, recette rechargée depuis la
    prod neutralisée (`odoo db load -n`), rotation des jetons et des secrets (avec
    redémarrage), changement d'outil de gestion des secrets, suppression des générations
    inactives, dépannage.
- `README.md`, `docs/ci.md`, `docs/gitflow.md` : environnements désormais déployés,
  nouveaux jobs, contrôles requis.
- Ce plan : une note d'écarts en tête une fois implémenté.

## 11. Phases et vérification (`ecc:verification-loop`)

| Phase | Contenu                | Vérification                                                     |
| ----- | ---------------------- | ---------------------------------------------------------------- |
| 0     | §5, sur `20.0`         | Voir §5                                                          |
| 1     | Essais, avant le chart | Voir ci-dessous                                                  |
| 2     | Chart et `prepare.sh`  | `ci/chart-lint.sh` ; scénarios de `ci/chart-e2e.sh` ci-dessous   |
| 3     | Scripts `ci/`          | shellcheck ; exécution contre kind ; sweep sur une liste factice |
| 4     | Workflows              | actionlint, pre-commit                                           |
| 5     | Kit et documentation   | kubeconform, dry-run serveur sur kind                            |
| 6     | Validation réelle      | Scénarios ci-dessous, sur le dépôt de test et un vrai cluster    |

**Phase 1, essais :**

- les commandes Odoo 20 passent par notre entrypoint avec les variables `PG*` : création
  avec démo, mot de passe admin, `-i` sur une base vide existante, `click-odoo-update`
  (référence posée à l'installation) ;
- avec un `odoo.conf` monté (`ODOO_RC`) et les secrets en variables `ODOO_*` et `PG*` :
  `odoo`, `odoo db init`, `click-odoo-update` et le jobrunner de queue_job (section
  `[queue_job]`, `ODOO_QUEUE_JOB_HTTP_AUTH_PASSWORD`) lisent bien leur configuration ;
- le rendu PDF fonctionne avec la racine en lecture seule ; PostgreSQL 18 et Mailpit
  tournent en non-root (PSA `restricted`) ;
- CNPG sur kind :
  - sauvegarde `volumeSnapshot` à froid ;
  - restauration dans un nouveau cluster ;
  - snapshots qui survivent à la suppression du cluster ;
  - archivage des WAL d'une nouvelle génération ;
- un volume créé depuis un `VolumeSnapshot`. La durée de restauration avec Longhorn se
  mesure sur le vrai cluster, en phase 6.

**Phase 2, scénarios de `ci/chart-e2e.sh` :**

- review :
  - installation, avec `/web/health` et `/web/login` à 200 ;
  - nouvelle image → remise à zéro ;
  - redémarrage du pod → pas de remise à zéro ;
- recette :
  - première installation ;
  - mise à jour avec point de restauration ;
  - module cassé → rollback automatique (base, filestore et digest précédents) ;
  - rollback manuel.

**Phase 6, scénarios :**

1. PR → URL HTTPS, connexion, websocket (bus), mails visibles dans Mailpit ;
2. push → remise à zéro ; fermeture → suppression ;
3. draft → pas de review app, puis « ready for review » → review app ;
4. plafond atteint → refus explicite ;
5. `release/0.1.0` → recette (première installation) ; nouveau push → mise à jour avec
   point de restauration, coupure mesurée ;
6. hotfix pendant la release (cas 2) → la recette bascule sur le hotfix, puis revient ;
7. tag `v0.1.0` → prod ;
8. mise à jour cassée en recette → rollback automatique, puis rollback manuel ;
9. restauration après sinistre depuis S3, dans un namespace vierge ;
10. sweep et nettoyage nocturne.

## 12. Risques

| Risque                                                           | Mitigation                                                                                                 |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Rollback automatique incorrect (restauration CNPG ou volume)     | Testé en phases 1, 2 et 6 ; état en échec conservé ; génération précédente intacte                         |
| Restauration Longhorn lente sur un gros volume (copie)           | Mesurée en phase 6 et documentée                                                                           |
| Snapshot ≠ sauvegarde                                            | Sauvegardes nocturnes hors cluster et test de restauration                                                 |
| Review apps exposées (code des PR, démo)                         | Mot de passe aléatoire, NetworkPolicy, filtre d'accès, prod sur un autre cluster                           |
| API du cluster exposée, jeton longue durée                       | Role limité au namespace, règles d'environnement, ruleset des tags, rotation ; OIDC ou ARC en durcissement |
| Commandes Odoo 20 et `click-odoo-update` via l'entrypoint        | Phases 0 et 1, avant le chart                                                                              |
| Websockets selon l'implémentation Gateway                        | `appProtocol: kubernetes.io/ws`, testé en phase 6                                                          |
| Pas de haute disponibilité (1 pod, volume RWO)                   | Assumé en v1 et documenté                                                                                  |
| Run de PR annulé pendant `helm upgrade`                          | `ci/deploy.sh` répare la release bloquée ; aucune annulation des déploiements                              |
| Base managée (`external`) sans point de restauration automatique | Documenté ; CNPG par défaut                                                                                |
| Secret changé sans redémarrage d'Odoo                            | Runbook de rotation ; Reloader en option                                                                   |
| Secret applicatif absent ou clé manquante                        | Vérifié par `ci/deploy.sh` avant l'arrêt ; sinon le pod reste en `CreateContainerConfigError`              |

## 13. Hors périmètre (v1)

- environnement `testing` ;
- mise à zéro des review apps inactives (KEDA HTTP, Sablier) ;
- variante Argo CD ;
- rafraîchissement automatique de la recette depuis la prod ;
- haute disponibilité et page de maintenance ;
- mise à jour en ligne, avec l'ancien pod en parallèle ;
- review apps construites depuis une copie neutralisée de la prod.

## Mise en œuvre

- Branche `20.0-k8s-deployment` (worktree `.claude/worktrees/k8s`), créée depuis `20.0`
  (`2db0119`).
- Phase 0 sur une branche de travail issue de `20.0`. L'utilisateur la fusionne, puis
  `20.0-k8s-deployment` est rebasée sur `20.0`.
- Commits depuis l'image de dev (pre-commit) ; pas de push sans accord.
- Validation réelle :
  - dépôt de test privé `Skilldron/test-odoo-template` (remote `test`), supprimé après
    validation ;
  - un cluster à fournir (fournisseur, domaine, DNS).
