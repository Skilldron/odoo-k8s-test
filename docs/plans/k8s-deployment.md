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
- **le chart définit le déploiement** : Odoo démarre à 0 replica, un **Job** prépare la
  base (initialisation ou mise à jour), puis Odoo passe à 1 replica. Le pod Odoo ne
  touche jamais au schéma de la base (§3, §6.2) ;
- **remise à zéro de la base réservée aux reviews** : un Job distinct, que le chart ne
  rend qu'avec une base qu'il crée lui-même (PostgreSQL éphémère) et refuse en
  production, au rendu comme à l'exécution (§6.3) ;
- **point de restauration** avant chaque déploiement (snapshots à froid de la base et du
  filestore), **rollback automatique** si le déploiement échoue ;
- **`odoo.conf` généré par le chart** (ConfigMap, sans secret) ; secrets dans des
  Secrets du cluster, lus nativement par Odoo 20 en variables d'environnement. La CI ne
  transmet que l'image (§6.1) ;
- **neutralisation** seulement quand une copie de la prod arrive en recette
  (rafraîchissement, runbook) ; jamais pendant un déploiement ;
- **le modèle exige des fonctions du cluster, il n'installe rien** : Gateway API, CSI
  avec snapshots, CNPG… sont des pré-requis installés par les administrateurs, avec les
  produits de leur choix (§4) ;
- pas d'environnement `testing` (`develop`) pour l'instant ;
- **phases 0 et 0 bis sur `20.0`** : digest publié en sortie de la CI,
  `click-odoo-contrib` dans l'image, configuration statique de l'image sans rendu au
  démarrage.

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
    helm upgrade --install pr-<n> (namespace <projet>-review), Odoo à 0
    Job reset : base supprimée, recréée avec la démo + modules de addons/
    Odoo à 1 ─► https://<projet>-pr-<n>.<domaine des reviews>
PR fermée ─► cleanup : helm uninstall pr-<n>, suppression de builds:pr-<n>
Chaque nuit ─► sweep : review apps de PR fermées restantes

push release/X.Y.Z | hotfix/X.Y.Z ─► quality ─► image (X.Y.Z-rc.N) ─► recette
tag vX.Y.Z ─► promote (dernière rc ─► X.Y.Z, même digest) ─► production
    1. helm upgrade, Odoo à 0 replica                               ┐
    2. point de restauration : base (CNPG, à froid) + filestore     │ coupure
    3. Job migrate : -i (base vide) ou click-odoo-update            │
    4. Odoo à 1 replica, smoke HTTPS                                ┘
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
| PostgreSQL 18        | éphémère, créé par le chart                   | CNPG                                                    | CNPG                            |
| Job de déploiement   | `reset`                                       | `migrate`                                               | `migrate`                       |
| Données              | remises à zéro à chaque nouvelle image        | conservées                                              | conservées                      |
| Odoo                 | threadé (`workers=0`), Mailpit                | `workers=2`, Mailpit                                    | workers dimensionnés, vrai SMTP |

## 3. Comportement

### 3.1 Review apps

- **Contenu.** Une release `pr-<n>` par PR, dans le namespace partagé `<projet>-review`,
  avec :
  - Odoo, plus Mailpit en sidecar ;
  - un PostgreSQL 18 éphémère, créé par le chart, avec son volume ;
  - un volume `/var/lib/odoo` ;
  - des secrets générés une fois et conservés (mot de passe PostgreSQL, mot de passe
    maître, mot de passe admin) ;
  - les HTTPRoute d'Odoo et de Mailpit, et une NetworkPolicy.
- **Remise à zéro à chaque nouvelle image.** `ci/deploy.sh` (§3.2) passe Odoo à 0, puis
  lance le Job `reset` (§6.3) :
  1. suppression de la base et de son filestore ;
  2. création avec la démo et installation des modules de `addons/` ;
  3. mot de passe admin.

  Un champ supprimé ou renommé ne peut donc pas empêcher Odoo de démarrer, et chaque
  push revalide l'installation complète.

- **Redémarrage sans nouvelle image** (nœud drainé, crash). Seul le pod Odoo redémarre :
  aucun Job ne tourne, rien n'est réinitialisé. Les saisies des testeurs restent
  jusqu'au push suivant.
- **Pas de neutralisation** : la base vient de la démo, et le serveur mail factice de la
  neutralisation empêcherait les mails d'arriver dans Mailpit.
