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
- **le chart porte le cycle de vie du déploiement** : ses hooks enchaînent l'arrêt
  d'Odoo, le point de restauration et la mise à jour de la base dans un même
  `helm upgrade`. La CI ne lance que `helm upgrade` et, en cas d'échec, la restauration.
  Le pod Odoo ne touche jamais au schéma de la base (§3.2, §6.2) ;
- **pas de script de déploiement dans l'image** : le Job `migrate` enchaîne des
  commandes natives (`odoo db init`, `odoo -i`, `click-odoo-update`) ; les Jobs d'arrêt
  et de snapshot n'ont que des commandes `kubectl` courtes, écrites dans les templates ;
  seul `entrypoint.sh` reste dans l'image ;
- **aucune commande de suppression de données dans le chart** : la remise à zéro d'une
  review vient de volumes neufs à chaque image (noms suffixés par le digest), refusés
  hors review au rendu (§6.3). Seule exception : le hook `validate` supprime les anciens
  points de restauration (`Backup` et leurs snapshots), jamais une base ni un volume
  (§6.4) ;
- **la base de recette et de prod est un cluster CloudNativePG installé à part**,
  obligatoire hors review (pré-requis de la charte) ; le chart Odoo ne crée de base que
  pour les reviews (`database.type` : `ephemeral` ou `external`) (§4, §6) ;
