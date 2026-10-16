# Review apps Odoo sur Kubernetes et CD recette / prod : rapport de recherche

_Généré le 2026-10-16 | 4 axes, ~370 appels d'outils, ~190 sources citées | Confiance :
moyenne à haute (faits sourcés ; les inférences sont signalées « inférence »)_

## Résumé

- **runboat** (`sbidoul/runboat`, il n'y a pas de dépôt OCA) est un contrôleur conçu
  pour les dépôts d'addons OCA. Il télécharge le code du commit (tarball GitHub anonyme)
  et l'installe au démarrage dans une image oca-ci.
  - Pour un projet privé avec une image prod déjà construite, il faudrait réécrire ses
    kubefiles et ses scripts.
  - Il ne fait pas le CD.
  - Il a un mainteneur principal et peu d'activité en 2026.
- **Outils GitOps** : Argo CD 3.5 (générateur Pull Request) et Flux Operator
  (`ResourceSet` + fournisseur `GitHubPullRequest`) savent créer une application par PR.
  En contrepartie :
  - un composant de plus à exploiter ;
  - une latence de polling sans webhook (30 min par défaut pour Argo, 10 min pour Flux)
    ;
  - une course avec la CI : l'image n'est pas encore publiée quand l'outil voit le
    commit.
- **Déploiement poussé depuis GitHub Actions avec Helm** : c'est l'option qui suit le
  pipeline existant. Elle déploie exactement le digest testé, au moment de l'événement,
  et respecte la règle de la recette partagée (« le dernier déployé occupe
  l'environnement »). Le coût : l'API du cluster doit être joignable depuis GitHub, et
  un jeton de déploiement est stocké dans un environnement GitHub.
- **Odoo 20 sur Kubernetes** :
  - un seul replica par environnement : le filestore et les sessions sont sur volume, et
    le stockage S3 d'OCA n'est pas porté en 20.0 ;
  - la mise à jour des modules se fait Odoo arrêté, puis on redémarre ;
  - un rollback, c'est la restauration de la base plus l'image précédente.
- **ingress-nginx est retiré** (dépôt archivé le 24/03/2026) : il faut passer par
  Gateway API.

## 1. runboat (OCA)

- **Ce que c'est.** Un contrôleur Kubernetes (FastAPI) qui déploie une instance Odoo par
  commit de branche ou de PR. Il remplace le runbot OCA. Licence MIT, par Stéphane
  Bidoul (ACSONE). Il n'y a aucun dépôt sous l'organisation OCA.
  ([README](https://github.com/sbidoul/runboat),
  [recherche OCA](https://github.com/orgs/OCA/repositories?q=runboat))
- **État.** Il vit dans les labels et annotations Kubernetes, avec un index SQLite en
  mémoire reconstruit depuis le cluster. runboat n'a pas de base à lui.
  ([db.py](https://raw.githubusercontent.com/sbidoul/runboat/main/src/runboat/db.py))
- **Déclenchement.**
  - Webhook GitHub uniquement, pas de polling.
  - Ouverture ou mise à jour d'une PR : déploiement. Fermeture : suppression.
  - Statut de commit `runboat/build` sur la PR.
  - La signature HMAC n'est vérifiée que si `RUNBOAT_GITHUB_WEBHOOK_SECRET` est défini.
    ([webhooks.py](https://raw.githubusercontent.com/sbidoul/runboat/main/src/runboat/webhooks.py),
    [github.py](https://raw.githubusercontent.com/sbidoul/runboat/main/src/runboat/github.py))
- **Récupération du code.** Le job d'initialisation lance
  `curl https://github.com/<repo>/tarball/<sha>` **sans authentification**, puis
  `oca_install_addons`.
  ([runboat-clone-and-install.sh](https://raw.githubusercontent.com/sbidoul/runboat/main/src/runboat/kubefiles/runboat-clone-and-install.sh))
  Inférence : sur un dépôt privé, cette étape échoue avec la configuration par défaut.
- **Image.** Elle est fixée par entrée de `RUNBOAT_REPOS`
  ([settings.py](https://raw.githubusercontent.com/sbidoul/runboat/main/src/runboat/settings.py)).
  L'image `odoo:20.0` n'a pas les outils oca-ci (unbuffer, git, manifestoo, `oca_*`,
  `/opt/odoo-venv`)
  ([Dockerfile 20.0](https://raw.githubusercontent.com/odoo/docker/master/20.0/Dockerfile)).
  Inférence : il faudrait réécrire les kubefiles et les scripts d'init et de démarrage.
- **Base de données.**
  - Un PostgreSQL externe partagé, avec un rôle qui peut créer des bases.
  - Deux bases par build : une complète et une `-baseonly`.
  - La démo est forcée (`with_demo = True`), car Odoo 19+ ne la charge plus par défaut.
    ([runboat-initialize.sh](https://raw.githubusercontent.com/sbidoul/runboat/main/src/runboat/kubefiles/runboat-initialize.sh))
- **Plafonds.**
  - Par défaut : `MAX_INITIALIZING` 2, `MAX_STARTED` 6, `MAX_DEPLOYED` 10.
  - Les builds arrêtés sont à 0 replica.
  - Démarrage et arrêt passent par l'API ; aucun réveil automatique sur requête n'a été
    trouvé.
    ([controller.py](https://raw.githubusercontent.com/sbidoul/runboat/main/src/runboat/controller.py))
- **Sécurité.**
  - Dans le code consulté, seules les routes deploy/undeploy de l'API demandent une
    authentification ; start, stop, redeploy et les GET n'en demandent pas.
  - Les builds sont servis en HTTP, aucun TLS n'est décrit.
    ([api.py](https://raw.githubusercontent.com/sbidoul/runboat/main/src/runboat/api.py))
- **Activité.**
  - Commits de septembre à novembre 2025 : démo Odoo 19+ et modes start/stop.
  - Puis deux petits commits en mai 2026.
  - Inférence : un mainteneur principal.
    ([commits](https://github.com/sbidoul/runboat/commits/main))
- **À vérifier.** La ligne d'installation `odoo … || dropdb … && exit 0` semble sortir
  en 0 même si l'installation échoue (précédence shell ; inférence non vérifiée). Un
  build cassé pourrait donc apparaître réussi.

## 2. Autres approches propres à Odoo

- **runbot d'Odoo.** C'est un addon Odoo avec Docker, nginx et systemd, sans Kubernetes
  ; il est « not safe by itself ». ([odoo/runbot](https://github.com/odoo/runbot))
- **Odoo.sh**, comme référence d'expérience utilisateur :
  - développement : une base neuve avec démo et les tests, gardée environ 3 jours ;
  - staging : une copie **neutralisée** de la prod ;
  - production : une par projet.
    ([builds](https://www.odoo.com/documentation/20.0/administration/odoo_sh/getting_started/builds.html),
    [branches](https://www.odoo.com/documentation/20.0/administration/odoo_sh/getting_started/branches.html))
- **Camptocamp et Doodba.** Images et Compose, sans review apps Kubernetes.
  L'odoo-bedrock-k8s-deployer d'ACSONE est archivé depuis 2019.
  ([camptocamp](https://github.com/camptocamp/docker-odoo-project),
  [doodba](https://github.com/Tecnativa/doodba),
  [acsone](https://github.com/acsone/odoo-bedrock-k8s-deployer))
- **Opérateurs Odoo.** Ils sont immatures ou abandonnés : Glasskube ne documente pas les
  modules sur mesure, et xoe-labs/odoo-operator renvoie une 404.
  ([glasskube](https://glasskube.eu/en/r/guides/odoo-kubernetes/))
- **Charts.**
  - Bitnami : d'après des sources secondaires, le catalogue gratuit est passé sur
    `bitnamilegacy` fin août 2025.
    ([rafay](https://docs.rafay.co/blog/2025/09/04/important-update-changes-to-bitnami-public-catalog/))
  - IMIO/helm-odoo : conçu pour les besoins d'IMIO.
    ([IMIO](https://github.com/IMIO/helm-odoo))
- **Inférence.** Rien n'est réutilisable tel quel pour une image prod déjà construite.

## 3. Outils génériques de preview sur Kubernetes

- **Argo CD v3.5.5** (12/10/2026)
  ([releases](https://github.com/argoproj/argo-cd/releases)).
  - Le générateur PR fournit `number`, `branch`, `branch_slug`, `head_sha`,
    `head_short_sha` (8 caractères), `head_short_sha_7` et `labels`, et filtre par
    labels (ET).
  - `requeueAfterSeconds` vaut 30 min par défaut ; un webhook supprime ce délai mais
    demande d'exposer le service.
  - Quand la PR est fermée, l'Application est supprimée. Les ressources ne le sont
    qu'avec le finalizer `resources-finalizer.argocd.argoproj.io`.
    ([générateur PR](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/),
    [suppression](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/))
- **Hooks PreDelete d'Argo CD**, depuis v3.3.0. Un hook en échec bloque la suppression.
  ([v3.3.0](https://github.com/argoproj/argo-cd/releases/tag/v3.3.0),
  [sync-waves](https://argo-cd.readthedocs.io/en/release-3.3/user-guide/sync-waves/))
- **Course avec la CI.** Si l'outil synchronise avant que l'image soit publiée, le pod
  passe en ImagePullBackOff, avec des tentatives espacées de 300 s au plus. Le
  `progressDeadlineSeconds` par défaut est de 600 s.
  ([images](https://kubernetes.io/docs/concepts/containers/images/),
  [deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/))
- **Flux v2.9.6 et Flux Operator v0.61.0.**
  - `ResourceSetInputProvider` de type `GitHubPullRequest` : filtre par labels,
    intervalle de 10 min par défaut, `Receiver` webhook.
  - Le cas d'une PR fermée sans merge n'est pas documenté. Licence AGPL-3.0.
    ([github-pull-requests](https://fluxoperator.dev/docs/resourcesets/github-pull-requests/),
    [CRD](https://fluxoperator.dev/docs/crd/resourcesetinputprovider/))
- **Déploiement poussé (GitHub Actions).**
  - Les PR de fork n'ont pas les secrets.
  - OIDC : permission `id-token: write`, sujet `repo:ORG/REPO:environment:NAME`. Les
    dépôts créés après le 15/07/2026 ont un format de sujet immuable.
  - Les runners standard n'ont pas d'IP fixe ; les IP statiques sont réservées aux
    larger runners, facturés.
  - ARC 0.15.0 permet d'avoir des runners dans le cluster.
    ([événements](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows),
    [OIDC](https://docs.github.com/en/actions/concepts/security/openid-connect),
    [larger runners](https://docs.github.com/en/actions/concepts/runners/larger-runners),
    [ARC](https://github.blog/changelog/2026-10-01-actions-runner-controller-release-0-15-0))
- **vCluster par PR.** Il faut environ 1 CPU et 2 GiB de control plane par instance
  (profil P1). Inférence : surdimensionné pour une instance Odoo.
  ([sizing](https://www.vcluster.com/docs/vcluster/deploy/control-plane/sizing-and-performance))
- **Coûts et ménage.**
  - Mise à zéro : KEDA HTTP add-on v0.16 (bêta), Sablier v1.18.
  - Ménage : Kyverno `DeletingPolicy`, stable en v1.19.
  - kube-janitor est archivé.
  - `ResourceQuota` et `LimitRange` s'appliquent par namespace.
    ([keda http](https://github.com/kedacore/http-add-on/releases),
    [kyverno](https://kyverno.io/docs/policy-types/deleting-policy/),
    [quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/))
- **TLS.**
  - Un certificat wildcard ne s'obtient qu'en DNS-01.
  - Limites Let's Encrypt (page du 05/08/2026) : 50 certificats par domaine enregistré
    et par 7 jours ; 5 doublons par 7 jours ; 300 commandes par 3 h.
  - Inférence : un wildcard évite ces limites pour les review apps.
    ([challenges](https://letsencrypt.org/docs/challenge-types/),
    [limites](https://letsencrypt.org/docs/rate-limits/))
- **Gateway API v1.6.3.**
  - Une Gateway peut être partagée via `allowedRoutes.namespaces.from: Selector`.
  - Avec cert-manager, le Secret TLS doit être dans le namespace de la Gateway.
  - La GEP-1911 définit `appProtocol: kubernetes.io/ws`. Certaines implémentations
    demandent d'activer les websockets.
    ([multi-namespace](https://gateway-api.sigs.k8s.io/guides/multiple-ns/),
    [cert-manager](https://cert-manager.io/docs/usage/gateway/),
    [GEP-1911](https://gateway-api.sigs.k8s.io/geps/gep-1911/),
    [implémentations](https://gateway-api.sigs.k8s.io/implementations/))
- **ingress-nginx.**
  - Retrait annoncé le 11/11/2025 ; plus de correctifs après mars 2026 ; dépôt archivé
    le 24/03/2026.
  - Les mainteneurs recommandent Gateway API.
  - ingress2gateway v1.2.0 existe.
    ([annonce](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/),
    [déclaration](https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/),
    [ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway/releases))

## 4. Odoo 20 sur Kubernetes

- **Image officielle 20.0.**
  - `FROM ubuntu:noble`, deb nightly figé.
  - `ODOO_RC=/etc/odoo/odoo.conf`, ports 8069/8071/8072, `VOLUME` sur `/var/lib/odoo` et
    `/mnt/extra-addons`.
  - L'uid est attribué à l'installation (notre Dockerfile le fixe à 1000).
  - Le kubelet exige un `runAsUser` numérique pour vérifier `runAsNonRoot`.
    ([Dockerfile](https://raw.githubusercontent.com/odoo/docker/master/20.0/Dockerfile),
    [kubelet](https://raw.githubusercontent.com/kubernetes/kubernetes/master/pkg/kubelet/kuberuntime/kuberuntime_container.go))
- **Entrypoint officiel.** Il attend PostgreSQL 30 s (`wait-for-psql.py`) et n'ajoute
  pas les options `--db_*` si les variables `PG*` sont définies.
  ([entrypoint.sh](https://raw.githubusercontent.com/odoo/docker/master/20.0/entrypoint.sh))
- **Websocket.**
  - En mode threadé (`workers = 0`), il passe sur 8069.
  - En mode multi-process, `/websocket` doit aller sur `gevent_port` (8072).
  - `proxy_mode` est requis derrière un proxy.
    ([deploy 20.0](https://www.odoo.com/documentation/20.0/administration/on_premise/deploy.html),
    [server.py](https://raw.githubusercontent.com/odoo/odoo/20.0/odoo/service/server.py))
- **`/web/health`.** Il renvoie 200 `{"status":"pass"}` sans toucher la base.
  `?db_server_status=1` teste la connexion PostgreSQL et renvoie 500 en cas d'échec.
  ([home.py](https://raw.githubusercontent.com/odoo/odoo/20.0/addons/web/controllers/home.py))
- **Dimensionnement.**
  - workers = CPU × 2 + 1, environ 6 utilisateurs par worker.
  - `limit_memory_hard` correspond à `RLIMIT_AS` (mémoire virtuelle).
  - Le cron se désactive avec `max_cron_threads = 0`, et `--no-http` donne un process
    cron seul.
    ([deploy 20.0](https://www.odoo.com/documentation/20.0/administration/on_premise/deploy.html))
- **Filestore et sessions.**
  - Le filestore est dans `<data_dir>/filestore/<db>`, les sessions sont des fichiers
    JSON dans `<data_dir>/sessions`, sans verrou entre process.
  - Un volume RWO ne s'attache qu'à un nœud.
  - OCA `fs_attachment(_s3)` existe en 18.0 et 19.0 ; la branche 20.0 est « (unported)
    ».
  - Inférence : un seul replica par environnement en 20.0.
    ([OCA/storage 20.0](https://github.com/OCA/storage/tree/20.0),
    [volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/))
- **Mise à jour.**
  - CLI `odoo module install|upgrade|uninstall|force-demo` à partir de 19.0 ; `list`
    seulement en 20.0 ; `-n` pour un essai à blanc. Sinon `-u all --stop-after-init`.
  - Le process qui charge la registry prend un verrou consultatif ; les autres
    rechargent via `orm_signaling_*`.
  - Inférence : terminer la mise à jour avant le démarrage, avec une stratégie Recreate.
    ([module.py](https://raw.githubusercontent.com/odoo/odoo/20.0/odoo/cli/module.py),
    [registry.py](https://raw.githubusercontent.com/odoo/odoo/20.0/odoo/orm/registry.py))
- **click-odoo-update** (click-odoo-contrib 1.24 du 26/09/2026). Il gère Odoo 20 et ne
  met à jour que les modules dont l'empreinte a changé ; la référence est stockée dans
  `ir_config_parameter`.
  ([CHANGES](https://raw.githubusercontent.com/acsone/click-odoo-contrib/master/CHANGES.rst))
- **Sauvegardes.**
  - `odoo db dump` produit un zip avec le filestore, ou un dump avec `--format dump`.
  - `db load -n` restaure puis neutralise ; `db duplicate -n` copie et neutralise.
    ([db.py](https://raw.githubusercontent.com/odoo/odoo/20.0/odoo/cli/db.py))
- **Neutralisation.** `odoo neutralize -d DB` exécute les `data/neutralize.sql` des
  modules installés. La liste est non exhaustive.
  ([neutralize.py](https://raw.githubusercontent.com/odoo/odoo/20.0/odoo/modules/neutralize.py))
- **Démo.**
  - `--with-demo`, faux par défaut depuis 19.0.
  - La doc dit : « Do not install demo data on internet-facing servers ».
    ([config.py](https://raw.githubusercontent.com/odoo/odoo/20.0/odoo/tools/config.py))
- **Versions minimales d'Odoo 20.** PostgreSQL 16 et Python 3.12.
  ([source 20.0](https://www.odoo.com/documentation/20.0/administration/on_premise/source.html))
- **CloudNativePG.**
  - La 1.30.x (1.30.1 du 23/09/2026) gère PostgreSQL 14 à 18 et Kubernetes 1.34 à 1.36.
  - Sauvegardes via le plugin Barman Cloud ; la méthode intégrée est dépréciée depuis la
    1.26, son retrait est prévu en 1.31.
  - Rôles gérés avec `createdb` et `passwordSecret`.
    ([supported releases](https://cloudnative-pg.io/docs/devel/supported_releases),
    [backup](https://cloudnative-pg.io/docs/devel/backup/),
    [plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/))
- **Rôle Odoo dans PostgreSQL.** Il ne doit pas être superutilisateur. `CREATEDB` n'est
  utile que si Odoo crée lui-même les bases.
  ([deploy 20.0](https://www.odoo.com/documentation/20.0/administration/on_premise/deploy.html))

## 5. CD recette / prod

- **Environnements GitHub.**
  - Jusqu'à 6 reviewers requis, règles de branches et de tags.
  - Les secrets d'environnement ne sont libérés qu'une fois les règles passées.
  - Concurrence : un run en cours et un en attente par groupe.
    ([environnements](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment),
    [concurrence](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/control-the-concurrency-of-workflows-and-jobs))
- **Automatisation d'images.**
  - Argo CD Image Updater v1.3.1 : stratégies semver, newest-build, digest et
    alphabetical ; les pré-releases s'activent avec `-0`.
  - Flux ImagePolicy : filtre plus plage semver.
  - Inférence : un tri semver choisit `1.3.0-rc.*` plutôt que `1.2.1-rc.*`. Cela
    contredit la recette partagée de `docs/gitflow.md` (hotfix, cas 2).
    ([image updater](https://argocd-image-updater.readthedocs.io/en/stable/basics/update-strategies/),
    [flux](https://fluxcd.io/flux/components/image/imagepolicies/))
- **Helm 4.**
  - Disponible depuis novembre 2025 (4.3.1). `--rollback-on-failure` remplace
    `--atomic`, et le server-side apply est utilisé par défaut à l'installation.
  - Helm 3 reçoit des correctifs de sécurité jusqu'au 10/02/2027.
  - Un hook en échec fait échouer la release. ([helm](https://helm.sh/docs/overview/),
    [EOL v3](https://helm.sh/blog/helm-v3-end-of-life),
    [hooks](https://helm.sh/docs/topics/charts_hooks/))
- **Hooks côté GitOps.**
  - Argo convertit les hooks Helm pre-install et pre-upgrade en PreSync. Si un hook Argo
    est défini, les hooks Helm sont ignorés.
  - Flux `HelmRelease` : remédiation par rollback par défaut, timeout de 5 min qui
    couvre les hooks.
    ([argo helm](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/),
    [helmrelease](https://fluxcd.io/flux/components/helm/helmreleases/))
- **GHCR.** « GitHub Packages only supports authentication using a personal access token
  (classic) » (`read:packages`). Les PAT fine-grained ne couvrent pas Packages. Un jeton
  d'installation d'app expire au bout d'1 h.
  ([GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry),
  [PAT](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens))
- **Gestion des secrets.**
  - Sealed Secrets v0.40.0.
  - SOPS v3.13.3 : natif dans Flux, KSOPS côté Argo.
  - External Secrets Operator v2.12.0.
    ([sealed](https://github.com/bitnami-labs/sealed-secrets/releases),
    [sops](https://github.com/getsops/sops/releases),
    [eso](https://github.com/external-secrets/external-secrets/releases))

## 6. Plateforme (octobre 2026)

- **Kubernetes.**
  - Dernière version : 1.37.1.
  - Fins de support : 1.34 le 27/10/2026, 1.35 le 28/02/2027, 1.36 le 28/06/2027.
  - Scaleway Kapsule maintient la 1.36 jusqu'au 07/07/2027.
  - Côté auto-géré : k3s v1.37.1+k3s1, Talos v1.14.3.
    ([releases](https://kubernetes.io/releases/),
    [scaleway](https://www.scaleway.com/en/docs/kubernetes/reference-content/version-support-policy/))
- **Composants.** cert-manager v1.21.2, Gateway API v1.6.3, Velero v1.18.4,
  CloudNativePG 1.30.1.
  ([cert-manager](https://github.com/cert-manager/cert-manager/releases),
  [velero](https://github.com/vmware-tanzu/velero/releases),
  [cnpg](https://github.com/cloudnative-pg/cloudnative-pg/releases))
- **Pod Security Admission « restricted ».** Exige `runAsNonRoot`,
  `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault` et le retrait de toutes
  les capabilities.
  ([PSS](https://kubernetes.io/docs/concepts/security/pod-security-standards/))
- **NetworkPolicy.** Sans plugin réseau qui les applique, elles « will have no effect ».
  ([network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/))
- **metrics-server.** À déployer soi-même.
  ([metrics](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/))
- **Longhorn en RWX.** Un share-manager NFSv4 par volume ; les I/O sont bloquées pendant
  le basculement.
  ([longhorn rwx](https://longhorn.io/docs/latest/nodes-and-volumes/volumes/rwx-volumes/))

## 7. Vérifications complémentaires : mise à jour et retour arrière

Faites après la première synthèse, pour trancher la question de la coupure pendant la
mise à jour.

- **La mise à jour n'est pas une transaction.**
  - `load_module_graph()` committe après chaque module mis à jour :
    `module.write({'state': 'installed', 'latest_version': ver})`, puis
    `module.env.cr.commit()`.
  - En cas d'échec, `Registry.new` annule le module en cours et appelle
    `reset_modules_state()`, qui repasse « to upgrade » en « installed » et « to install
    » en « uninstalled ». Il committe ensuite.
  - Une mise à jour en échec laisse donc la base partiellement migrée.
    ([loading.py](https://github.com/odoo/odoo/blob/20.0/odoo/modules/loading.py),
    [registry.py](https://github.com/odoo/odoo/blob/20.0/odoo/orm/registry.py))
- **Installations « en ligne ».**
  - `load_modules` fixe `lock_timeout = '15s'` « during online installs » : Odoo prévoit
    qu'on installe des modules pendant que le serveur tourne, mais avec le même code.
  - Le chargement de la registry prend un verrou consultatif `registry_loading` :
    partagé sans mise à jour, exclusif pendant une mise à jour.
- **Filestore.** Chaque fichier est nommé par le SHA-1 de son contenu. Une suppression
  passe par une liste de contrôle et ne devient effective qu'au GC
  (`@api.autovacuum _gc_file_store`), après un délai de grâce.
  ([ir_attachment.py](https://github.com/odoo/odoo/blob/20.0/odoo/addons/base/models/ir_attachment.py))
- **CNPG et snapshots.**
  - Sauvegarde `method: volumeSnapshot` : à chaud par défaut (`online: true`), à froid
    avec `online: false`, auquel cas le primaire est isolé pendant le snapshot.
  - La doc recommande le froid pour une restauration par snapshot.
  - La restauration se fait dans un nouveau cluster, via
    `bootstrap.recovery.volumeSnapshots`.
  - Le CSI doit gérer les snapshots, avec une `VolumeSnapshotClass`.
    ([snapshots](https://cloudnative-pg.io/docs/devel/appendixes/backup_volumesnapshot),
    [à froid, 1.24](https://cloudnative-pg.io/documentation/1.24/backup_volumesnapshot/),
    [recovery 1.28](https://cloudnative-pg.io/docs/1.28/recovery))
- **CNPG et stockage répliqué.** Avec Longhorn ou Ceph, la doc conseille de ramener les
  réplicas au niveau stockage à 1 (pour Longhorn, data locality strict-local) : la
  résilience est assurée par les instances PostgreSQL.
  ([storage](https://cloudnative-pg.io/docs/devel/storage/))
- **Longhorn.**
  - Un `VolumeSnapshot` est de type `snap` (snapshot Longhorn) ou `bak` (sauvegarde vers
    la cible, incrémentale par défaut).
  - Restaurer, c'est créer un nouveau PVC de même taille avec un `dataSource`. Le CSI ne
    permet pas de remettre un volume en arrière sur place.
    ([Longhorn 1.9](https://longhorn.io/docs/1.9.0/snapshots-and-backups/csi-snapshot-support/csi-volume-snapshot-associated-with-longhorn-snapshot),
    [SUSE, sauvegarde CSI](https://documentation.suse.com/cloudnative/storage/1.12/en/snapshots-backups/csi-snapshots/csi-snapshot-longhorn-backup.html))

## Points clés

1. Ne pas adopter runboat. Le garder comme référence d'expérience utilisateur :
   plafonds, statut et URL dans la PR, démo et modules du dépôt, boîte mail de test,
   suppression à la fermeture.
2. Déployer depuis GitHub Actions avec un chart Helm fourni par le modèle. C'est ce qui
   respecte le pipeline : digest testé, recette « dernier rc », promotion au tag.
3. Garder le chart compatible GitOps : pas d'étape impérative, valeurs par
   environnement. Une variante Argo CD reste possible plus tard.
4. Odoo 20 : un replica, stratégie Recreate, mise à jour des modules modifiés
   (`click-odoo-update`) Odoo arrêté, point de restauration par snapshots juste avant.
   Odoo committe après chaque module : une mise à jour en échec impose une restauration.
5. Gateway API et wildcard DNS-01 pour les review apps ; ingress-nginx est exclu.

## Méthodologie

- Quatre agents de recherche en parallèle, avec WebSearch et WebFetch (les MCP firecrawl
  et exa ne sont pas configurés). Environ 370 appels d'outils au total.
- Sources primaires privilégiées : dépôts GitHub, documentations officielles, notes de
  version.
- Axes : runboat et écosystème Odoo ; outils de preview Kubernetes ; Odoo 20 sur
  Kubernetes ; CD et pré-requis de plateforme.
- Limites :
  - les pages ont été lues via un outil qui les résume : revérifier les citations
    exactes avant réutilisation ;
  - quelques pages étaient en 404 ;
  - données insuffisantes sur les IP des runners GitHub, la prise en charge par GHCR des
    jetons d'app GitHub, et l'OIDC chez Scaleway.