- **Accès.**
  - Adresse : `https://<projet>-pr-<n>.<domaine des reviews>`.
  - Identifiants (admin et mot de passe aléatoire de la PR) dans le résumé du job, relus
    dans le Secret de la release, le dépôt étant privé.
  - Filtre d'accès optionnel à la Gateway : liste d'IP ou basic auth, selon
    l'implémentation.
- **PR concernées.**
  - Uniquement les PR du dépôt : une PR de fork n'a pas les secrets.
  - Non draft : une PR est déployée au passage en « ready for review ».
  - Pas les branches `release/*` et `hotfix/*`, qui ont déjà la recette.
  - Au-delà de `REVIEW_MAX_APPS` (5) review apps, toute nouvelle review app est refusée
    avec un message explicite ; les existantes continuent d'être mises à jour.
  - Le ResourceQuota du namespace, s'il existe, sert de filet.
- **Fin.**
  - Fermeture ou fusion de la PR : `helm uninstall pr-<n>`, qui supprime tout, volumes
    compris.
  - Le sweep nocturne rattrape les oublis.

### 3.2 Déploiement : `ci/deploy.sh`

Le chart décrit les étapes (valeurs `odoo.replicas`, `jobs.migrate.run`,
`jobs.reset.run`) ; `ci/deploy.sh` les enchaîne avec le même chart et les mêmes valeurs,
en ne changeant que ces trois réglages :

1. **Vérification**, avant toute coupure :
   - les fonctions du cluster attendues par les valeurs sont là (CRD Gateway API et
     CNPG, `VolumeSnapshotClass`, StorageClass, Gateway, `ObjectStore`) ;
   - le Secret applicatif existe avec ses clés (§6.1) ;
   - le rendu passe (`helm upgrade --dry-run=server`).

   Si quelque chose manque, on s'arrête ici avec un message clair, sans coupure.

2. **Arrêt** : `helm upgrade --install` avec le nouveau digest et `odoo.replicas=0`. Les
   ressources sont créées ou mises à jour (ConfigMap, Secrets, base, volumes), mais
   aucun pod Odoo ne tourne. On attend la fin des pods. En recette et en prod, la
   coupure commence.
3. **Point de restauration** (recette et prod, sauf premier déploiement), étiqueté avec
   le digest en cours et le digest visé :
   - base : `Backup` CNPG `method: volumeSnapshot`, `online: false`. Le snapshot est à
     froid : Odoo est arrêté, donc le fencing ne gêne pas, et le snapshot ne dépend pas
     de l'archivage des WAL ;
   - filestore : `VolumeSnapshot` du volume `/var/lib/odoo` ;
   - attente de `readyToUse`. On garde les 3 derniers points (réglable).
4. **Job** : `helm upgrade` avec `jobs.migrate.run=true` (recette, prod) ou
   `jobs.reset.run=true` (review), Odoo toujours à 0. Puis
   `kubectl wait --for=condition=complete` sur le Job, avec un délai réglable. Un échec
   du Job fait échouer le déploiement, avec ses logs dans le résumé.
5. **Démarrage** : `helm upgrade` avec `odoo.replicas=1 --wait`, puis smoke test :
   `/web/health` et `/web/login` en HTTPS sur l'hôte public. La coupure prend fin.
6. **Échec en 4 ou 5** (recette, prod) : rollback automatique (§3.3). Le job échoue,
   avec le détail dans le résumé.

Chaque déploiement crée donc trois révisions Helm ; l'historique est limité
(`--history-max`). Le premier déploiement suit les mêmes étapes, sans point de
restauration : le Job `migrate` voit une base vide et l'initialise.

Pas de hooks Helm : `pre-install` tourne avant que les Secrets et la base existent, et
`pre-upgrade` pendant que l'ancien pod sert encore.

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
2. `helm upgrade` avec la génération `g+1`, le **digest précédent** et Odoo à 0 :
   - un cluster CNPG restauré depuis le snapshot du point de restauration
     (`bootstrap.recovery.volumeSnapshots`) ;
   - un volume du filestore créé depuis son `VolumeSnapshot`.
3. Pas de Job : la base restaurée correspond déjà au digest précédent. Odoo passe à 1
   replica, puis smoke test.
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
cluster. Hors du cluster :

- **base** : archivage continu des WAL et sauvegarde complète chaque nuit vers l'
  `ObjectStore` fourni par l'administrateur (CNPG, plugin Barman Cloud,
  `ScheduledBackup` créé par le chart). Cela permet une restauration à un instant donné.
  Rétention de 30 jours par défaut, réglable ;