- **point de restauration** à chaque mise à jour, pris par le chart : snapshot de volume
  à froid de la base (et du filestore s'il est sur PVC), Odoo arrêté ; si la mise à jour
  échoue, **Odoo reste arrêté et la CI restaure automatiquement** (§3.3) ;
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

Décisions de la phase 3 bis (2026-10-18), après la proposition « Évolution : snapshots à
froid pour le rollback des upgrades Odoo » et sa revue :

- **chart publiable** : `deploy/chart` est conçu comme un projet à part (publication OCI
  prévue), sans dépendance aux scripts `ci/` ; ses runbooks vont dans sa documentation ;
- **le chart porte la séquence de mise à jour** : hooks `pre-upgrade` « arrêt → snapshot
  → mise à jour des modules » sans trou, puis Helm applique les Deployments. Un
  `helm upgrade` relancé à la main ou une CI rejouée en partie ne peut plus glisser un
  démarrage d'Odoo entre le snapshot et la mise à jour. Remplace le pilotage par étapes
  de `ci/deploy.sh` de la phase 3 (§3.2) ;
- **CNPG obligatoire hors review** : les cas « base non CNPG » disparaissent ;
- **Service stable** `odoo-db` devant le primaire du cluster actif, hors de toute
  release de base comme du chart Odoo. Odoo s'y connecte ; le cluster actif se lit dans
  son sélecteur. Une restauration crée un nouveau cluster et bascule le sélecteur (§3.3,
  §4) ;
- **identifiants stables** : rôle `odoo` déclaré dans le `Cluster` (`cluster.roles`, mot
  de passe lu dans le Secret `odoo-db-credentials`), à l'installation comme à la
  restauration (§4) ;
- **état des points de restauration** sur la `Backup` (étiquette `upgrade-state`) :
  `pending`, `validated`, `restored`. Une relance après échec ne prend pas de nouveau
  snapshot tant qu'un point `pending` existe (§3.3) ;
- **restauration automatique** : le job `restore` de la CI, lancé seulement si le job
  `deploy` échoue, restaure le point `pending` dans un nouveau cluster, bascule le
  Service et fait `helm rollback` (§3.3) ;
- **point de restauration nommé dans les WAL** (`pg_create_restore_point`), posé juste
  avant le snapshot, pour viser l'instant d'avant la mise à jour en cas de sinistre
  (§3.4, §6.2) ;
- **première installation et reviews** : les Jobs de base tournent en `post-install` (et
  `post-upgrade` en review), car le PVC et la base éphémère n'existent qu'après
  l'application par Helm ; les pods Odoo attendent la base dans un init container
  (solution A, §3.2) ;
- **ConfigMap des hooks** `<release>-odoo-conf-hook`, rendue par le même helper que
  celle des Deployments, sans mot de passe (§6.1) ;
- **filestore** : trois modes, une instance et PVC RWO, plusieurs instances et PVC RWX,
  plusieurs instances avec filestore sur S3 et sessions en base ou Redis sans PVC
  (recommandé en prod) (§3.4) ;
- **rétention dans le hook `validate`**, sans CronJob : de nouveaux points
  n'apparaissent qu'aux mises à jour, la purge se fait donc après chaque mise à jour
  réussie. Elle garde les `keep` plus récents, ne touche jamais un point `pending`
  complet, et une erreur de purge ne fait pas échouer le hook. Un seul compte, celui des
  hooks, recréé à chaque mise à jour. Remplace la décision de phase 3 « l'administrateur
  purge » (§6.4) ;
- **une `Backup` emporte tout le point** : `snapshotOwnerReference: backup` dans le
  patch du `Cluster` (snapshot de la base) et `ownerReference` du snapshot du filestore
  vers la `Backup` (ramasse-miettes de Kubernetes). Supprimer la `Backup` supprime le
  point entier (§6.4) ;
- **`VolumeSnapshotClass` en `deletionPolicy: Delete`**, vérifiée par la CI, sinon la
  purge ne libère pas d'espace (§4) ;
- **plus de bloc `state`** : sans restauration automatique du filestore, rien n'est
  reporté entre deux déploiements ; la CI ne passe que le digest (§3.3).

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
    helm upgrade --install pr-<n> (namespace <projet>-review), puis rollout status
        nouvelle image : volumes neufs (base et filestore), les anciens supprimés
        pods Odoo en attente (init container wait-db) tant que la base n'est pas prête
        hook post-install / post-upgrade, Job migrate : db init --with-demo, -i
    ─► https://<projet>-pr-<n>.<domaine des reviews>
PR fermée ─► cleanup : helm uninstall pr-<n>, suppression de builds:pr-<n>
Chaque nuit ─► sweep : review apps de PR fermées restantes

push release/X.Y.Z | hotfix/X.Y.Z ─► quality ─► image (X.Y.Z-rc.N) ─► recette
tag vX.Y.Z ─► promote (dernière rc ─► X.Y.Z, même digest) ─► production
  job deploy : vérifications, puis helm upgrade --install --wait (mise à jour)
    hooks pre-upgrade du chart                                        ┐
      1. stop-snapshot : Odoo à 0, point nommé dans les WAL,          │
         Backup à froid « pending » (+ snapshot du filestore lié)     │
         sauf si un point « pending » complet existe déjà            │ coupure
      2. migrate : odoo -i, click-odoo-update                         │
    Helm applique les Deployments : nouvelle image, N réplicas        │
    hook post-upgrade, validate : « pending » ─► « validated »,       ┘
      purge au-delà des 3 plus récents (une Backup emporte ses snapshots)
    smoke HTTPS
  job restore (seulement si deploy échoue) :
    point « pending » complet ─► nouveau cluster CNPG, bascule du Service,
    « restored », helm rollback ; aucune « pending » ─► helm rollback seul
  première installation : helm upgrade --install sans --wait,
    hook post-install (db init, -i), pods en attente, puis rollout status
```

|                      | review                                        | recette                                                                                                               | production                      |
| -------------------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| Déclencheur          | PR interne non draft, après `image / publish` | push `release/*` ou `hotfix/*`, après `image / publish`                                                               | tag `v*`, après `promote`       |
| Contrôle GitHub      | `review / deploy`                             | `recette / deploy`                                                                                                    | `production / deploy`           |
| Environnement GitHub | `review`                                      | `recette` (branches `release/*`, `hotfix/*`)                                                                          | `production` (tags `v*`)        |
| Namespace            | `<projet>-review` (toutes les PR)             | `<projet>-recette`                                                                                                    | `<projet>-prod`                 |
| Release Helm         | `pr-<n>`                                      | `odoo`                                                                                                                | `odoo`                          |
| Image                | `…/builds@sha256:…`                           | `…@sha256:…` (la rc)                                                                                                  | même digest que la rc           |
| PostgreSQL 18        | éphémère, créé par le chart                   | cluster CNPG installé à part (obligatoire)                                                                            | cluster CNPG (obligatoire)      |
| Job `migrate`        | `db init --with-demo`, `-i` (hook `post-*`)   | `-i`, `click-odoo-update` (hook `pre-upgrade`, après le snapshot) ; `db init` au premier déploiement (`post-install`) | idem recette                    |
| Données              | remises à zéro à chaque nouvelle image        | conservées                                                                                                            | conservées                      |
| Odoo                 | threadé (`workers=0`), Mailpit                | `workers=2`, Mailpit                                                                                                  | workers dimensionnés, vrai SMTP |

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
- **Remise à zéro à chaque nouvelle image, sans suppression.** Les volumes de la review
  (données PostgreSQL et filestore) ont le digest court dans leur nom (§6.3). À une
  nouvelle image, `helm upgrade` crée des volumes neufs : le PostgreSQL éphémère
  redémarre dessus, et les anciens volumes sont supprimés comme toute ressource qui
  n'est plus rendue. Le pod Odoo attend la base (init container `wait-db`) pendant que
  le Job `migrate`, en hook `post-upgrade` (§6.2) :
  1. crée la base avec la démo et le mot de passe admin (`odoo db init`) ;
  2. installe les modules de `addons/` (`odoo -i`).

  Un champ supprimé ou renommé ne peut donc pas empêcher Odoo de démarrer, et chaque
  push revalide l'installation complète.

- **Redémarrage sans nouvelle image** (nœud drainé, crash). Seul le pod Odoo redémarre,
  sur les mêmes volumes : aucun Job ne tourne, rien n'est réinitialisé. Les saisies des
  testeurs restent jusqu'au push suivant.
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

### 3.2 Déploiement et mise à jour : le chart

Le chart porte tout le cycle. La CI lance `helm upgrade --install` et, si ce job échoue,
le job de restauration (§3.3). La séquence « arrêt → snapshot → mise à jour des modules
» est dans les hooks d'un même `helm upgrade` : un `helm upgrade` relancé à la main ou
une CI rejouée en partie ne peut pas glisser un démarrage d'Odoo entre le snapshot et la
mise à jour.

**Job `deploy` de la CI** (`ci/deploy.sh ENV IMAGE@DIGEST`) :

1. **Vérification**, avant toute coupure :
   - les fonctions du cluster attendues par les valeurs sont là (CRD Gateway API,
     StorageClass, `VolumeSnapshotClass`, Gateway) ;
   - le Secret applicatif et le Secret des identifiants existent avec leurs clés (§6.1),
     dont `admin-user-password` tant que la base d'Odoo n'existe pas ;
   - recette, prod : le Service stable (`database.external.host`) vise un `Cluster` CNPG
     prêt, qui archive ses WAL et a sa section `spec.backup.volumeSnapshot` (patch de
     l'administrateur, §4) ;
   - review : plafond `REVIEW_MAX_APPS` pour une nouvelle review app ;
   - le rendu passe côté serveur (`helm upgrade --dry-run=server`) ;
   - release restée « pending » (run annulé) : si un Job de hook tourne encore, refus («
     mise à jour en cours ») ; sinon, elle est traitée comme un échec (job `restore`).

   Si quelque chose manque, on s'arrête ici avec un message clair, sans coupure. **Même
   digest déjà déployé** (release `deployed`) : rien à faire, pas de coupure.

2. **`helm upgrade --install --timeout <délai>`** avec `deploy/values/ENV.yaml` et le
   digest, sans autre valeur. Le délai couvre la plus longue migration attendue.
   - **Mise à jour de recette ou de prod** : avec `--wait` (stratégie `watcher`), pour
     que le hook `validate` ne passe qu'une fois les pods prêts.
   - **Première installation et review** : sans `--wait` (stratégie par défaut de Helm
     4, `hookOnly`, qui attend les hooks mais pas les ressources), puis
     `kubectl rollout status`. Avec `--wait`, Helm attend les pods avant de lancer les
     hooks `post-install`, alors que les pods attendent la base créée par ces hooks :
     blocage jusqu'au délai (essai du 2026-10-18).

   Pas de `--rollback-on-failure` : remettre l'ancienne image sur une base migrée serait
   pire que l'échec ; la restauration passe d'abord par la base (§3.3).

3. **Smoke test** : `/web/health` et `/web/login` en HTTPS sur l'hôte public. Un échec
   ici, pods prêts, met en cause la Gateway : alerte, sans restauration.

**Mise à jour (recette, prod) : hooks du chart.**

| Ordre | Hook                     | Ressource                                                                          | Action                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ----- | ------------------------ | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | `pre-upgrade`, poids -10 | ServiceAccount, Role, RoleBinding des hooks ; ConfigMap `<release>-odoo-conf-hook` | Recréés à chaque mise à jour (`before-hook-creation`) : le Job a toujours les droits et l'`odoo.conf` de la nouvelle révision                                                                                                                                                                                                                                                                                                                            |
| 2     | `pre-upgrade`, poids -5  | Job `stop-snapshot`                                                                | Refus si un point `pending` complet est orphelin (§3.3). Deployments d'Odoo à 0, attente de la fin des pods ; cluster actif lu dans le sélecteur du Service stable. Si un point `pending` complet existe : rien, signalé dans les logs. Sinon : point nommé dans les WAL, `Backup` à froid `<cluster>-preupgrade-r<révision>` étiquetée `pending`, snapshot du filestore rattaché à la `Backup` s'il y a un PVC, attente des deux, puis du primaire prêt |
| 3     | `pre-upgrade`, poids 0   | Job `migrate`                                                                      | Attente de la base (`pg_isready`), `odoo -i`, `click-odoo-update` (§6.2)                                                                                                                                                                                                                                                                                                                                                                                 |
| —     | (Helm)                   | Deployments, ConfigMap, PVC…                                                       | Appliqués seulement si les hooks ont réussi : nouvelle image, N réplicas ; `--wait` attend qu'ils soient prêts                                                                                                                                                                                                                                                                                                                                           |
| 4     | `post-upgrade`           | Job `validate`                                                                     | Le point `pending` complet passe `validated` ; les points `pending` incomplets sont supprimés ; purge des points au-delà de `keep` (§6.4)                                                                                                                                                                                                                                                                                                                |

Si un hook échoue, Helm n'applique rien : les Deployments restent à 0 (mis à 0 par
`stop-snapshot`, l'ancienne image dans leur spec) et la release est `failed`. Un HPA ne
remonte pas un Deployment à 0. Une modification des seules valeurs (même image) passe
par la même séquence, avec sa coupure.

**Première installation et reviews (solution A).** Le PVC du filestore et la base
éphémère sont des ressources de la release : ils n'existent qu'après l'application par
Helm. Les Jobs de base tournent donc en hooks `post-*` :

- recette, prod, première installation : Job `migrate` en `post-install`, avec l'étape
  `db-init` (`odoo db init --password`, clé `admin-user-password`, sans démo), puis
  `odoo -i` et `click-odoo-update`. Pas de point de restauration : la base est vide ;
- review, à chaque installation ou nouvelle image : volumes neufs, Job `migrate` en
  `post-install` ou `post-upgrade` (`db init --with-demo`, `-i`), sans snapshot ni hook
  `pre-upgrade` ;
- les pods Odoo démarrent avec la release et attendent dans un init container `wait-db`
  que la base soit prête : présence du paramètre
  `module_auto_update.installed_checksums` dans `ir_config_parameter`, écrit par
  `click-odoo-update` à la fin de sa première passe (vérifié dans l'image). Après une
  mise à jour de recette ou de prod, il existe déjà : l'attente est immédiate ;
- volume RWO : le Job et le pod Odoo montent le même PVC et pourraient être placés sur
  deux nœuds, le second restant bloqué. Le Job a une affinité requise avec le nœud du
  pod Odoo (non testable sur un kind à un nœud : phase 6) ;
- relance d'une première installation en échec : `helm upgrade --install` fait une mise
  à jour (vérifié avec Helm 4), donc la chaîne `pre-upgrade` avec un snapshot de la base
  presque vide ; l'étape `db-init` ne tourne que si la base n'existe pas.

Un déploiement crée une seule révision Helm ; l'historique est limité
(`--history-max 10`). Au premier déploiement, `odoo db init` crée la base, `odoo -i`
installe les modules, puis `click-odoo-update` enregistre les empreintes.

### 3.3 Échec de mise à jour et restauration automatique

Le Job `migrate` committe module par module : une base à moitié migrée ne peut pas
repartir avec l'ancienne image. Après un échec, la CI restaure donc d'abord la base,
puis remet l'ancienne image. Restaurer automatiquement ne perd aucune saisie : Odoo est
arrêté depuis le snapshot.

**États d'un point de restauration**, étiquette `<préfixe>/upgrade-state` sur la
`Backup` (préfixe `odoo.haroldd.dev`, valeur `labelPrefix` du chart, avec
`<préfixe>/backup-type=pre-upgrade`) :

| État        | Posé par                            | Signification                                              |
| ----------- | ----------------------------------- | ---------------------------------------------------------- |
| `pending`   | Job `stop-snapshot` (`pre-upgrade`) | Point de restauration d'une mise à jour pas encore validée |
| `validated` | Job `validate` (`post-upgrade`)     | Mise à jour réussie : le point devient un historique       |
| `restored`  | Job `restore` de la CI              | Point utilisé pour restaurer : l'incident est clos         |

- **Point complet** : `Backup` en phase `completed` et, s'il y a un PVC, snapshot du
  filestore `readyToUse` (la `Backup` porte l'annotation `<préfixe>/filestore` avec son
  nom). La phase de la `Backup` ne concerne que la base ; `stop-snapshot` attend les
  deux avant de laisser la migration démarrer.
- Tant qu'un point `pending` complet existe, `stop-snapshot` ne prend ni snapshot ni
  point nommé : une relance après échec garde le point d'avant le premier échec.
- Un point `pending` incomplet (snapshot raté, migration non lancée) ne bloque rien et
  n'est jamais validé : il prendrait la place d'un point valide parmi les `keep`.
  `validate` le supprime.
- `validate` passe à `validated` le point `pending` complet, quelle que soit sa
  révision.
- **Point orphelin** : si `validate` échoue après une mise à jour réussie, le point
  reste `pending` alors que la base a changé depuis. Le laisser bloquer les mises à jour
  suivantes les priverait de point de restauration, et une restauration ramènerait la
  base trop loin en arrière. Deux gardes :
  - la CI refuse de déployer si un point `pending` complet existe alors que la release
    est `deployed` ;
  - `stop-snapshot`, avant d'arrêter Odoo, refuse si les Deployments sont disponibles
    avec l'image visée par ce point (annotation `<préfixe>/target-image`), même pour un
    `helm upgrade` lancé à la main.

  On lève le blocage en passant l'étiquette à `validated` (runbook).

- Le hook `validate` ne supprime jamais un point `pending` complet (§6.4).

**Job `restore` de la CI** (recette, prod ; `ci/deploy-restore.sh ENV`), lancé seulement
si le job `deploy` a échoué :

1. Cherche le point `pending` complet de la release (au plus un, par ses étiquettes) ;
   son nom est `<cluster>-preupgrade-r<révision>`.
2. **Aucun** : la base n'a pas été touchée (échec avant la migration). Mise à jour :
   `helm rollback` vers la dernière révision `deployed`, Odoo repart sur l'ancienne
   image. Première installation : rien à restaurer, l'échec est signalé. **Mise à jour
   appliquée et pods prêts** (seul `validate` a échoué) : pas de restauration, Odoo sert
   déjà la nouvelle version ; alerte et validation manuelle du point.
3. **Une** :
   - nouveau cluster `<cluster>-r<révision>` avec le chart `cnpg/cluster` en
     `mode: recovery` (`recovery.method: backup`, `backupName`), valeurs reprises de la
     release du cluster actif (`helm get values`), une instance ; mêmes rôles et Secret
     `odoo-db-credentials`, son propre dossier Barman ;
   - attente de `Ready`, puis section `spec.backup.volumeSnapshot` recopiée du cluster
     actif sur le nouveau (§4), et attente du pod primaire prêt ;
   - bascule du Service stable sur le nouveau cluster ;
   - la `Backup` passe `restored` ;
   - `helm rollback` vers la dernière révision `deployed` : ancienne image, N réplicas.
     Les hooks `pre-upgrade` ne tournent pas sur un rollback ;
   - smoke test.
4. Résumé du job : logs du Job en échec (gardés par `before-hook-creation` jusqu'à la
   tentative suivante), point utilisé, cluster restauré.

**Après la restauration** (administrateur, runbook) : analyser l'ancien cluster, passer
le cluster restauré au nombre d'instances voulu, puis désinstaller l'ancien. La CI ne
supprime jamais de cluster. Le Service stable n'appartient à aucune release de base : il
reste en place.

- **Filestore.** Il est adressé par contenu (SHA-1). Une migration ajoute des fichiers
  mais n'en efface aucun : Odoo ne supprime un fichier que dans le ramasse-miettes de
  l'autovacuum, un cron qui ne tourne pas avec `--stop-after-init` (à confirmer à
  l'essai). Une base restaurée retrouve donc ses fichiers, les orphelins sont sans effet
  : la restauration automatique ne touche pas au filestore. Le snapshot du filestore
  reste un filet manuel : nouveau PVC depuis `<point>-filestore`, puis
  `odoo.persistence.existingClaim` (runbook). Sans PVC, le versioning du bucket joue ce
  rôle.
- **Retour arrière manuel plus tard** (sur un point `validated`) : mêmes étapes, à la
  main ou par `ci/deploy-restore.sh ENV POINT` ; les saisies faites depuis le point sont
  perdues, et le résumé le dit.
- Avec Longhorn, restaurer un snapshot `type: snap` copie les données dans un nouveau
  volume : la durée dépend de la taille et se mesure en phase 6.

### 3.4 Sauvegardes et reprise après sinistre

Les snapshots restent dans le stockage du cluster : ils ne protègent pas d'une perte du
cluster. Hors du cluster :

- **base** : archivage continu des WAL et sauvegarde complète chaque nuit vers l'
  `ObjectStore` (chart CNPG `cluster`, plugin Barman Cloud, `ScheduledBackup`), gérés
  par l'administrateur avec la base. Un dossier par environnement : Barman refuse
  d'archiver dans un dossier non vide. Cela permet une restauration à un instant donné,
  et en particulier à l'instant d'avant une mise à jour : `recoveryTarget.targetName`
  avec le nom du point de restauration, posé dans les WAL par le Job `stop-snapshot`
  (§6.2). CNPG exige alors `backupID`, l'identifiant d'une sauvegarde de base antérieure
  au point, et le chart `cnpg/cluster` ne rend pas `targetName` : le runbook de sinistre
  utilise un manifeste `Cluster` brut (vérifié sur kind). Rétention de 30 jours dans
  l'exemple ;
- **filestore** : sur PVC, sauvegarde hors cluster recommandée, à la charge de
  l'administrateur avec l'outil de son choix (job récurrent de son stockage, Velero…),
  documentée comme pré-requis recommandé ; sur S3, versioning du bucket obligatoire ;
- **secrets** : récupérables avec l'outil de l'équipe (Sealed Secrets, SOPS, External
  Secrets…) ; ils ne sont ni dans le dépôt ni dans GitHub (§6.1) ;
- **test de restauration** complet dans un namespace vierge, en phase 6 puis
  périodiquement (runbook).

**Modes du filestore** (`odoo.persistence`) :

| Mode                                | Valeurs                                      | Point de restauration | Conditions                                                                                                                                                                                                    |
| ----------------------------------- | -------------------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Une instance, PVC                | `enabled: true`, `accessMode: ReadWriteOnce` | base et filestore     | Défaut                                                                                                                                                                                                        |
| 2. Plusieurs instances, PVC partagé | `enabled: true`, `accessMode: ReadWriteMany` | base et filestore     | StorageClass RWX (Longhorn RWX par un pod NFS, CephFS, NFS managé). La réplication de Longhorn ne suffit pas : un volume RWO ne s'attache qu'à un nœud. Le chart refuse plus d'une instance sur un volume RWO |
| 3. Plusieurs instances, sans PVC    | `enabled: false`                             | base seule            | Filestore sur S3 (module de type `fs_attachment`, versioning du bucket obligatoire) et sessions en base ou dans Redis : recommandé en prod                                                                    |

En mode 3, `/var/lib/odoo` est sur un `emptyDir`. Le chart ne peut pas vérifier les
modules : c'est un pré-requis documenté. Les sessions restent sinon dans
`data_dir/sessions`, que `fs_attachment` ne déplace pas : chaque redémarrage
déconnecterait les utilisateurs, et les instances ne les partageraient pas. Le module de
stockage doit être dans la première installation : un fichier écrit avant sa
configuration finit dans l'`emptyDir`.

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
     `migrate` ;
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
   fournisseur cloud…) en **`deletionPolicy: Delete`** : supprimer un point de
   restauration (rétention, §6.4) doit libérer l'espace (vérifié sur kind : le
   `VolumeSnapshotContent` disparaît). Avec `Retain`, le snapshot du stockage resterait,
   et le supprimer demanderait au chart un ClusterRole. La CI vérifie la politique des
   classes utilisées (base et filestore) avant de déployer ; si son compte ne peut pas
   lire les classes (objets du cluster), elle le signale sans bloquer. Elle sert aux
   points de restauration de la base et du filestore. Le snapshot doit être
   copy-on-write : quelques secondes, quelle que soit la taille du volume. Avec Longhorn
   : `type: snap` (snapshot dans le volume), pas `bak` (copie vers la cible de
   sauvegarde, aussi lente que S3) ; exemple
   `deploy/examples/longhorn-volumesnapshotclass.yaml`. Les snapshots vivent dans le
   stockage du cluster : une panne de ce stockage ou la suppression du namespace les
   emporte, seule la sauvegarde Barman protège de ce cas (§3.4).
8. Des **StorageClasses** pour le filestore, la base et les reviews
   (`reclaimPolicy: Delete` conseillé pour les reviews). Le chart les prend par nom dans
   les valeurs. Pour plusieurs instances d'Odoo sur un filestore PVC : une StorageClass
   `ReadWriteMany` (§3.4).
9. Recommandé : une sauvegarde hors cluster du filestore (§3.4).

### PostgreSQL

10. **Une base PostgreSQL 18 par environnement de recette et de prod**, installée par
    l'administrateur. **Obligatoire hors review** (pré-requis de la charte) :
    l'opérateur **CloudNativePG 1.30**, son **plugin Barman Cloud** (qui demande
    cert-manager) et le chart **`cnpg/cluster`** (exemple de valeurs dans
    `deploy/examples/cnpg-cluster.values.yaml` : archivage et sauvegarde nocturne vers
    S3). Odoo crée sa propre base au premier déploiement (`database.name`, §3.2) ; la
    base `app` de CNPG reste vide. La base doit être sur une StorageClass à snapshots.
    - **Rôle `odoo` déclaré** (`cluster.roles`) : connexion, `CREATEDB`, non
      superutilisateur, mot de passe lu dans le Secret `odoo-db-credentials`
      (`kubernetes.io/basic-auth`, clés `username` et `password`), aussi propriétaire de
      `app` (`cluster.initdb.secret`). Les mêmes valeurs servent à la restauration : le
      chart `cnpg/cluster` 0.9.0 ne transmet pas de Secret au bloc `recovery`, mais CNPG
      applique les rôles déclarés quel que soit le bootstrap. Le Secret `-app` généré
      par CNPG n'est pas utilisé.
    - **`GRANT EXECUTE ON FUNCTION pg_create_restore_point(text) TO odoo`**
      (`postInitSQL`, exécuté dans la base `postgres`) : la fonction est réservée aux
      superutilisateurs. Le droit vaut pour la base `postgres` seulement (vérifié :
      refus dans `app`), c'est donc là que `stop-snapshot` l'appelle (§6.2). La
      restauration le conserve (données restaurées).
    - **Service stable `odoo-db`** devant le primaire du cluster actif (sélecteur
      `cnpg.io/cluster` et `cnpg.io/instanceRole: primary`,
      `deploy/examples/database-service.yaml`), appliqué une fois par l'administrateur,
      hors de toute release de base : désinstaller l'ancien cluster ne doit pas
      l'emporter. Odoo s'y connecte (`database.external.host`). Les certificats de CNPG
      ne portent pas ce nom : la connexion reste en `sslmode=prefer`, ou
      `cluster.certificates.serverAltDNSNames` si l'on veut vérifier l'hôte.
    - **Après chaque installation de la base, restauration comprise**, l'administrateur
      ajoute la section `spec.backup.volumeSnapshot` par un `kubectl patch` documenté
      dans l'exemple :
      `{"className":"<classe>","online":false,"snapshotOwnerReference":"backup"}`.
      `snapshotOwnerReference: backup` rattache les snapshots de la base à leur `Backup`
      : supprimer la `Backup` les supprime (vérifié sur kind). Le chart `cnpg/cluster`
      0.9.0 ne sait pas écrire cette section
      ([cloudnative-pg/charts#900](https://github.com/cloudnative-pg/charts/issues/900))
      ; `helm upgrade` la conserve (vérifié avec Helm 4). Quand le chart la gérera, le
      patch deviendra une valeur. La CI vérifie les trois réglages avant de déployer, et
      le job `restore` recopie la section sur le cluster restauré.
    - **Rétention native de CNPG** : elle ne couvre pas les snapshots de volume
      (documentation de CNPG 1.30 : « Volume snapshots … do not support retention
      policies »), et `spec.backup.retentionPolicy` est dépréciée au profit de la
      rétention du plugin Barman, qui ne purge que S3. Les points de restauration sont
      donc purgés par le chart Odoo (§6.4) ; la rétention de l'`ObjectStore` reste celle
      de la reprise après sinistre.
11. Un **bucket S3 hors du cluster** et ses identifiants, un dossier par environnement.
12. Le chart Odoo prend l'hôte et le port de la base dans ses valeurs
    (`database.external.host`, `database.external.port`), et les identifiants dans un
    Secret aux clés `username` et `password` (`database.external.secret`) :
    `odoo-db-credentials` avec CNPG, ou un Secret créé avec les mêmes clés pour une
    autre base (managée, classique). Le rôle doit avoir `CREATEDB` : Odoo crée sa base
    (`database.name`, `odoo` par défaut) au premier déploiement.
13. Si le namespace de la base refuse le trafic par défaut, une NetworkPolicy qui laisse
    entrer les pods Odoo (exemple : `deploy/examples/database-networkpolicy.yaml`). Le
    chart Odoo ne restreint pas la sortie de ses pods.

### Réseau, DNS, TLS

14. Une **implémentation de Gateway API v1.6** (canal standard) et une **Gateway**
    fournie par l'administrateur :
    - listeners HTTPS pour `*.<domaine des reviews>` et pour les hôtes de recette et de
      prod, avec leurs certificats (wildcard pour les reviews) gérés comme
      l'administrateur l'entend ;
    - `allowedRoutes` qui accepte les namespaces du projet ;
    - le `/websocket` d'Odoo doit passer ;
    - pas ingress-nginx, qui est retiré.

    Le chart ne crée que des `HTTPRoute` rattachées à cette Gateway (valeur
    `gateway.parentRefs`).

15. DNS : `*.<domaine des reviews>` et les hôtes de recette et de prod pointent vers la
    Gateway.

### Registre et secrets

16. **Jeton GHCR** : un PAT **classique** `read:packages`, appartenant à un compte
    machine qui a accès aux paquets `<dépôt>` et `<dépôt>/builds`.
    - GHCR n'accepte pas les PAT fine-grained, et les jetons d'app expirent en 1 h.
    - Il est stocké en secret `docker-registry` dans chaque namespace (nom dans les
      valeurs).
    - Sa rotation est à planifier.
17. **Secrets de recette et de prod**, créés dans le cluster, hors du dépôt et hors de
    GitHub, avec le nom et les clés attendus par le chart (§6.1) :
    - un Secret applicatif par namespace : `admin-passwd` (mot de passe maître),
      `admin-user-password` (mot de passe de l'utilisateur admin, lu au premier
      déploiement), et `smtp-password` pour la prod ;
    - n'importe quel outil peut le produire : `kubectl`, Sealed Secrets, SOPS, External
      Secrets (Vault, gestionnaire du fournisseur cloud, Infisical…). Exemples dans
      `deploy/examples/` ;
    - les identifiants PostgreSQL viennent du Secret `odoo-db-credentials` (`username`,
      `password`), créé avant la base et réutilisé par chaque cluster restauré ;
    - pour les reviews, les secrets sont générés par le chart.

### Accès de la CI et GitHub

18. **API du cluster joignable depuis les runners GitHub.** Aucune IP fixe n'est
    documentée pour les runners standard. Sinon : runners « larger » à IP fixe, ou
    runners dans le cluster.
19. **Un ServiceAccount de déploiement par namespace**, avec un Role limité au
    namespace. Le modèle documente les permissions nécessaires et fournit un Role de
    référence (`deploy/examples/ci-access.yaml`) que l'administrateur applique ou adapte
    : ressources du chart, `jobs`, `deployments/scale`, `volumesnapshots`, création et
    lecture des `backups` CNPG et lecture des `clusters` CNPG.
    - `deploy/examples/ci-kubeconfig.sh` produit son kubeconfig.
    - L'OIDC est un durcissement possible, selon le fournisseur.
20. **Environnements GitHub** `review`, `recette` et `production` :
    - secret `KUBECONFIG` dans chacun, seul secret côté GitHub ;
    - règles de branches et de tags (§2) ;
    - variable `REVIEW_MAX_APPS`. Les hôtes, le domaine des reviews, les namespaces et
      la Gateway sont dans `deploy/values/*.yaml`, versionnés et relus en PR.
21. **Ruleset sur les tags `v*`** : création réservée aux mainteneurs, puisqu'un tag
    déclenche une mise en prod.
22. Les pré-requis CI existants (rôle Admin sur les paquets). La CI v2 est verte sur
    GitHub (main, develop) depuis le 2026-10-16.

### Exploitation (recommandé, non fourni)

23. Logs, métriques et alertes : déploiement en échec, CrashLoopBackOff, sauvegarde
    manquée.
24. Une fenêtre de mise en prod : le tag coupe le service le temps de la mise à jour.

### Poste de dev

25. `kubectl`, Helm 4, kind et Docker. Pour ses propres tests, `ci/chart-e2e.sh`
    installe dans kind CNPG, csi-driver-host-path, snapshot-controller, une
    implémentation Gateway API et un stockage S3 (MinIO, image
    `cgr.dev/chainguard/minio` : MinIO ne publie plus d'image). Ce n'est pas une
    installation de référence pour un cluster.

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
- stratégie `Recreate` ; N réplicas (`odoo.replicas`), plusieurs seulement avec un
  filestore partagé ou sur S3 (§3.4) ;
- aucun produit d'infrastructure supposé : StorageClasses, `VolumeSnapshotClass`,
  Gateway et `ObjectStore` sont des noms dans les valeurs.

| Template                 | Rôle                                                                                                                                                                   |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deployment.yaml`        | Odoo, init container `wait-db` (§3.2), sidecar Mailpit (en option) ; `replicas` depuis `odoo.replicas`                                                                 |
| `job-migrate.yaml`       | Job `migrate` (§6.2) : hook `pre-upgrade` (mise à jour de recette et prod) ou `post-install` / `post-upgrade` (première installation, review)                          |
| `job-stop-snapshot.yaml` | Recette et prod : hook `pre-upgrade` (poids -5), arrêt d'Odoo et point de restauration `pending` (§6.2)                                                                |
| `job-validate.yaml`      | Recette et prod : hook `post-upgrade`, `pending` → `validated`                                                                                                         |
| `hooks-rbac.yaml`        | ServiceAccount, Role et RoleBinding des hooks, hooks `pre-install,pre-upgrade` de poids -10 (§6.4)                                                                     |
| `configmap-config.yaml`  | `odoo.conf` complet généré depuis `odoo.config`, sans secret (§6.1) ; copie `<release>-odoo-conf-hook` en hook pour les Jobs, rendue par le même helper                |
| `service.yaml`           | 8069 ; 8072 (`appProtocol: kubernetes.io/ws`) si `workers` > 0 ; 8025 (Mailpit)                                                                                        |
| `httproute.yaml`         | Hôte Odoo (`/websocket` vers 8072 en multi-process), hôte Mailpit, filtres optionnels ; rattaché à la Gateway de l'administrateur                                      |
| `pvc.yaml`               | Si `odoo.persistence.enabled` et sans `existingClaim` : `/var/lib/odoo`, recette et prod `<release>-odoo-data` (`keep`), review `<release>-odoo-data-<digest court>`   |
| `postgres.yaml`          | Base `ephemeral` (review) : PostgreSQL 18 (Deployment, Service `<release>-postgres`, volume `pgdata-<digest court>` sur `/var/lib/postgresql`, `POSTGRES_DB=postgres`) |
| `secrets.yaml`           | Review : mots de passe générés une fois, conservés via `lookup`                                                                                                        |
| `networkpolicy.yaml`     | Odoo joignable depuis la Gateway seulement ; base éphémère depuis les pods de la release seulement. Sortie libre ; une base externe a sa propre policy                 |
| `serviceaccount.yaml`    | Compte d'Odoo, sans jeton                                                                                                                                              |

**`values.yaml`** (avec `values.schema.json`) :

- `environment` : `review`, `recette` ou `production` (obligatoire) ;
- image et digest ;
- `odoo.replicas` ;
- `odoo.config` : sections et options d'`odoo.conf` (§6.1) ;
- `secrets` : nom du Secret applicatif, et variables `secrets.env` des modules ;
- `odoo.modules` : modules à installer. `odoo -i` a besoin des noms et Helm ne voit pas
  le contenu de l'image : la liste est dans les valeurs, et `ci/chart-lint.sh` vérifie
  qu'elle correspond aux dossiers d'`addons/` ;
- base : `ephemeral` (review) ou `external` (`database.external.host` et `.port`, le
  Service stable ; `database.external.secret` pour les identifiants) ; `database.name`,
  le nom de la base d'Odoo ;
- `odoo.persistence` : `enabled` (`true` par défaut), `accessMode`, `size`,
  `storageClass`, `existingClaim` (restauration manuelle du filestore) (§3.4) ;
- `jobs` : délais des Jobs (`activeDeadlineSeconds`), délai du snapshot ;
- `labelPrefix` : préfixe des étiquettes et annotations du chart (`odoo.haroldd.dev`) ;
- `restorePoints` : `keep` (3, au moins 1), image avec `sh` et `kubectl` des Jobs
  `stop-snapshot` et `validate`, délai du snapshot (§6.4) ;
- noms des StorageClasses, de la `VolumeSnapshotClass`, du secret de registre ; Gateway
  (`parentRefs`) et hôtes ; Mailpit ; ressources.

Les valeurs par environnement sont dans
`deploy/values/{review,recette,production}.yaml`. La CI n'ajoute que le digest. L'hôte
d'une review est déduit du nom de la release (`<projet>-pr-<n>.<domaine des reviews>`).

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
  - `PGHOST` et `PGPORT` depuis `database.external.host` et `.port` (le Service stable
    avec CNPG) ; `PGUSER` et `PGPASSWORD` depuis le Secret `database.external.secret`
    (clés `username` et `password`, celles d'`odoo-db-credentials`), ou depuis le Secret
    généré en review ; `PGDATABASE` vaut `database.name`. L'entrypoint officiel n'ajoute
    alors pas de `--db_*` ;
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

### 6.2 Jobs du chart

| Job                             | Conteneurs (dans l'ordre)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `stop-snapshot` (recette, prod) | 1. `stop` (image kubectl) : refus si un point `pending` complet est orphelin (§3.3) ; Deployments d'Odoo de la release à 0, attente de la fin des pods ; cluster actif lu dans le Service stable ; point `pending` complet existant → rien à prendre. 2. `restore-point` (image Odoo, `psql`, base `postgres`) : `pg_create_restore_point('<cluster>-preupgrade-r<révision>')` s'il y a un point à prendre. 3. `snapshot` (image kubectl) : `Backup` `method: volumeSnapshot`, `online: false`, étiquetée `pending`, annotée (image visée, nom du snapshot du filestore) ; lecture de son `metadata.uid` ; `VolumeSnapshot` `<nom>-filestore` avec une `ownerReference` vers la `Backup` (cet UID, sans `blockOwnerDeletion`) s'il y a un PVC ; attente de la `Backup` (`completed`, échec immédiat sur `failed`) et du snapshot (`readyToUse: true`), délai réglable (15 min par défaut) ; attente du pod primaire prêt |
| `migrate` (partout)             | 1. `db-init` : attente de la base (`pg_isready`), puis seulement si la base n'existe pas `odoo db init --password $(ODOO_INIT_ADMIN_PASSWORD)` (recette, prod) ou `--with-demo --password $(ODOO_REVIEW_ADMIN_PASSWORD)` (review). 2. `install` : `odoo -i <odoo.modules> --stop-after-init --no-http`. 3. `update` : `click-odoo-update`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `validate` (recette, prod)      | (image kubectl) 1. le point `pending` complet passe `validated` ; un échec ici fait échouer le hook. 2. suppression des points `pending` incomplets. 3. purge : au-delà des `keep` plus récents parmi les `validated` et `restored`, `kubectl delete backup` (les snapshots suivent). Les étapes 2 et 3 n'échouent jamais : une erreur est signalée dans les logs et le hook réussit                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |

- **Le point nommé avant le snapshot** : sur une instance unique, CNPG isole le primaire
  pendant le snapshot à froid, et `psql` ne pourrait plus s'y connecter. Odoo est déjà
  arrêté : la position dans les WAL vaut celle du snapshot. Le rôle `odoo` a le droit
  d'appeler la fonction dans la base `postgres` (`GRANT`, §4). Le nom est celui de la
  `Backup`.
- **Après le snapshot à froid**, CNPG déclare le `Cluster` prêt avant que le primaire
  accepte de nouveau des connexions par le Service : sans attente du pod primaire et
  sans `pg_isready`, le premier Job `migrate` de l'essai a échoué sur un refus de
  connexion.
- **Le Job `migrate`** n'a que des commandes natives d'Odoo ou de `click-odoo-contrib`,
  passées par l'entrypoint de l'image. Les Jobs `stop-snapshot` et `validate` ont des
  commandes `kubectl` courtes, écrites dans les templates et relues par le lint.
- **Tous les Jobs** : même image, même `odoo.conf` (ConfigMap des hooks) et mêmes
  Secrets que le pod Odoo ; noms fixes (`<release>-migrate`…) et
  `hook-delete-policy: before-hook-creation`, qui garde les logs jusqu'à la tentative
  suivante ; `backoffLimit: 0` (une migration partielle ne se rejoue pas toute seule),
  `activeDeadlineSeconds` réglable. Le `--timeout` de Helm doit couvrir leur somme.

Vérifié sur l'image (essais du 2026-10-16) :

- `odoo -i` sur une base vide déjà créée (cas CNPG) l'initialise ; sur une base
  initialisée, il ne fait rien (1 s), même si le code a changé. Il installe en revanche
  un module ajouté dans `addons/`, ce que `click-odoo-update` seul ne fait pas ;
- `click-odoo-update` met ensuite à jour les modules dont l'empreinte a changé (nouveau
  champ : colonne créée). Sur une base vide, il échoue : `-i` passe donc toujours avant
  ;
- au premier déploiement, `click-odoo-update` repasse une fois sur tous les modules
  (aucune empreinte enregistrée), puis enregistre les empreintes ;
- `odoo db init --with-demo --password X` crée la base de démo avec le mot de passe
  admin X, et **refuse une base qui existe déjà** (« exists, aborting ») ;
- `$(VAR)` est remplacé par Kubernetes depuis l'environnement du conteneur, sans shell :
  le mot de passe vient du Secret de la release et n'apparaît pas dans le manifeste.

Les Jobs ne neutralisent pas. Le pod Odoo, lui, ne fait que servir : un redémarrage ne
touche jamais la base.

### 6.3 Remise à zéro des reviews et garde-fous

Le chart ne contient **aucune commande de suppression de données** (`dropdb`, `DROP`,
`rm`, `--force`), pour aucun environnement. Le hook `validate` ne supprime que des
`Backup` de points de restauration (leurs snapshots suivent), et son Role ne lui donne
rien d'autre à supprimer (§6.4). La remise à zéro d'une review vient de ses volumes :

- avec une base `ephemeral`, le volume PostgreSQL (`pgdata-<digest court>`) et celui du
  filestore (`odoo-data-<digest court>`) ont le digest dans leur nom. Une nouvelle image
  donne des volumes neufs ; Helm supprime les anciens, qui ne sont plus rendus ;
- le PostgreSQL éphémère démarre sans la base d'Odoo, que `odoo db init` crée ;
- un redémarrage sans nouvelle image garde les mêmes volumes.

Garde-fous :

- **Au rendu (Helm).** Les volumes nommés par digest ne sont rendus qu'avec une base
  `ephemeral` et `environment: review` ; le template échoue (`fail`) sinon.
  `values.schema.json` n'accepte `ephemeral` qu'avec `environment: review`. En recette
  et en prod, le filestore est gardé (`keep`), et la base est installée à part : le
  chart n'a rien à supprimer. Une valeur mal placée fait échouer le lint et le
  déploiement, avant toute action.
- **À l'exécution.** `odoo db init` refuse une base existante (« exists, aborting ») :
  même mal configuré, il ne peut rien écraser. Seul `--force` supprimerait la base ; le
  lint l'interdit.
- **Par les droits.** Les comptes de déploiement sont propres à chaque namespace : le
  job `review` de la CI ne peut rien faire dans celui de la prod. Les deux comptes du
  chart n'ont que leurs verbes (§6.4).
- **Par les tests.** `ci/chart-lint.sh` vérifie que :
  - aucun rendu ne contient `dropdb`, `DROP DATABASE`, `rm` ni `--force` ;
  - les rendus de `recette.yaml` et `production.yaml` n'ont ni démo ni volume nommé par
    digest, et échouent avec `database.type=ephemeral` ;
  - l'étape `db-init` de recette et de prod n'a pas la démo et lit le mot de passe admin
    dans le Secret applicatif ;
  - aucun Job `stop-snapshot` ni `validate`, ni compte des hooks, n'est rendu en review
    ;
  - le Role des hooks n'a que les ressources et verbes du §6.4 ;
  - le snapshot du filestore porte une `ownerReference` sans `blockOwnerDeletion`.

L'image ne change pas pour Kubernetes, en dehors des phases 0 et 0 bis.

### 6.4 Compte des hooks et rétention des points de restauration

**Un seul compte, `<release>-hooks`**, en hook `pre-install,pre-upgrade` de poids -10
avec `before-hook-creation` : recréé à chaque mise à jour, non suivi par la release, il
n'existe que pour les hooks. Le compte d'Odoo reste sans jeton. Son Role, limité au
namespace :

| Ressource                                 | Verbes                                              | Pour                                                                                    |
| ----------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `apps/deployments`                        | `get`, `list`                                       | Trouver les Deployments d'Odoo de la release, lire leur image (point orphelin)          |
| `apps/deployments/scale`                  | `get`, `patch`                                      | Les passer à 0                                                                          |
| `pods`                                    | `get`, `list`, `watch`                              | Attendre la fin des pods d'Odoo, puis le pod primaire prêt                              |
| `services`                                | `get`                                               | Lire le cluster actif dans le sélecteur du Service stable                               |
| `postgresql.cnpg.io/clusters`             | `get`, `list`, `watch`                              | Attendre que le cluster soit prêt                                                       |
| `postgresql.cnpg.io/backups`              | `create`, `get`, `list`, `watch`, `patch`, `delete` | Créer le point, lire son UID et sa phase, l'étiqueter, purger                           |
| `snapshot.storage.k8s.io/volumesnapshots` | `create`, `get`, `list`, `watch`                    | Créer le snapshot du filestore, attendre `readyToUse`, vérifier qu'un point est complet |

Pas de `delete` sur les `volumesnapshots` : ils partent avec leur `Backup`, par CNPG
(`snapshotOwnerReference: backup`) pour la base et par le ramasse-miettes de Kubernetes
(`ownerReference`) pour le filestore. Pas de `blockOwnerDeletion` sur cette référence :
certains clusters exigeraient alors `update` sur `backups/finalizers`. Aucun accès aux
Secrets : les identifiants de la base arrivent dans les conteneurs par `secretKeyRef`.

**Rétention**, dans le hook `validate`, après chaque mise à jour réussie : de nouveaux
points n'apparaissent qu'aux mises à jour. Les snapshots copy-on-write consomment
l'espace modifié depuis leur prise, et leur accumulation dégrade le stockage : le chart
porte donc leur purge, ni la CI ni l'administrateur.

- Un point `pending` complet n'est jamais supprimé : pendant un incident, c'est le seul
  point de restauration valable.
- Les points `pending` incomplets sont supprimés : ils ne servent à rien et ne doivent
  pas compter parmi les `keep`.
- Les `restorePoints.keep` plus récents (3 par défaut) se comptent parmi les `validated`
  et `restored` de la release, triés par date ; les plus anciens sont supprimés par
  `kubectl delete backup`, une suppression par point.
- Une erreur de purge est signalée dans les logs et ne fait pas échouer le hook : la
  mise à jour a réussi, la purge reprendra à la suivante.
- Nombre de points borné : au plus `keep` + 1 (le point `pending` pendant une mise à
  jour). Après une restauration, le point `restored` est compté avec les autres et purgé
  à la prochaine mise à jour réussie.
- **Espace libéré** seulement avec une `VolumeSnapshotClass` en `deletionPolicy: Delete`
  (§4).
- **Image** des Jobs `stop-snapshot` et `validate` (décision du 2026-10-18) :
  `cgr.dev/chainguard/kubectl:latest-dev`, épinglée par digest (`restorePoints.image`).
  La variante `-dev` est nécessaire : l'image `latest` de Chainguard est distroless,
  sans shell, comme `registry.k8s.io/kubectl`. Elle fournit `sh`, `kubectl`, `awk`,
  `grep` et `head`, pas `jq` ; 43 Mo, non-root (uid 65532), utilisée aux essais. Rien
  n'est installé au lancement. En gratuit, Chainguard ne publie que les étiquettes
  `latest` et `latest-dev` : le digest est relevé à chaque montée de version du chart,
  et la valeur permet de pointer vers une copie dans le registre du projet si un digest
  venait à disparaître.
- Un administrateur qui supprime un point n'a qu'une `Backup` à supprimer ; il ne doit
  jamais supprimer un point `pending` complet.

## 7. Scripts `ci/`

La CI ne fait que lancer les commandes ; le cycle de mise à jour est dans le chart.

| Script                             | Rôle                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci/deploy.sh ENV IMAGE@DIGEST`    | Vérifications du §3.2 (dont la politique `Delete` des classes de snapshots et le point `pending` orphelin), même digest déjà déployé → rien, release « pending », `helm upgrade --install` (avec `--wait` pour une mise à jour de recette ou de prod, sinon `kubectl rollout status` ensuite), smoke HTTPS. Résumé du job avec les logs des Jobs de hook en échec et, en review, les identifiants. Plafond des reviews. Fonctions dans `ci/deploy-lib.sh` |
| `ci/deploy-restore.sh ENV [POINT]` | Job `restore` (§3.3) : point `pending` complet (ou `POINT` pour un retour arrière manuel), nouveau cluster CNPG, section `volumeSnapshot` recopiée, bascule du Service, `restored`, `helm rollback`, smoke ; sans point : `helm rollback` seul ; mise à jour appliquée et pods prêts : pas de restauration, alerte                                                                                                                                        |
| `ci/review-remove.sh N`            | `helm uninstall pr-<n>`, puis suppression des ressources de hook de la release (non suivies par Helm), par étiquette                                                                                                                                                                                                                                                                                                                                      |
| `ci/review-sweep.sh`               | Review apps des PR fermées (API GitHub) ; `DRY_RUN` et liste de PR factice pour les tests                                                                                                                                                                                                                                                                                                                                                                 |
| `ci/chart-lint.sh`                 | `helm lint`, rendu des trois environnements, kubeconform (avec les schémas des CRD), `odoo.conf` rendu comparé à un fichier attendu, `odoo.modules` conforme à `addons/`, garde-fous du §6.3                                                                                                                                                                                                                                                              |
| `ci/chart-e2e.sh`                  | kind avec CNPG, plugin Barman, csi-driver-host-path, les CRD Gateway API et MinIO, installés pour le test ; base de recette installée avec le chart `cnpg/cluster` et `deploy/examples` ; scénarios des phases 2, 3 et 3 bis, en local                                                                                                                                                                                                                    |

`ci/deploy-snapshot.sh` et `ci/deploy-rollback.sh` (phase 3) disparaissent : remplacés
par les hooks du chart et `ci/deploy-restore.sh`.

## 8. Workflows

- **`deploy.yml`** (nouveau, `workflow_call`) : deux jobs.
  - `deploy` : `environment: {name, url}` ; concurrence par environnement (et par PR
    pour les reviews), sans annulation ; Helm 4 épinglé, kubeconfig lu dans le secret
    d'environnement, puis `ci/deploy.sh`. Aucune configuration d'Odoo ni aucun secret
    applicatif ne passe par le workflow ; l'URL de l'environnement GitHub est lue dans
    les valeurs.
  - `restore` : `needs: deploy`, `if: failure()`, recette et prod seulement, même
    environnement et même concurrence, `ci/deploy-restore.sh`.
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
  permissions dont la CI a besoin, dont celles du job `restore` : créer un `Cluster` et
  son `ObjectStore`, modifier le Service stable, étiqueter une `Backup`), RoleBinding,
  jeton, et kubeconfig pour GitHub ;
- `app-secret.example.sh` : création du Secret applicatif avec `kubectl` (clés du §6.1)
  ;
- `external-secret.example.yaml` : le même Secret produit par External Secrets Operator
  ;
- `registry-secret.sh` : crée le secret de registre GHCR dans un namespace ;
- `cnpg-cluster.values.yaml` : base de recette ou de prod avec le chart `cnpg/cluster`
  (PG 18, plugin Barman Cloud, sauvegarde nocturne, un dossier S3 par environnement ;
  rôle `odoo` déclaré avec `odoo-db-credentials`, `GRANT` sur `pg_create_restore_point`)
  ; en tête, le patch `volumeSnapshot` avec `snapshotOwnerReference: backup` ;
- `cnpg-cluster-recovery.values.yaml` : base restaurée depuis le snapshot d'un point de
  restauration, une instance, mêmes rôles (runbook §3.3) ;
- `database-credentials.example.sh` : Secret `odoo-db-credentials`
  (`kubernetes.io/basic-auth`) ;
- `database-service.yaml` : Service stable `odoo-db` devant le primaire du cluster
  actif, et la commande de bascule ;
- `longhorn-volumesnapshotclass.yaml` : `VolumeSnapshotClass` Longhorn des points de
  restauration (`type: snap`, `deletionPolicy: Delete`) ;
- `database-networkpolicy.yaml` : entrée de la base autorisée aux pods Odoo, à
  l'opérateur CNPG et au plugin.

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
| 2     | Chart, Job `migrate`      | `ci/chart-lint.sh` ; scénarios de `ci/chart-e2e.sh` ci-dessous   |
| 3     | Scripts `ci/`             | shellcheck ; exécution contre kind ; sweep sur une liste factice |
| 3 bis | Restauration, rétention   | Essais puis scénarios ci-dessous (lint et e2e sur kind)          |
| 4     | Workflows                 | actionlint, pre-commit                                           |
| 5     | Exemples et documentation | kubeconform des exemples, dry-run serveur sur kind               |
| 6     | Validation réelle         | Scénarios ci-dessous, sur le dépôt de test et un vrai cluster    |

**Phase 1, essais :**

- avec un `odoo.conf` monté (`ODOO_RC`) et les secrets en variables `ODOO_*` et `PG*`,
  via notre entrypoint : `odoo`, `odoo db init`, `odoo -i` et `click-odoo-update` (déjà
  vérifiés avec les variables, §6.2) et le jobrunner de queue_job (section
  `[queue_job]`, `ODOO_QUEUE_JOB_HTTP_AUTH_PASSWORD`) lisent bien leur configuration ;
- `$(VAR)` dans les arguments d'un conteneur de Job, avec un mot de passe venant d'un
  Secret ;
- le rendu PDF fonctionne avec la racine en lecture seule ; PostgreSQL 18 et Mailpit
  tournent en non-root (PSA `restricted`) ;
- CNPG sur kind :
  - sauvegarde `volumeSnapshot` à froid ;
  - restauration dans un nouveau cluster ;
  - snapshots qui survivent à la suppression du cluster ;
  - archivage des WAL d'une nouvelle génération ;
- un volume créé depuis un `VolumeSnapshot`. La durée de restauration se mesure sur le
  stockage du vrai cluster, en phase 6.

**Phase 1, résultats (2026-10-16).** Tout passe. Essais sur l'image prod de `20.0`
(`9f68b4b`), Docker puis kind v0.33 (Kubernetes 1.37) avec CNPG 1.30.1, plugin Barman
Cloud 0.15.1, cert-manager 1.21, external-snapshotter 8.6, csi-driver-host-path 1.18 et
Mailpit 1.31.4.

| Essai                                     | Résultat                                                                                                                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| queue_job, `odoo.conf` monté (`ODOO_RC`)  | `channels` et `http_auth_user` lus dans `[queue_job]`, mot de passe lu dans `ODOO_QUEUE_JOB_HTTP_AUTH_PASSWORD` ; jobrunner démarré (`workers = 2`) ; job exécuté sur `root.channel1` |
| `$(VAR)` dans les arguments du Job        | La spec garde `$(ODOO_REVIEW_ADMIN_PASSWORD)` ; connexion `admin` avec le mot de passe du Secret, `admin`/`admin` refusé                                                              |
| Job `migrate` (`db init`, `-i`, update)   | Les trois étapes passent en PSA `restricted`, racine en lecture seule                                                                                                                 |
| `db init` sur une base existante          | Refus, code 1 ; `--force` supprimerait la base : ajouté au lint (§6.3)                                                                                                                |
| PDF, racine en lecture seule              | `%PDF`, en Docker et dans le pod                                                                                                                                                      |
| PostgreSQL 18 et Mailpit non-root         | PSA `restricted`, racine en lecture seule (`emptyDir` sur `/var/run/postgresql` et `/tmp`) ; mail envoyé via `smtp_server` de `odoo.conf`, visible dans Mailpit                       |
| CNPG, sauvegarde `volumeSnapshot` à froid | 31 s ; le `VolumeSnapshot` n'a pas d'`ownerReference` : lui et le `Backup` survivent à la suppression du `Cluster`                                                                    |
| Restauration en génération 2              | 30 s ; données exactement celles du snapshot ; archivage des WAL actif sous le nouveau `serverName`                                                                                   |
| Filestore depuis un `VolumeSnapshot`      | Odoo à 0, snapshot, PVC créé depuis le snapshot : 116 fichiers sur 116, Odoo répond                                                                                                   |

Constats pour la suite :

- **queue_job n'est pas encore publié pour 20.0.** La branche `20.0` d'OCA/queue le
  marque non installable ; l'essai a utilisé la PR de migration OCA/queue#999
  (`2b08ccd`). Il dépend aussi d'`openupgradelib`, absent de l'image : c'est au projet
  qui l'utilise de l'ajouter à ses dépendances.
- Le chart pose `POSTGRES_DB=postgres` pour la base éphémère, sinon l'image crée la base
  d'Odoo et `db init` refuse ; la sonde `pg_isready` vise `-d postgres`.
- Les ancres YAML ne traversent pas `---` : sans importance pour Helm, à noter pour les
  exemples.

**Phase 2, scénarios de `ci/chart-e2e.sh` :**

- review :
  - installation (Odoo à 0, Job `migrate` avec `db init`, Odoo à 1), avec `/web/health`
    et `/web/login` à 200 ;
  - nouvelle image → volumes neufs, anciens supprimés, base de démo recréée ;
  - redémarrage du pod → aucun Job, données conservées ;
- garde-fous : `database.type=ephemeral` avec les valeurs de recette ou de prod → échec
  du rendu ; `db init` sur une base existante → refus ;
- recette :
  - première installation (Job `migrate` sur base vide) ;
  - mise à jour avec point de restauration ;
  - module cassé → Job en échec → Odoo reste arrêté ;
  - runbook : base restaurée à l'heure du point de restauration (chart `cnpg/cluster`),
    filestore depuis son snapshot, digest précédent.

**Phase 2, résultats (2026-10-16).** `ci/chart-lint.sh` : 23 contrôles sur 23.
`ci/chart-e2e.sh` : 32 scénarios sur 32, sur kind (Kubernetes 1.37), en PSA
`restricted`, NetworkPolicy actives. Écarts et corrections :

- **Noms préfixés par la release** : `<release>-odoo-data-<g>`, `<release>-pg-<g>`,
  `<release>-pgdata-<digest court>`, `<release>-secrets` (plusieurs reviews partagent un
  namespace).
- **Pas d'`inheritedMetadata` sur le `Cluster` CNPG** : ses labels `app.kubernetes.io/*`
  écrasaient ceux de CNPG sur le volume de l'instance, et la sauvegarde `volumeSnapshot`
  restait bloquée sans erreur. La NetworkPolicy de la base vise `cnpg.io/cluster`.
- **`serverName` Barman = `<namespace>-<release>-pg-<g>`** : Barman refuse d'archiver
  dans un dossier non vide ; deux environnements sur le même bucket, ou un environnement
  réinstallé, se bloqueraient.
- **Digests réels en e2e** : registre local branché sur kind (`kind load` ne permet pas
  de référencer une image par digest).
- Les points de restauration et le rollback sont pilotés par des fonctions de
  `ci/chart-e2e.sh`, qui préfigurent `ci/deploy.sh` (phase 3). Le rollback manuel est
  reporté à la phase 3 (`ci/deploy-rollback.sh`).
- La Gateway n'est pas installée dans kind : seules les CRD Gateway API le sont
  (`HTTPRoute` validées). HTTPS et websocket restent testés en phase 6.
- L'exclusion des templates Helm de prettier et de check-yaml (§8) est faite dès la
  phase 2, pour pouvoir committer le chart.
- **Point ouvert** : en recette et en prod, `odoo -i` sur une base vide laisse l'admin
  avec le mot de passe `admin`. Traité en phase 3 : Odoo crée sa base avec
  `odoo db init --password` (§3.2).

**Phase 2 bis, base externe (2026-10-16).** Sur décision de Harold, le chart ne gère
plus la base de recette ni de prod : `database.type` vaut `ephemeral` (review) ou
`external` (Secret existant). Les résultats de phase 2 sur le `Cluster` CNPG du chart
(`inheritedMetadata`, `serverName`) ne le concernent plus ; le second reste une règle
d'exploitation : un dossier Barman par environnement. `ci/chart-lint.sh` : 26 contrôles
sur 26. `ci/chart-e2e.sh` : 44 scénarios sur 44 (recette sur une base installée avec le
chart `cnpg/cluster` 0.9.0, contrôle préalable du patch, runbook de restauration depuis
le snapshot compris). Écarts et corrections :

- **Point de restauration par snapshot de volume à froid** : le chart `cnpg/cluster` ne
  sait pas écrire `spec.backup.volumeSnapshot`
  ([#900](https://github.com/cloudnative-pg/charts/issues/900)). Une première version
  passait par une sauvegarde Barman et une PITR, écartée : sur 100 à 200 Go, elle
  enverrait toute la base vers S3 à chaque déploiement et la retéléchargerait à chaque
  restauration. L'administrateur ajoute la section par `kubectl patch` après chaque
  installation de la base ; essai sur kind : le patch survit à `helm upgrade` (mêmes
  valeurs, valeurs changées, `--reuse-values`), car Helm 4 applique côté serveur et ne
  gère pas ce champ. La restauration passe par le chart (`recovery.method: backup`) ; la
  base restaurée n'hérite pas du patch, d'où l'étape dans le runbook et le contrôle
  préalable de la CI.
- **Chiffrement côté serveur** : le chart `cnpg/cluster` demande `AES256` par défaut ;
  MinIO sans KMS refuse alors tout envoi et l'archivage échoue sans bloquer le `Ready`
  du `Cluster`. L'e2e le désactive et attend `ContinuousArchiving` ; l'exemple le
  documente.
- **Helm isolé dans l'e2e** (`HELM_CACHE_HOME`, `HELM_CONFIG_HOME`, `HELM_DATA_HOME`) :
  `helm --repo` lisait les dépôts du poste et échouait sur un index absent.

**Phase 3, résultats (2026-10-17).** Scripts `ci/deploy.sh`, `ci/deploy-lib.sh`,
`ci/deploy-snapshot.sh`, `ci/deploy-rollback.sh`, `ci/review-remove.sh`,
`ci/review-sweep.sh` ; shellcheck sans remarque. `ci/chart-e2e.sh` déploie désormais par
ces scripts : 70 scénarios sur 70 (review, plafond, relance de la même image,
garde-fous, recette de la première installation à la restauration, déploiement suivant,
sweep sur une liste factice). `ci/chart-lint.sh` : 28 contrôles sur 28. Décisions et
écarts :

- **Mot de passe admin** (décision de Harold) : Odoo crée sa base au premier
  déploiement, Job `db-init` avec `odoo db init --password` (clé `admin-user-password`
  du Secret applicatif) ; CNPG donne `CREATEDB` au rôle `odoo` (`postInitSQL`), sa base
  `app` reste vide ; le chart prend `database.name` pour `PGDATABASE`. Job à part (et
  non étape du Job `migrate`) : un premier déploiement interrompu après la création de
  la base se relance, « exists, aborting » vaut « base déjà créée ».
- **Bloc `state`** (décision de Harold) : état de l'environnement écrit par la CI et
  reporté à chaque déploiement ; remplace `generation` et `restore.filestore`. Sans lui,
  le déploiement qui suit une restauration revenait au premier filestore et à la base en
  échec.
- **Rétention** (décision de Harold) : la CI ne supprime aucun point de restauration ;
  le résumé les liste, l'administrateur purge. Remplacée en phase 3 bis par la purge du
  hook `validate` (§6.4).
- **Contrôle `volumeSnapshot` dès le premier déploiement** : le patch est exigé dès
  l'installation de la base, l'oubli se voit tout de suite.
- **Même image déjà en service** : seulement remise à 1 (le Job `migrate` disparaît à
  l'étape de démarrage, une relance aurait tout rejoué et cassé une review sur
  `db init`). Après un échec, la relance est une nouvelle tentative.
- **Valeurs lues sans `yq`** : `helm upgrade --dry-run=server -o json`, valeurs du chart
  fusionnées avec celles de l'environnement par `jq`.
- **Helm 4** : `helm list` liste tous les statuts par défaut, `-a` n'existe plus.
- **Logs des Jobs** : `kubectl logs --all-containers --ignore-errors`, sinon un
  conteneur pas encore démarré peut masquer les logs de l'étape en échec.
- `EXTRA_VALUES` (fichier de valeurs ajouté, tests seulement) remplace les arguments
  Helm en plus.

**Phase 3 bis, le chart porte le cycle de mise à jour (décisions du 2026-10-18).** Un
seul lot.

**Phase 3 bis, résultats des essais (2026-10-18).** Sur kind (contexte `kind-odoo-e2e`,
namespace `trial`, PSA `restricted`), avec un chart prototype : Deployments factices,
vraies `Backup` CNPG 1.30.1 (chart `cnpg/cluster` 0.9.0, plugin Barman), « migration »
en `psql` qui écrit puis échoue à la demande, et l'image Odoo de l'e2e pour le
filestore.

| Essai                            | Résultat                                                                                                                                                                                                                                                                                   |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1. Séquence des hooks            | OK : mise à jour complète en 45 s ; après `kubectl scale` à 0, Helm 4 réapplique le nombre de réplicas, et le champ `replicas` appartient de nouveau à `helm` (pas de dérive)                                                                                                              |
| 2. États                         | OK : la relance après échec garde le point `pending` (« Pas de nouveau snapshot ») ; la relance réussie le valide                                                                                                                                                                          |
| 3. Première installation, review | `--wait` bloque `post-install` (correction du §3.2) ; sans `--wait`, review en 3 s et nouvelle image en 4 s ; relance d'une première installation en échec = mise à jour ; RWO sur plusieurs nœuds non testable (kind à un nœud)                                                           |
| 4. Rôles déclarés                | OK : rôle `odoo` réconcilié, `CREATEDB`, non superutilisateur ; même mot de passe sur le cluster restauré, par le Service stable                                                                                                                                                           |
| 5. Point nommé                   | OK dans la base `postgres` (refus dans `app`) ; restauration Barman avec `targetName` : exactement l'état d'avant la mise à jour, avec un `Cluster` brut et le `backupID` d'une sauvegarde de base antérieure (exigé par CNPG, et le chart ne rend pas `targetName`) : runbook de sinistre |
| 6. Rétention                     | OK : CNPG étiquette ses snapshots `cnpg.io/backupName` ; `snapshotOwnerReference: backup` et l'`ownerReference` du filestore : `kubectl delete backup` supprime les deux snapshots et leurs `VolumeSnapshotContent` (classe en `Delete`)                                                   |
| 7. Filestore                     | OK : le fichier d'une pièce jointe supprimée survit à `odoo -u base` et à `click-odoo-update` ; marqueur de `wait-db` : `module_auto_update.installed_checksums`                                                                                                                           |
| 8. Image kubectl                 | `registry.k8s.io/kubectl` et `rancher/kubectl` sans shell ; retenue : `cgr.dev/chainguard/kubectl:latest-dev` (§6.4), qui a servi aux essais                                                                                                                                               |
| 9. Job `restore`                 | OK en 32 s : base revenue au point, ancienne image, Service basculé, nouveau cluster archivant dans son propre `ObjectStore`, point `restored` ; la mise à jour suivante prend son snapshot sur le nouveau cluster. Lancé avec les droits d'administrateur : Role de la CI à vérifier      |

Corrections reportées dans le plan : `--wait` seulement pour les mises à jour (§3.2) ;
attente du primaire et `pg_isready` après le snapshot (§6.2) ; `GRANT` et appel dans la
base `postgres` (§4) ; PITR par nom avec `backupID` (§3.4) ; échec immédiat sur une
`Backup` en échec ; rétention dans `validate` plutôt qu'un CronJob, `Backup`
propriétaire de tous les snapshots du point (§6.4) ; point complet et point orphelin
(§3.3).

Changements :

- **chart** :
  - hooks `stop-snapshot`, `migrate`, `validate` (avec la rétention), ConfigMap et RBAC
    des hooks ;
  - init container `wait-db` ; Jobs en `post-*` à la première installation et en review
    ;
  - `database.external.host` et `.port`, Secret aux clés `username` et `password` ;
  - modes du filestore (`enabled`, `accessMode`, `existingClaim`), refus de plusieurs
    instances sur un volume RWO ;
  - fin de `state`, `jobs.migrate.run`, `jobs.dbInit`, de la génération du filestore et
    de `database.external.cnpgCluster` ;
- **scripts** : `ci/deploy.sh` réduit aux vérifications, à `helm upgrade` et au smoke ;
  `ci/deploy-restore.sh` ; fin de `ci/deploy-snapshot.sh` et `ci/deploy-rollback.sh` ;
- **exemples** : Service stable, Secret des identifiants, rôles et `GRANT`, patch avec
  `snapshotOwnerReference`, classe de snapshots en `Delete`, Role de la CI élargi pour
  la restauration.

Scénarios :

- `chart-lint` :
  - hooks et compte rendus en recette et en prod avec leurs seuls verbes, absents en
    review ;
  - Jobs en `post-*` à l'installation et en review, en `pre-upgrade` sinon ;
  - modes du filestore ; refus de plusieurs instances sur un volume RWO ;
  - ConfigMap des hooks identique à celle des Deployments ;
- `chart-e2e` :
  - review : installation et nouvelle image, pod en attente de la base ;
  - recette : première installation en `post-install` ;
  - mise à jour réussie : `pending` puis `validated` ;
  - module cassé : `deploy` en échec, Odoo à 0 ; `restore` : nouveau cluster, Service
    basculé, `restored`, ancienne image, données du point ;
  - relance après échec : pas de nouveau point, la relance réussie valide le premier ;
  - snapshot de la base en échec, puis snapshot du filestore en échec : point incomplet,
    `helm rollback` seul, base intacte ; la mise à jour suivante supprime le point
    incomplet ;
  - point orphelin (`validate` cassé) : la CI et `stop-snapshot` refusent la mise à jour
    suivante ; le job `restore` ne restaure pas ;
  - rétention : quatre mises à jour réussies → trois points restent, snapshots de base
    et de filestore supprimés avec leur `Backup` ; une erreur de purge laisse le hook
    réussir ;
  - mode sans PVC : point de restauration réduit à la `Backup`.
- Restent pour la phase 6 : RWO sur plusieurs nœuds, Role de la CI, durées sur Longhorn.

**Phase 3 bis, résultats (2026-10-18).** Chart, scripts et exemples livrés.
`ci/chart-lint.sh` : 49 contrôles sur 49 (trois mutations du chart vérifiées : verbe
ajouté au Role, `blockOwnerDeletion`, affinité retirée, chacune fait échouer son
contrôle). `ci/chart-e2e.sh` : 116 scénarios sur 116 sur kind (Kubernetes 1.37, CNPG
1.30.1, PSA `restricted`), environ 40 min. Écarts et précisions :

- **Valeurs** : `restorePoints.volumeSnapshotClass` remplace
  `snapshots.volumeSnapshotClass` ; `database.external.host` est le Service stable, dans
  le namespace de la release (son premier label donne le nom du Service). Préfixe des
  étiquettes `odoo.haroldd.dev` (décision du 2026-10-19), valeur `labelPrefix` commune à
  toutes les étiquettes du chart, `odoo.dev/*` compris (domaine qui n'est pas le nôtre).
- **Jeton des hooks** : pas de montage automatique ; un volume projeté le monte dans les
  seuls conteneurs `kubectl` de `stop-snapshot` et `validate`, pas dans le conteneur
  `restore-point` (image Odoo).
- **`kubectl scale`** passe avec `get` et `patch` sur `deployments/scale`, sans `update`
  (vérifié en e2e).
- **Affinité RWO** : le pod Odoo porte l'étiquette `<préfixe>/digest` ; le Job `migrate`
  en `post-*` vise le pod de la même image, pas l'ancien pod en cours d'arrêt d'une
  review.
- **`admin-user-password`** lu en `optional` : la clé peut disparaître après la première
  installation ; `db-init` échoue avec un message clair seulement s'il doit créer la
  base sans elle.
- **Révision visée par `helm rollback`** (`ci/deploy-restore.sh`) : la dernière révision
  `deployed` ou `superseded` antérieure à celle du point (`-r<N>`), ou à la dernière
  révision sans point. Avec `POINT` (retour arrière manuel), Odoo est d'abord arrêté.
- **Sauvegarde nocturne** : le chart `cnpg/cluster` lance une `Backup` à l'installation
  (`immediate: true`). Elle n'a pas les étiquettes d'un point de restauration : ni la
  rétention ni la CI ne la voient.
- **Échecs injectés** dans l'e2e par un `helm upgrade` à la main : section
  `volumeSnapshot` retirée (snapshot de la base), classe inexistante (snapshot du
  filestore), point validé repassé `pending` (point orphelin),
  `ValidatingAdmissionPolicy` qui refuse la suppression d'une `Backup` (erreur de
  purge).
- **Retour du mode sans PVC au PVC** : Helm réadopte le volume gardé (`keep`), Odoo
  retrouve son filestore.
- **Reste pour la phase 5** : Role de la CI (`deploy/examples/ci-access.yaml`), dont les
  droits du job `restore` (`Cluster`, `ObjectStore`, Service, `Backup`, release Helm de
  la base) ; documentation du chart publiable et runbooks.

**Phase 6, scénarios :**

1. PR → URL HTTPS, connexion, websocket (bus), mails visibles dans Mailpit ;
2. push → remise à zéro ; fermeture → suppression ;
3. draft → pas de review app, puis « ready for review » → review app ;
4. plafond atteint → refus explicite ;
5. `release/0.1.0` → recette (première installation) ; nouveau push → mise à jour avec
   point de restauration, coupure mesurée ;
6. hotfix pendant la release (cas 2) → la recette bascule sur le hotfix, puis revient ;
7. tag `v0.1.0` → prod ;
8. mise à jour cassée en recette → Odoo arrêté, alerte, runbook de restauration ;
9. restauration après sinistre depuis S3, dans un namespace vierge ;
10. rafraîchissement de la recette depuis la prod, neutralisée (runbook) ;
11. sweep et nettoyage nocturne.

## 12. Risques

| Risque                                                          | Mitigation                                                                                                                                                            |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Remise à zéro déclenchée hors review                            | Aucune suppression dans le chart ; volumes par digest refusés hors review ; `db init` refuse une base existante ; droits par namespace ; lint (§6.3)                  |
| Restauration incorrecte                                         | Job `restore` testé en e2e et en phase 6 ; l'ancien cluster n'est jamais supprimé par la CI ; Service stable basculé seulement après `Ready`                          |
| Job `migrate` en échec ou trop long                             | `backoffLimit: 0`, délais réglables, `--timeout` de Helm, logs dans le résumé, restauration automatique                                                               |
| Restauration lente sur un gros volume (selon le stockage)       | Mesurée en phase 6 et documentée                                                                                                                                      |
| Coupure prolongée après un échec de mise à jour en prod         | Job `restore` automatique : cluster restauré depuis un snapshot local, ancienne image ; alerte                                                                        |
| Snapshot ≠ sauvegarde                                           | Base : sauvegarde Barman hors cluster ; filestore : sauvegarde hors cluster recommandée ; test de restauration                                                        |
| Fonction du cluster absente ou différente                       | Vérifiée par `ci/deploy.sh` avant toute coupure ; noms des ressources dans les valeurs                                                                                |
| Copie de la prod en recette sans neutralisation                 | Runbook de rafraîchissement avec `odoo db load -n`                                                                                                                    |
| Review apps exposées (code des PR, démo)                        | Mot de passe aléatoire, NetworkPolicy, filtre d'accès, prod sur un autre cluster                                                                                      |
| API du cluster exposée, jeton longue durée                      | Role limité au namespace, règles d'environnement, ruleset des tags, rotation ; OIDC ou ARC en durcissement                                                            |
| Websockets selon l'implémentation Gateway                       | `appProtocol: kubernetes.io/ws`, testé en phase 6                                                                                                                     |
| Plusieurs instances sur un volume RWO                           | Refusé au rendu ; RWX ou filestore S3 (§3.4)                                                                                                                          |
| Run annulé pendant `helm upgrade` (release « pending »)         | Hook encore actif : refus du run suivant ; sinon traité comme un échec (`restore`) ; aucune annulation des déploiements                                               |
| Relance après échec qui snapshotterait une base à moitié migrée | État `pending` : pas de nouveau point tant que le premier n'est ni validé ni restauré                                                                                 |
| Hook `validate` en échec après une mise à jour réussie          | La `Backup` reste `pending` (côté sûr) ; levée à la main, documentée                                                                                                  |
| Purge d'un point encore utile                                   | Jamais un point `pending` complet ; les `keep` plus récents gardés ; points incomplets supprimés seulement                                                            |
| Snapshots accumulés, stockage saturé ou ralenti                 | Purge à chaque mise à jour réussie ; `deletionPolicy: Delete` vérifiée par la CI                                                                                      |
| Point `pending` orphelin après un `validate` en échec           | La CI et `stop-snapshot` refusent la mise à jour suivante ; le job `restore` ne restaure pas une mise à jour appliquée et servie ; levée à la main                    |
| Sessions perdues sans PVC                                       | Documenté (§3.4) ; module de sessions en base ou Redis au choix du projet                                                                                             |
| Secret changé sans redémarrage d'Odoo                           | Runbook de rotation ; Reloader en option                                                                                                                              |
| Image des hooks introuvable (digest Chainguard retiré)          | Digest relevé à chaque version du chart ; `restorePoints.image` peut viser une copie dans le registre du projet ; le preflight de la CI vérifie que l'image se résout |
| Secret applicatif absent ou clé manquante                       | Vérifié par `ci/deploy.sh` avant l'arrêt ; sinon le pod reste en `CreateContainerConfigError`                                                                         |

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