- **filestore** : sauvegarde hors cluster recommandée, à la charge de l'administrateur
  avec l'outil de son choix (job récurrent de son stockage, Velero…). Documenté comme
  pré-requis recommandé ;
- **secrets** : récupérables avec l'outil de l'équipe (Sealed Secrets, SOPS, External
  Secrets…) ; ils ne sont ni dans le dépôt ni dans GitHub (§6.1) ;
- **test de restauration** complet dans un namespace vierge, en phase 6 puis
  périodiquement (runbook).

Si les pièces jointes passent un jour sur S3 (`fs_attachment`, pas encore porté en
20.0), le versioning du bucket remplacera le snapshot du filestore.

### 3.5 Neutralisation

La neutralisation d'Odoo 20 est une opération sur la base, pas un mode de lancement
(`odoo neutralize`, `odoo db load -n`, `odoo db duplicate -n`). Elle applique le
`data/neutralize.sql` de chaque module installé : crons désactivés (sauf l'autovacuum),
serveurs mail désactivés et remplacés par un serveur factice, `database.secret` changé,
webhooks, paiements et EDI neutralisés.

- Elle se fait **quand une copie de la prod arrive en recette** : runbook de
  rafraîchissement avec `odoo db load -n` (v1).
- Jamais pendant un déploiement : rejouée à chaque mise à jour, elle recouperait les
  crons réactivés par les testeurs et changerait `database.secret`.
- Ni en review (base de démo, Mailpit), ni en prod.

## 4. Pré-requis

Le modèle **n'installe rien dans le cluster**. Il exige des fonctions, que les
administrateurs installent et exploitent avec les produits de leur choix. Les produits
cités sont des exemples. `ci/deploy.sh` vérifie ces fonctions avant de déployer (§3.2).

### Cluster(s)

1. Kubernetes **1.35 ou 1.36**.
   - La 1.34 arrive en fin de support le 2026-10-27, et CNPG 1.30 couvre 1.34 à 1.36.
   - Managé ou auto-géré, au choix.
2. **Deux clusters recommandés**, l'un hors prod (review et recette), l'autre pour la
   prod. À défaut, un pool de nœuds dédié à la prod, car le code des PR tourne dans le
   cluster des reviews.
3. **Capacité** (estimation, mesurée en phase 6) :
   - review app : environ 0,4 vCPU et 1 GiB demandés, avec un pic de CPU pendant le Job
     `reset` ;
   - recette : environ 1 vCPU et 3 GiB ;
   - prod : workers = CPU × 2 + 1, environ 6 utilisateurs par worker ;
   - exemple hors prod pour 5 review apps et la recette : 2 nœuds de 4 vCPU / 8 GiB.
4. Les **NetworkPolicy appliquées** par le plugin réseau.
5. Pod Security Admission : le chart est compatible `restricted`.
6. Les **namespaces** du projet, créés par l'administrateur (quota et LimitRange
   recommandés pour celui des reviews).

### Stockage

7. Un **CSI qui gère les `VolumeSnapshot`** : CRD `snapshot.storage.k8s.io`,
   snapshot-controller et une `VolumeSnapshotClass` (Longhorn, Rook-Ceph, CSI du
   fournisseur cloud…).
8. Des **StorageClasses** pour le filestore, la base et les reviews
   (`reclaimPolicy: Delete` conseillé pour les reviews). Le chart les prend par nom dans
   les valeurs.
9. Recommandé : une sauvegarde hors cluster du filestore (§3.4).

### PostgreSQL

10. L'opérateur **CloudNativePG 1.30** et son **plugin Barman Cloud** ; la méthode de
    sauvegarde intégrée est dépréciée.
11. Un **`ObjectStore`** Barman Cloud dans chaque namespace de recette et de prod, vers
    un bucket S3 hors du cluster, avec ses identifiants. Le chart le référence par nom.
12. Le chart crée le `Cluster` CNPG : PostgreSQL 18, rôle Odoo non superutilisateur et
    propriétaire de la base.

Une base managée reste possible (mode `external` du chart), mais sans point de
restauration ni rollback automatique pour la base.

### Réseau, DNS, TLS

13. Une **implémentation de Gateway API v1.6** (canal standard) et une **Gateway**
    fournie par l'administrateur :
    - listeners HTTPS pour `*.<domaine des reviews>` et pour les hôtes de recette et de
      prod, avec leurs certificats (wildcard pour les reviews) gérés comme
      l'administrateur l'entend ;
    - `allowedRoutes` qui accepte les namespaces du projet ;
    - le `/websocket` d'Odoo doit passer ;
    - pas ingress-nginx, qui est retiré.

    Le chart ne crée que des `HTTPRoute` rattachées à cette Gateway (valeur
    `gateway.parentRefs`).

14. DNS : `*.<domaine des reviews>` et les hôtes de recette et de prod pointent vers la
    Gateway.

### Registre et secrets

15. **Jeton GHCR** : un PAT **classique** `read:packages`, appartenant à un compte
    machine qui a accès aux paquets `<dépôt>` et `<dépôt>/builds`.
    - GHCR n'accepte pas les PAT fine-grained, et les jetons d'app expirent en 1 h.
    - Il est stocké en secret `docker-registry` dans chaque namespace (nom dans les
      valeurs).
    - Sa rotation est à planifier.
16. **Secrets de recette et de prod**, créés dans le cluster, hors du dépôt et hors de
    GitHub, avec le nom et les clés attendus par le chart (§6.1) :
    - un Secret applicatif par namespace : `admin-passwd`, et `smtp-password` pour la
      prod ;
    - n'importe quel outil peut le produire : `kubectl`, Sealed Secrets, SOPS, External
      Secrets (Vault, gestionnaire du fournisseur cloud, Infisical…). Exemples dans
      `deploy/examples/` ;
    - la connexion PostgreSQL vient du secret `<cluster>-app` de CNPG ;
    - pour les reviews, les secrets sont générés par le chart.

### Accès de la CI et GitHub

17. **API du cluster joignable depuis les runners GitHub.** Aucune IP fixe n'est
    documentée pour les runners standard. Sinon : runners « larger » à IP fixe, ou
    runners dans le cluster.
18. **Un ServiceAccount de déploiement par namespace**, avec un Role limité au
    namespace. Le modèle documente les permissions nécessaires et fournit un Role de
    référence (`deploy/examples/ci-access.yaml`) que l'administrateur applique ou adapte
    : ressources du chart, `jobs`, `deployments/scale`, `volumesnapshots`, et `backups`
    et `clusters` CNPG.
    - `deploy/examples/ci-kubeconfig.sh` produit son kubeconfig.
    - L'OIDC est un durcissement possible, selon le fournisseur.
19. **Environnements GitHub** `review`, `recette` et `production` :
    - secret `KUBECONFIG` dans chacun, seul secret côté GitHub ;
    - règles de branches et de tags (§2) ;
    - variable `REVIEW_MAX_APPS`. Les hôtes, le domaine des reviews, les namespaces et
      la Gateway sont dans `deploy/values/*.yaml`, versionnés et relus en PR.
20. **Ruleset sur les tags `v*`** : création réservée aux mainteneurs, puisqu'un tag
    déclenche une mise en prod.
21. Les pré-requis CI existants (rôle Admin sur les paquets). La CI v2 est verte sur
    GitHub (main, develop) depuis le 2026-10-16.

### Exploitation (recommandé, non fourni)

22. Logs, métriques et alertes : déploiement en échec, CrashLoopBackOff, sauvegarde
    manquée.
23. Une fenêtre de mise en prod : le tag coupe le service le temps de la mise à jour.

### Poste de dev

24. `kubectl`, Helm 4, kind et Docker. Pour ses propres tests, `ci/chart-e2e.sh`
    installe dans kind CNPG, csi-driver-host-path, snapshot-controller, une
    implémentation Gateway API et MinIO. Ce n'est pas une installation de référence pour
    un cluster.

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

## 5 bis. Phase 0 bis — sur `20.0`

Plus de rendu de configuration au démarrage, Docker comme Kubernetes :

- suppression de `docker/render-config.py` et `docker/odoo.conf.template` ;
- `docker/odoo.conf` statique, sans secret (`ODOO_RC`), avec seulement ce qui diffère
  des défauts d'Odoo ;
- `docker/entrypoint.sh` : garde shell sur `ODOO_ADMIN_PASSWD` et les variables `PG*`,
  puis l'entrypoint officiel ;
- `docs/ci.md` : même contrat de variables, plus la règle `ODOO_<OPTION>`.

Vérification : image construite en local, `run-tests.sh`, `smoke.sh`, configuration lue
par Odoo (défauts du fichier, surcharge `ODOO_WORKERS`, secrets), arrêt si une variable
manque, `click-odoo-update` via l'entrypoint avec la racine en lecture seule.

## 6. Chart Helm — `deploy/chart/`

Un seul chart `odoo` pour les trois environnements, conforme à `kubernetes-patterns` :

- image référencée par digest ;
- non root (uid et gid 1000, `fsGroup`), seccomp `RuntimeDefault` ;
- racine en lecture seule, avec `/tmp` en `emptyDir` ;
- capabilities retirées, pas d'escalade de privilèges ;
- `automountServiceAccountToken: false` ;
- requests et limits partout ;
- sondes startup, liveness et readiness sur `/web/health` ;
- stratégie `Recreate`, 0 ou 1 replica ;
- aucun produit d'infrastructure supposé : StorageClasses, `VolumeSnapshotClass`,
  Gateway et `ObjectStore` sont des noms dans les valeurs.

| Template                 | Rôle                                                                                                                                                  |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deployment.yaml`        | Odoo (sans init container), sidecar Mailpit (en option) ; `replicas` depuis `odoo.replicas`                                                           |
| `job-migrate.yaml`       | Job `migrate` (§6.2), rendu si `jobs.migrate.run`                                                                                                     |
| `job-reset.yaml`         | Job `reset` (§6.3), rendu seulement si `jobs.reset.run` **et** base `ephemeral` **et** environnement `review`                                         |
| `configmap-scripts.yaml` | `migrate.sh` ; `reset.sh` seulement avec une base `ephemeral`                                                                                         |
| `configmap-config.yaml`  | `odoo.conf` complet généré depuis `odoo.config`, sans secret (§6.1)                                                                                   |
| `service.yaml`           | 8069 ; 8072 (`appProtocol: kubernetes.io/ws`) si `workers` > 0 ; 8025 (Mailpit)                                                                       |
| `httproute.yaml`         | Hôte Odoo (`/websocket` vers 8072 en multi-process), hôte Mailpit, filtres optionnels ; rattaché à la Gateway de l'administrateur                     |
| `pvc.yaml`               | `/var/lib/odoo` (filestore, sessions) : `odoo-data-<g>`, créé depuis un `VolumeSnapshot` au rollback ; `helm.sh/resource-policy: keep` hors review    |
| `postgres.yaml`          | Base `ephemeral` (review) : PostgreSQL 18 (Deployment, Service `<release>-postgres`, volume sur `/var/lib/postgresql`)                                |
| `cnpg.yaml`              | Base `cnpg` : `Cluster` `<release>-pg-<g>` (PG 18, `keep`), `ScheduledBackup` vers l'`ObjectStore` nommé ; bootstrap depuis les snapshots au rollback |
| `secrets.yaml`           | Review : mots de passe générés une fois, conservés via `lookup`                                                                                       |
| `networkpolicy.yaml`     | Odoo joignable depuis la Gateway seulement ; PostgreSQL depuis les pods de la release seulement                                                       |
| `serviceaccount.yaml`    | Compte sans jeton                                                                                                                                     |

**`values.yaml`** (avec `values.schema.json`) :

- `environment` : `review`, `recette` ou `production` (obligatoire) ;
- image et digest ;
- `odoo.replicas` (0 ou 1), `jobs.migrate.run`, `jobs.reset.run` : posés par
  `ci/deploy.sh` à chaque étape ;
- `odoo.config` : sections et options d'`odoo.conf` (§6.1) ;
- `secrets` : nom du Secret applicatif, et variables `secrets.env` des modules ;
- modules à installer (par défaut tout `addons/`) ;
- base : `ephemeral`, `cnpg` ou `external` ;
- génération ;
- noms des StorageClasses, de la `VolumeSnapshotClass`, de l'`ObjectStore`, du secret de
  registre ; Gateway (`parentRefs`) et hôtes ; Mailpit ; ressources ; délai des Jobs.

Les valeurs par environnement sont dans
`deploy/values/{review,recette,production}.yaml`. La CI n'ajoute que le digest, les
réglages d'étape et la génération lors d'un rollback. L'hôte d'une review est déduit du
nom de la release (`<projet>-pr-<n>.<domaine des reviews>`).

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
  - Le chart impose dans `[options]` ce qui ne se règle pas : `addons_path`, `data_dir`
    et `http_interface`. `db_name` vient de `PGDATABASE`, et sans `dbfilter` Odoo ne
    sert que cette base.
  - Le fichier est monté en lecture seule sur `/etc/odoo/odoo.conf`, avec
    `ODOO_RC=/etc/odoo/odoo.conf`, à la place du `docker/odoo.conf` statique de l'image,
    dans le pod Odoo comme dans les Jobs. L'entrypoint de l'image ne fait que vérifier
    les variables requises (phase 0 bis).
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
  est fourni dans `deploy/examples/`.
- **Changements :**
  - quand la ConfigMap change, le pod redémarre (annotation `checksum/config`) ;
  - quand un secret change (rotation), le pod ne redémarre pas tout seul : il faut
    `kubectl rollout restart` ou Reloader (optionnel), et c'est documenté. En recette et
    en prod, le redémarrage coupe brièvement le service (Recreate).
- Le déploiement Docker utilise le même mécanisme : `docker/odoo.conf` statique et
  variables d'environnement (phase 0 bis).

Écartés :

- rendre un modèle au démarrage du pod : inutile, puisque Odoo 20 lit ses secrets dans
  l'environnement. `render-config.py` est supprimé de `20.0` (phase 0 bis) ;
- mettre tout `odoo.conf` dans un Secret : les réglages et les secrets seraient
  mélangés, et on ne pourrait plus confier les secrets à un outil dédié ;
- un mot de passe de review aléatoire passé par la CI (`--set`) : le PostgreSQL de la
  review ne fixe son mot de passe qu'à la création de son volume, et la valeur serait
  copiée dans l'historique Helm.

### 6.2 Job `migrate` (tous les environnements)

Même image, même `odoo.conf`, mêmes Secrets que le pod Odoo. Nommé
`<release>-migrate-<digest court>` : un Job ne se modifie pas, et redéployer le même
digest ne relance rien. `backoffLimit: 0` (une migration partielle ne se rejoue pas
automatiquement), `activeDeadlineSeconds` réglable, `ttlSecondsAfterFinished`.

`deploy/chart/files/migrate.sh` :

1. attend PostgreSQL ;
2. **base vide** (pas de table `ir_module_module`) :
   `odoo -i <modules de addons/> --stop-after-init --no-http`, sans démo, puis
   `click-odoo-update --only-compute-hashes` pour poser la référence ;
3. **base initialisée** : `click-odoo-update` (seulement les modules dont l'empreinte a
   changé).

Il ne contient aucune commande de suppression, ne neutralise pas, et s'arrête au moindre
échec (aucun `|| true`). Le pod Odoo, lui, ne fait que servir : un redémarrage ne touche
jamais la base.

### 6.3 Job `reset` (review uniquement) et garde-fous

Un seul chart, mais la remise à zéro est impossible hors des reviews, à chaque niveau :

- **Au rendu (Helm).** `job-reset.yaml` et `reset.sh` ne sont rendus que si la base est
  `ephemeral`, c'est-à-dire un PostgreSQL créé par le chart lui-même. Avec
  `jobs.reset.run=true`, le template échoue (`fail`) si la base est `cnpg` ou
  `external`, ou si `environment` vaut `production` ou `recette`. `values.schema.json`
  n'accepte `ephemeral` qu'avec `environment: review`. Une valeur mal placée fait donc
  échouer le lint et le déploiement, avant toute action.
- **À l'exécution (Job).** `reset.sh` refuse de tourner si `ODOO_ENVIRONMENT` (posé par
  le chart) n'est pas `review`, ou si `PGHOST` n'est pas `<release>-postgres`, le
  service de sa propre release.
- **Par les droits.** Les comptes de déploiement sont propres à chaque namespace : le
  job `review` de la CI ne peut rien faire dans celui de la prod.
- **Par les tests.** `ci/chart-lint.sh` vérifie que :
  - le rendu de `production.yaml` et de `recette.yaml` ne contient ni Job `reset`, ni
    `reset.sh`, ni `dropdb` / `DROP DATABASE` ;
  - ces deux rendus avec `jobs.reset.run=true` échouent.

`deploy/chart/files/reset.sh` :

1. vérifications ci-dessus ;
2. attend PostgreSQL ;
3. supprime la base (`dropdb --if-exists`) et son filestore
   (`/var/lib/odoo/filestore/<base>`) ;
4. crée la base avec la démo et installe les modules de `addons/` ;
5. pose le mot de passe admin (Secret de la release).

L'image ne change pas pour Kubernetes, en dehors des phases 0 et 0 bis.

## 7. Scripts `ci/`

| Script                          | Rôle                                                                                                                                                                                                                                                                                                        |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci/deploy.sh ENV IMAGE@DIGEST` | Valeurs de `deploy/values/ENV.yaml`, plus le digest. Vérification des pré-requis, puis étapes du §3.2 (arrêt, point de restauration, Job, démarrage, smoke HTTPS), rollback automatique en cas d'échec. Plafond des reviews. Répare une release bloquée en « pending ». Résumé du job avec les logs du Job. |
| `ci/deploy-snapshot.sh`         | Point de restauration : création, attente, rétention                                                                                                                                                                                                                                                        |
| `ci/deploy-rollback.sh [POINT]` | Rollback (§3.3), appelé aussi par le workflow manuel                                                                                                                                                                                                                                                        |
| `ci/review-remove.sh N`         | `helm uninstall pr-<n>`                                                                                                                                                                                                                                                                                     |
| `ci/review-sweep.sh`            | Review apps des PR fermées (API GitHub) ; `DRY_RUN` et liste de PR factice pour les tests                                                                                                                                                                                                                   |
| `ci/chart-lint.sh`              | `helm lint`, rendu des trois environnements, kubeconform (avec les schémas des CRD), `odoo.conf` rendu comparé à un fichier attendu (sections, listes, booléens, secret en clair refusé), garde-fous du Job `reset` (§6.3)                                                                                  |
| `ci/chart-e2e.sh`               | kind avec CNPG, csi-driver-host-path, une Gateway et MinIO, installés pour le test : scénarios de la phase 2, en local                                                                                                                                                                                      |

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

## 9. Exemples — `deploy/examples/`

Le modèle ne fournit **aucune installation de cluster**. `deploy/examples/` ne contient
que des exemples liés au projet, à appliquer ou adapter par l'administrateur :

- `ci-access.yaml` et `ci-kubeconfig.sh` : ServiceAccount, Role de référence (les
  permissions dont la CI a besoin), RoleBinding, jeton, et kubeconfig pour GitHub ;
- `app-secret.example.sh` : création du Secret applicatif avec `kubectl` (clés du §6.1)
  ;
- `external-secret.example.yaml` : le même Secret produit par External Secrets Operator
  ;
- `registry-secret.sh` : crée le secret de registre GHCR dans un namespace.

Les fonctions du cluster (§4) sont décrites dans `docs/deployment-kubernetes.md`, avec
des liens vers la documentation des produits courants. Le modèle ne fournit pour eux ni
manifeste ni script.

## 10. Documentation

- `docs/deployment-kubernetes.md` :
  - pré-requis (§4) décrits comme des fonctions, avec la façon de les vérifier ; mise en
    place du projet pas à pas ; workflow ;
  - runbooks : rollback manuel, restauration après sinistre, **rafraîchissement de la
    recette depuis la prod avec neutralisation** (`odoo db load -n`), rotation des
    jetons et des secrets (avec redémarrage), changement d'outil de gestion des secrets,
    suppression des générations inactives, Job en échec, dépannage.
- `README.md`, `docs/ci.md`, `docs/gitflow.md` : environnements désormais déployés,
  nouveaux jobs, contrôles requis.
- Ce plan : une note d'écarts en tête une fois implémenté.

## 11. Phases et vérification (`ecc:verification-loop`)

| Phase | Contenu                   | Vérification                                                     |
| ----- | ------------------------- | ---------------------------------------------------------------- |
| 0     | §5, sur `20.0`            | Voir §5                                                          |
| 0 bis | §5 bis, sur `20.0`        | Voir §5 bis                                                      |
| 1     | Essais, avant le chart    | Voir ci-dessous                                                  |
| 2     | Chart, `migrate`, `reset` | `ci/chart-lint.sh` ; scénarios de `ci/chart-e2e.sh` ci-dessous   |
| 3     | Scripts `ci/`             | shellcheck ; exécution contre kind ; sweep sur une liste factice |
| 4     | Workflows                 | actionlint, pre-commit                                           |
| 5     | Exemples et documentation | kubeconform des exemples, dry-run serveur sur kind               |
| 6     | Validation réelle         | Scénarios ci-dessous, sur le dépôt de test et un vrai cluster    |

**Phase 1, essais :**

- avec un `odoo.conf` monté (`ODOO_RC`) et les secrets en variables `ODOO_*` et `PG*`,
  via notre entrypoint : `odoo`, `odoo -i` sur une base vide existante (cas CNPG),
  création avec démo et mot de passe admin (cas `reset`), `click-odoo-update` (référence
  posée à l'installation) et le jobrunner de queue_job (section `[queue_job]`,
  `ODOO_QUEUE_JOB_HTTP_AUTH_PASSWORD`) lisent bien leur configuration ;
- détection « base vide » de `migrate.sh` ;
- le rendu PDF fonctionne avec la racine en lecture seule ; PostgreSQL 18 et Mailpit
  tournent en non-root (PSA `restricted`) ;
- CNPG sur kind :
  - sauvegarde `volumeSnapshot` à froid ;
  - restauration dans un nouveau cluster ;
  - snapshots qui survivent à la suppression du cluster ;
  - archivage des WAL d'une nouvelle génération ;
- un volume créé depuis un `VolumeSnapshot`. La durée de restauration se mesure sur le
  stockage du vrai cluster, en phase 6.

**Phase 2, scénarios de `ci/chart-e2e.sh` :**

- review :
  - installation (Odoo à 0, Job `reset`, Odoo à 1), avec `/web/health` et `/web/login` à
    200 ;
  - nouvelle image → remise à zéro ;
  - redémarrage du pod → aucun Job, données conservées ;
- garde-fous : `jobs.reset.run=true` avec les valeurs de recette ou de prod → échec du
  rendu ; `reset.sh` lancé avec un autre `PGHOST` → refus ;
- recette :
  - première installation (Job `migrate` sur base vide) ;
  - mise à jour avec point de restauration ;
  - module cassé → Job en échec → rollback automatique (base, filestore et digest
    précédents) ;
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
10. rafraîchissement de la recette depuis la prod, neutralisée (runbook) ;
11. sweep et nettoyage nocturne.

## 12. Risques

| Risque                                                           | Mitigation                                                                                                          |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Remise à zéro déclenchée hors review                             | Rendu refusé hors base `ephemeral` et `environment: review`, refus à l'exécution, droits par namespace, lint (§6.3) |
| Rollback automatique incorrect (restauration CNPG ou volume)     | Testé en phases 1, 2 et 6 ; état en échec conservé ; génération précédente intacte                                  |
| Job `migrate` en échec ou trop long                              | `backoffLimit: 0`, délai réglable, logs dans le résumé, rollback automatique                                        |
| Restauration lente sur un gros volume (selon le stockage)        | Mesurée en phase 6 et documentée                                                                                    |
| Snapshot ≠ sauvegarde                                            | Sauvegardes hors cluster et test de restauration                                                                    |
| Fonction du cluster absente ou différente                        | Vérifiée par `ci/deploy.sh` avant toute coupure ; noms des ressources dans les valeurs                              |
| Copie de la prod en recette sans neutralisation                  | Runbook de rafraîchissement avec `odoo db load -n`                                                                  |
| Review apps exposées (code des PR, démo)                         | Mot de passe aléatoire, NetworkPolicy, filtre d'accès, prod sur un autre cluster                                    |
| API du cluster exposée, jeton longue durée                       | Role limité au namespace, règles d'environnement, ruleset des tags, rotation ; OIDC ou ARC en durcissement          |
| Websockets selon l'implémentation Gateway                        | `appProtocol: kubernetes.io/ws`, testé en phase 6                                                                   |
| Pas de haute disponibilité (1 pod, volume RWO)                   | Assumé en v1 et documenté                                                                                           |
| Run de PR annulé pendant `helm upgrade`                          | `ci/deploy.sh` répare la release bloquée ; aucune annulation des déploiements                                       |
| Base managée (`external`) sans point de restauration automatique | Documenté ; CNPG par défaut                                                                                         |
| Secret changé sans redémarrage d'Odoo                            | Runbook de rotation ; Reloader en option                                                                            |
| Secret applicatif absent ou clé manquante                        | Vérifié par `ci/deploy.sh` avant l'arrêt ; sinon le pod reste en `CreateContainerConfigError`                       |

## 13. Hors périmètre (v1)

- environnement `testing` ;
- installation ou configuration des composants du cluster ;
- mise à zéro des review apps inactives (KEDA HTTP, Sablier) ;
- variante Argo CD ;
- rafraîchissement automatique de la recette depuis la prod (runbook en v1) ;
- haute disponibilité et page de maintenance ;
- mise à jour en ligne, avec l'ancien pod en parallèle ;
- review apps construites depuis une copie neutralisée de la prod.

## Mise en œuvre

- Branche `20.0-k8s-deployment` (worktree `.claude/worktrees/k8s`), créée depuis `20.0`.
- Phases 0 et 0 bis sur des branches de travail issues de `20.0`. L'utilisateur les
  fusionne, puis `20.0-k8s-deployment` est rebasée sur `20.0`.
- Commits depuis l'image de dev (pre-commit) ; pas de push sans accord.
- Validation réelle :
  - dépôt de test privé `Skilldron/test-odoo-template` (remote `test`), supprimé après
    validation ;
  - un cluster à fournir (fournisseur, domaine, DNS).
