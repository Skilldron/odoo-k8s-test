#!/usr/bin/env bash
# End-to-end scenarios of the chart and of the deployment scripts (phases 2 and 3 of
# docs/plans/k8s-deployment.md) on a local kind cluster. Installs, for the test only, a
# local registry (real image digests), snapshot-controller, csi-driver-host-path,
# cert-manager, CNPG with the Barman Cloud plugin, the Gateway API CRDs and MinIO. This is
# not a reference cluster installation. The recette database is installed apart, as an
# administrator would, with the CNPG "cluster" chart and deploy/examples.
#
# Builds two variants of the prod image (dev_sample with a new field, then with a broken
# view) and deploys them with ci/deploy.sh: review install, restart, new image (reset),
# same image again, cap; guards; recette first install (Odoo creates its database), update
# (refused without volume snapshots, then db-init taken as done), broken update with its
# restore point, the restore runbook (database from the snapshot, ci/deploy-rollback.sh),
# the next deployment with the carried state; ci/review-sweep.sh on a fake list of pull
# requests.
#
# Uses its own kubeconfig and Helm home: the current kubectl context and Helm repositories
# are never touched.
# Usage: ci/chart-e2e.sh <prod-image>
# Env: E2E_CLUSTER (odoo-e2e), E2E_REGISTRY_PORT (5001), KEEP_CLUSTER=1 to keep the
#      cluster and the registry, KIND (kind binary).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
source ci/lib.sh

image="${1:?usage: ci/chart-e2e.sh <prod-image>}"
cluster="${E2E_CLUSTER:-odoo-e2e}"
kind="${KIND:-kind}"
reg_name="$cluster-registry"
reg_port="${E2E_REGISTRY_PORT:-5001}"
repo="localhost:$reg_port/odoo-e2e"

SNAPSHOTTER_VERSION=v8.6.0
HOSTPATH_VERSION=v1.18.0
CERT_MANAGER_VERSION=v1.21.2
CNPG_VERSION=1.30.1
BARMAN_PLUGIN_VERSION=v0.15.1
GATEWAY_API_VERSION=v1.6.3
CNPG_CLUSTER_CHART_VERSION=0.9.0
REGISTRY_IMAGE=registry:3.1.1
MINIO_IMAGE=cgr.dev/chainguard/minio:latest
MC_IMAGE=cgr.dev/chainguard/minio-client:latest
SNAPCLASS=e2e-retain

work="$(mktemp -d)"
export KUBECONFIG="$work/kubeconfig"
# Helm cache, repositories and plugins of the test only, not the user's
export HELM_CACHE_HOME="$work/helm/cache" HELM_CONFIG_HOME="$work/helm/config" \
    HELM_DATA_HOME="$work/helm/data"
failures=0
results=()

cleanup() {
    if [ "${KEEP_CLUSTER:-}" = 1 ]; then
        echo "Cluster kept: export KUBECONFIG=$work/kubeconfig"
        return
    fi
    "$kind" delete cluster --name "$cluster" >/dev/null 2>&1 || true
    docker rm -f "$reg_name" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

log() { echo "--- $*"; }
check() { # check <description> <command...>
    local description="$1"
    shift
    if "$@"; then
        echo "ok   $description"
        results+=("| $description | ok |")
    else
        echo "FAIL $description" >&2
        results+=("| $description | **échec** |")
        failures=$((failures + 1))
    fi
}

# ---------------------------------------------------------------------------------------
# Cluster, registry and test components
# ---------------------------------------------------------------------------------------
setup_cluster() {
    if [ -z "$(docker ps -q -f "name=^$reg_name$")" ]; then
        docker run -d --restart=always --name "$reg_name" \
            -p "127.0.0.1:$reg_port:5000" "$REGISTRY_IMAGE" >/dev/null
    fi
    if "$kind" get clusters 2>/dev/null | grep -qx "$cluster"; then
        "$kind" get kubeconfig --name "$cluster" >"$KUBECONFIG"
    else
        cat >"$work/kind.yaml" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
        "$kind" create cluster --name "$cluster" --config "$work/kind.yaml" \
            --kubeconfig "$KUBECONFIG" --wait 120s
    fi
    for node in $("$kind" get nodes --name "$cluster"); do
        docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:$reg_port"
        printf '[host."http://%s:5000"]\n' "$reg_name" |
            docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:$reg_port/hosts.toml"
    done
    docker network connect kind "$reg_name" 2>/dev/null || true
}

install_components() {
    git clone -q --depth 1 -b "$SNAPSHOTTER_VERSION" \
        https://github.com/kubernetes-csi/external-snapshotter.git "$work/snapshotter" 2>/dev/null
    kubectl kustomize "$work/snapshotter/client/config/crd" | kubectl apply -f - >/dev/null
    kubectl -n kube-system kustomize "$work/snapshotter/deploy/kubernetes/snapshot-controller" |
        kubectl apply -f - >/dev/null
    git clone -q --depth 1 -b "$HOSTPATH_VERSION" \
        https://github.com/kubernetes-csi/csi-driver-host-path.git "$work/hostpath" 2>/dev/null
    if ! kubectl get csidriver hostpath.csi.k8s.io >/dev/null 2>&1; then
        "$work/hostpath/deploy/kubernetes-latest/deploy.sh" >/dev/null
    fi
    kubectl apply -f "$work/hostpath/examples/csi-storageclass.yaml" >/dev/null
    kubectl apply -f - >/dev/null <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata: {name: $SNAPCLASS}
driver: hostpath.csi.k8s.io
deletionPolicy: Retain
EOF
    kubectl apply --server-side -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
    kubectl apply -f \
        "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml" >/dev/null
    kubectl apply --server-side -f \
        "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$CNPG_VERSION/cnpg-$CNPG_VERSION.yaml" >/dev/null
    kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s >/dev/null
    kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s >/dev/null
    kubectl apply -f \
        "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/$BARMAN_PLUGIN_VERSION/manifest.yaml" >/dev/null
    kubectl -n cnpg-system rollout status deploy/barman-cloud --timeout=300s >/dev/null

    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: minio}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: minio, namespace: minio}
spec:
  selector: {matchLabels: {app: minio}}
  template:
    metadata: {labels: {app: minio}}
    spec:
      containers:
        - name: minio
          image: $MINIO_IMAGE
          args: [server, /data]
          env:
            - {name: MINIO_ROOT_USER, value: e2e}
            - {name: MINIO_ROOT_PASSWORD, value: e2e-minio-password}
          readinessProbe: {httpGet: {path: /minio/health/ready, port: 9000}}
          volumeMounts: [{name: data, mountPath: /data}]
      volumes: [{name: data, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: minio, namespace: minio}
spec: {selector: {app: minio}, ports: [{port: 9000}]}
EOF
    kubectl -n minio rollout status deploy/minio --timeout=300s >/dev/null
    kubectl -n minio run mc --rm -i --restart=Never --image="$MC_IMAGE" \
        --env MC_HOST_m=http://e2e:e2e-minio-password@minio:9000 -- mb -p m/backups >/dev/null 2>&1

    for ns in e2e-review e2e-recette; do
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        kubectl label --overwrite namespace "$ns" pod-security.kubernetes.io/enforce=restricted >/dev/null
    done
    # Recette prerequisites (§4): application Secret, S3 credentials of the database
    kubectl -n e2e-recette create secret generic odoo-app \
        --from-literal=admin-passwd="$(openssl rand -hex 16)" \
        --from-literal=admin-user-password="$(openssl rand -hex 16)" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n e2e-recette create secret generic odoo-db-s3 \
        --from-literal=ACCESS_KEY_ID=e2e --from-literal=ACCESS_SECRET_KEY=e2e-minio-password \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# The database of the recette, installed apart with the CNPG cluster chart (an
# administrator's task); extra helm args select a recovery (runbook)
install_database() { # install_database <ns> <release> [helm args...]
    local ns="$1" release="$2"
    shift 2
    helm upgrade --install "$release" cluster --repo https://cloudnative-pg.github.io/charts \
        --version "$CNPG_CLUSTER_CHART_VERSION" -n "$ns" \
        -f deploy/examples/cnpg-cluster.values.yaml \
        --set fullnameOverride="$release" --set cluster.storage.size=2Gi \
        --set cluster.storage.storageClass=csi-hostpath-sc \
        --set backups.endpointURL=http://minio.minio:9000 \
        --set backups.destinationPath="s3://backups/$ns/" \
        --set backups.wal.encryption= --set backups.data.encryption= "$@" >/dev/null ||
        return 1
    kubectl -n "$ns" wait "cluster/$release" --for=condition=Ready --timeout=600s >/dev/null &&
        kubectl -n "$ns" wait "cluster/$release" --for=condition=ContinuousArchiving \
            --timeout=300s >/dev/null
}

# ---------------------------------------------------------------------------------------
# Images: A = the prod image, B = dev_sample with a new field, C = B with a broken view
# ---------------------------------------------------------------------------------------
push() { # push <tag> → prints the digest
    docker push -q "$repo:$1" >/dev/null
    docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$repo:$1" |
        grep "^$repo@" | head -1 | sed 's/.*@//'
}

build_images() {
    docker tag "$image" "$repo:a"
    mkdir -p "$work/b" "$work/c"
    cp -R addons/dev_sample "$work/b/dev_sample"
    perl -pi -e 's/^(    done = fields\.Boolean\(\)\n)/$1    e2e_field = fields.Char()\n/' \
        "$work/b/dev_sample/models/dev_sample_note.py"
    grep -q e2e_field "$work/b/dev_sample/models/dev_sample_note.py"
    cp -R "$work/b/dev_sample" "$work/c/dev_sample"
    perl -0pi -e 's/(<field name="done" \/>)/$1<field name="e2e_missing" \/>/' \
        "$work/c/dev_sample/views/dev_sample_note_views.xml"
    grep -q e2e_missing "$work/c/dev_sample/views/dev_sample_note_views.xml"
    for variant in b c; do
        printf 'FROM %s\nCOPY --chown=odoo:odoo dev_sample /opt/odoo/addons/dev_sample\n' \
            "$repo:a" >"$work/$variant/Dockerfile"
        docker build -q -t "$repo:$variant" "$work/$variant" >/dev/null
    done
    DIGEST_A="$(push a)"
    DIGEST_B="$(push b)"
    DIGEST_C="$(push c)"
    echo "A=$DIGEST_A"
    echo "B=$DIGEST_B"
    echo "C=$DIGEST_C"
}

# ---------------------------------------------------------------------------------------
# Deployments through the scripts of the CI; $ns and $rel name the target
# ---------------------------------------------------------------------------------------
short() {
    local d="${1#sha256:}"
    echo "${d:0:12}"
}

ci_env() { # ci_env <command...>: a CI script with the test settings; its log in
    # $work/ci.log, its outputs in $work/ci.out, its job summary in $work/ci.md
    : >"$work/ci.out"
    : >"$work/ci.md"
    env NAMESPACE="$ns" PR_NUMBER="${rel#pr-}" SMOKE=none EXTRA_VALUES="$work/kind-values.yaml" \
        REVIEW_MAX_APPS="${REVIEW_MAX_APPS:-5}" GITHUB_OUTPUT="$work/ci.out" \
        GITHUB_STEP_SUMMARY="$work/ci.md" "$@" >"$work/ci.log" 2>&1 && return 0
    tail -4 "$work/ci.log" | sed 's/^/    /' >&2
    return 1
}
deploy() { ci_env ci/deploy.sh "$1" "$repo@$2"; } # deploy <env> <digest>
ci_output() { sed -n "s/^$1=//p" "$work/ci.out" | tail -1; }
in_log() { grep -q "$1" "$work/ci.log"; }

helm_raw() { # helm_raw <release> <env> <digest> [helm args...]: the chart without the
    # scripts, to simulate a mistake (guards)
    helm upgrade --install "$1" deploy/chart -n "$ns" -f "deploy/values/$2.yaml" \
        -f "$work/kind-values.yaml" --set image.repository="$repo" --set image.digest="$3" \
        "${@:4}" >/dev/null
}

job_fails() { # job_fails <job>: the Job ends in failure, its logs in $work/job.log
    local status
    for _ in $(seq 1 120); do
        status="$(kubectl -n "$ns" get job "$1" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)"
        case "$status" in
        1/*) return 1 ;;
        */1)
            kubectl -n "$ns" logs "job/$1" --all-containers --ignore-errors --tail=20 >"$work/job.log" 2>&1 || true
            return 0
            ;;
        esac
        sleep 5
    done
    return 1
}

replicas() { kubectl -n "$ns" get deploy "$rel" -o jsonpath='{.spec.replicas}'; }

enable_snapshots() { # enable_snapshots <cluster>: the administrator's patch after every
    # install or recovery of the database (the CNPG cluster chart cannot set this section)
    kubectl -n "$ns" patch "cluster/$1" --type merge -p \
        "{\"spec\":{\"backup\":{\"volumeSnapshot\":{\"className\":\"$SNAPCLASS\",\"online\":false}}}}" >/dev/null
}

snapshots_enabled() { # snapshots_enabled <cluster>
    [ -n "$(kubectl -n "$ns" get "cluster/$1" -o jsonpath='{.spec.backup.volumeSnapshot.className}')" ]
}

archive_current_wal() { # archive_current_wal <ns> <cluster>: closes the current WAL segment
    # and waits until it is archived (Barman continuous archiving works)
    local segment
    segment="$(kubectl -n "$1" exec "$2-1" -c postgres -- psql -U postgres -tAc \
        "select pg_walfile_name(pg_switch_wal())")" || return 1
    for _ in $(seq 1 60); do
        kubectl -n "$1" exec "$2-1" -c postgres -- psql -U postgres -tAc \
            "select last_archived_wal >= '$segment' from pg_stat_archiver" | grep -q t && return 0
        sleep 5
    done
    return 1
}

# ---------------------------------------------------------------------------------------
# Checks, run inside the Odoo pod
# ---------------------------------------------------------------------------------------
http_ok() { # http_ok <ns> <release>: /web/health and /web/login answer 200
    local path code
    for path in /web/health /web/login; do
        code="$(kubectl -n "$1" exec "deploy/$2" -c odoo -- \
            curl -fsS -o /dev/null -w '%{http_code}' "http://localhost:8069$path" 2>/dev/null || true)"
        [ "$code" = 200 ] || return 1
    done
}

rpc() { # rpc <ns> <release> <admin password> <python using call()> → prints the result
    kubectl -n "$1" exec -i "deploy/$2" -c odoo -- python3 - "$3" <<EOF
import os, sys, xmlrpc.client
pw, db = sys.argv[1], os.environ["PGDATABASE"]
common = xmlrpc.client.ServerProxy("http://localhost:8069/xmlrpc/2/common")
uid = common.authenticate(db, "admin", pw, {})
assert uid, "admin login refused"
models = xmlrpc.client.ServerProxy("http://localhost:8069/xmlrpc/2/object")
def call(model, method, *args, **kw):
    return models.execute_kw(db, uid, pw, model, method, list(args), kw)
print($4)
EOF
}

secret_value() { # secret_value <ns> <secret> <key>
    kubectl -n "$1" get secret "$2" -o go-template="{{index .data \"$3\" | base64decode}}"
}

only_password() { # only_password <ns> <release> <password>: admin logs in with it, not
    # with "admin"
    rpc "$1" "$2" "$3" "1" >/dev/null && ! rpc "$1" "$2" admin "1" >/dev/null 2>&1
}
marker_count() { # marker_count <ns> <release> <password> <name>
    rpc "$1" "$2" "$3" "call('res.partner', 'search_count', [('name', '=', '$4')])"
}

has_e2e_field() { # has_e2e_field <ns> <release> <password> → True/False
    rpc "$1" "$2" "$3" "'e2e_field' in call('dev.sample.note', 'fields_get')"
}

pvc_names() { kubectl -n "$1" get pvc -o name | sort | tr '\n' ' '; }
equals() { [ "$1" = "$2" ]; }
contains() { [[ "$1" == *"$2"* ]]; }
not_contains() { [[ "$1" != *"$2"* ]]; }
fails() { ! "$@"; }
exists() { kubectl -n "$1" get "${@:2}" -o name >/dev/null; } # exists <ns> <resource...>

# ---------------------------------------------------------------------------------------
log "Cluster $cluster, registry localhost:$reg_port"
setup_cluster
log "Test components (snapshots, CSI, cert-manager, CNPG, Barman Cloud, Gateway API, MinIO)"
install_components
log "Images"
build_images

cat >"$work/kind-values.yaml" <<EOF
odoo: {persistence: {storageClass: csi-hostpath-sc}}
snapshots: {volumeSnapshotClass: $SNAPCLASS}
EOF

# Review ------------------------------------------------------------------------------
ns=e2e-review
rel=pr-1
log "Review: install (ci/deploy.sh: Odoo at 0, migrate with db init, Odoo at 1)"
check "review : installation" deploy review "$DIGEST_A"
check "review : /web/health et /web/login à 200" http_ok $ns $rel
# shellcheck disable=SC2016 # Markdown backticks
check "review : identifiants dans le résumé du job" grep -qF 'Connexion : `admin`' "$work/ci.md"
review_pw="$(secret_value $ns $rel-secrets review-admin-password)"
rpc $ns $rel "$review_pw" "call('res.partner', 'create', {'name': 'e2e-marker'})" >/dev/null
check "review : connexion admin avec le mot de passe généré" \
    equals "$(marker_count $ns $rel "$review_pw" e2e-marker)" 1
check "review : base de démo (partenaires de démo présents)" \
    test "$(rpc $ns $rel "$review_pw" "call('res.partner', 'search_count', [])")" -gt 10

log "Review: restart of the pod"
kubectl -n $ns delete pod -l "app.kubernetes.io/instance=$rel,app.kubernetes.io/component=odoo" >/dev/null
kubectl -n $ns rollout status deploy/$rel --timeout=300s >/dev/null
check "review : redémarrage, aucun Job" equals "$(kubectl -n $ns get jobs -o name)" ""
check "review : redémarrage, données conservées" \
    equals "$(marker_count $ns $rel "$review_pw" e2e-marker)" 1

log "Review: new image (new volumes, demo database recreated)"
pvcs_a="$(pvc_names $ns)"
check "review : nouvelle image" deploy review "$DIGEST_B"
kubectl -n $ns wait --for=delete --timeout=120s "pvc/$rel-pgdata-$(short "$DIGEST_A")" \
    "pvc/$rel-odoo-data-$(short "$DIGEST_A")" >/dev/null 2>&1 || true
pvcs_b="$(pvc_names $ns)"
echo "    volumes: $pvcs_a-> $pvcs_b"
check "review : volumes neufs ($(short "$DIGEST_B"))" contains "$pvcs_b" "pgdata-$(short "$DIGEST_B")"
check "review : anciens volumes supprimés" not_contains "$pvcs_b" "$(short "$DIGEST_A")"
check "review : mot de passe conservé, base recréée (marqueur absent)" \
    equals "$(marker_count $ns $rel "$review_pw" e2e-marker)" 0
check "review : nouveau champ installé" equals "$(has_e2e_field $ns $rel "$review_pw")" True

log "Review: same image again (workflow re-run)"
rpc $ns $rel "$review_pw" "call('res.partner', 'create', {'name': 'e2e-rerun'})" >/dev/null
check "review : même image redéployée" deploy review "$DIGEST_B"
check "review : même image, aucun Job ni remise à zéro" in_log "Image already deployed"
check "review : même image, données conservées" \
    equals "$(marker_count $ns $rel "$review_pw" e2e-rerun)" 1

log "Review: cap of the review apps"
rel=pr-2
REVIEW_MAX_APPS=1
check "review : plafond atteint, nouvelle review app refusée" fails deploy review "$DIGEST_A"
check "review : message du plafond" in_log "cap of 1 review apps reached"
check "review : aucune release pr-2" equals "$(helm -n $ns list -q -f '^pr-2$')" ""
unset REVIEW_MAX_APPS
rel=pr-1

log "Guards"
helm_raw $rel review "$DIGEST_B" --set odoo.replicas=0 --set jobs.migrate.run=true
check "garde-fou : db init refuse une base existante (Job en échec)" \
    job_fails "$rel-migrate-$(short "$DIGEST_B")"
check "garde-fou : message « exists, aborting » dans les logs du Job" \
    grep -q "exists, aborting" "$work/job.log"
helm_raw $rel review "$DIGEST_B" --set odoo.replicas=1 --wait --timeout 10m
check "garde-fou : review intacte après le refus" http_ok $ns $rel
ns=e2e-recette
check "garde-fou : base ephemeral refusée en recette" \
    fails helm_raw guard recette "$DIGEST_A" --set database.type=ephemeral
check "garde-fou : aucune release créée" equals "$(helm -n $ns list -q -f '^guard$')" ""

# Recette -----------------------------------------------------------------------------
ns=e2e-recette
rel=odoo
# Admin password of the first deployment (odoo db init), from the application Secret
admin_pw="$(secret_value $ns odoo-app admin-user-password)"
log "Recette: database installed apart (CNPG cluster chart), NetworkPolicy example"
check "recette : base installée avec le chart CNPG officiel" install_database $ns odoo-db
check "recette : rôle odoo avec CREATEDB (postInitSQL)" \
    equals "$(kubectl -n $ns exec odoo-db-1 -c postgres -- psql -tAc \
        "select rolcreatedb from pg_roles where rolname = 'odoo'")" t
kubectl -n $ns apply -f deploy/examples/database-networkpolicy.yaml >/dev/null

log "Recette: deployment refused while the database has no volume snapshots"
check "garde-fou : base sans section volumeSnapshot, déploiement refusé" \
    fails deploy recette "$DIGEST_A"
check "garde-fou : message du contrôle préalable" in_log "has no spec.backup.volumeSnapshot"
check "garde-fou : rien déployé" equals "$(helm -n $ns list -q -f '^odoo$')" ""
check "recette : patch volumeSnapshot de la base (administrateur)" enable_snapshots odoo-db
check "recette : helm upgrade de la base" install_database $ns odoo-db --set backups.retentionPolicy=31d
check "recette : patch conservé par helm upgrade" snapshots_enabled odoo-db

log "Recette: first install (Odoo creates its database with the admin password of the Secret)"
check "recette : première installation (Job db-init, puis migrate)" deploy recette "$DIGEST_A"
check "recette : base créée par le Job db-init" in_log "database created"
check "recette : pas de point de restauration au premier déploiement" equals "$(ci_output restore_point)" ""
check "recette : /web/health et /web/login à 200" http_ok $ns $rel
check "recette : admin/admin refusé, mot de passe du Secret accepté" only_password $ns $rel "$admin_pw"
check "recette : base sans démo" \
    test "$(rpc $ns $rel "$admin_pw" "call('res.partner', 'search_count', [])")" -lt 10
rpc $ns $rel "$admin_pw" "call('res.partner', 'create', {'name': 'before-update'})" >/dev/null
check "recette : données saisies" equals "$(marker_count $ns $rel "$admin_pw" before-update)" 1

log "Recette: update, after a first deployment interrupted once its database was created"
helm upgrade $rel deploy/chart -n $ns --reuse-values --set state.initialized=false >/dev/null
check "recette : mise à jour" deploy recette "$DIGEST_B"
check "recette : db-init relancé, base existante acceptée" \
    in_log "database already created by a previous attempt"
check "recette : nouveau champ créé par click-odoo-update" \
    equals "$(has_e2e_field $ns $rel "$admin_pw")" True
check "recette : données conservées" equals "$(marker_count $ns $rel "$admin_pw" before-update)" 1
rpc $ns $rel "$admin_pw" "call('res.partner', 'create', {'name': 'after-update'})" >/dev/null

log "Recette: broken module, Odoo stays stopped"
check "recette : module cassé, déploiement en échec" fails deploy recette "$DIGEST_C"
rp="$(ci_output restore_point)"
echo "    restore point: $rp"
check "recette : point de restauration (snapshots à froid de la base et du filestore)" \
    exists $ns "backup/$rp" "volumesnapshot/$rp-filestore"
check "recette : message du Job migrate en échec" in_log "migrate Job failed"
check "recette : logs du Job (vue cassée) dans le résumé du job" grep -q e2e_missing "$work/ci.md"
check "recette : Odoo reste arrêté" equals "$(replicas)" 0
check "recette : runbook dans le résumé du job" \
    grep -q "ci/deploy-rollback.sh recette $rp odoo-db-2-app odoo-db-2" "$work/ci.md"
# A write after the restore point, which the restoration must not bring back
kubectl -n $ns exec odoo-db-1 -c postgres -- psql -d odoo -qc \
    "create table e2e_after_restore_point (id int)"

log "Recette: restore runbook (database odoo-db-2 from the restore point, ci/deploy-rollback.sh)"
check "runbook : base odoo-db-2 restaurée depuis le point" \
    install_database $ns odoo-db-2 -f deploy/examples/cnpg-cluster-recovery.values.yaml \
    --set recovery.backupName="$rp"
check "runbook : volume de odoo-db-2 créé depuis le snapshot" \
    equals "$(kubectl -n $ns get pvc odoo-db-2-1 -o jsonpath='{.spec.dataSource.name}')" "$rp"
check "runbook : rollback refusé tant que odoo-db-2 n'a pas le patch" \
    fails ci_env ci/deploy-rollback.sh recette "$rp" odoo-db-2-app odoo-db-2
check "runbook : patch volumeSnapshot de odoo-db-2" enable_snapshots odoo-db-2
check "runbook : ci/deploy-rollback.sh" ci_env ci/deploy-rollback.sh recette "$rp" odoo-db-2-app odoo-db-2
check "runbook : image d'avant le point de restauration" \
    equals "$(helm get values $rel -n $ns -o json | jq -r .image.digest)" "$DIGEST_B"
check "runbook : /web/health et /web/login à 200" http_ok $ns $rel
check "runbook : données du point de restauration présentes" \
    equals "$(marker_count $ns $rel "$admin_pw" after-update)" 1
check "runbook : écriture postérieure au point de restauration absente" \
    equals "$(kubectl -n $ns exec odoo-db-2-1 -c postgres -- psql -d odoo -tAc \
        "select to_regclass('e2e_after_restore_point') is null")" t
check "runbook : base en échec et ancien filestore conservés" \
    exists $ns cluster/odoo-db pvc/$rel-odoo-data-1
check "runbook : filestore génération 2 créé depuis le snapshot" \
    equals "$(kubectl -n $ns get pvc $rel-odoo-data-2 -o jsonpath='{.spec.dataSource.name}')" "$rp-filestore"
check "runbook : archivage des WAL de odoo-db-2" archive_current_wal $ns odoo-db-2

log "Recette: next deployment after the restoration (state carried over)"
check "recette : déploiement suivant" deploy recette "$DIGEST_B"
check "recette : état reporté (génération 2, base odoo-db-2)" \
    equals "$(helm get values $rel -n $ns -o json | jq -r '"\(.state.generation) \(.state.databaseSecret)"')" "2 odoo-db-2-app"
check "recette : Odoo sur le filestore génération 2 et la base restaurée" \
    equals "$(kubectl -n $ns get deploy $rel -o json | jq -r '.spec.template.spec |
        [(.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName),
         (.containers[0].env[] | select(.name == "PGHOST") | .valueFrom.secretKeyRef.name)] |
        join(" ")')" "$rel-odoo-data-2 odoo-db-2-app"

# Review apps sweep --------------------------------------------------------------------
ns=e2e-review
rel=pr-1
log "Review apps sweep (fake list of pull requests)"
echo "1 open" >"$work/prs"
check "sweep : PR ouverte, review app gardée" ci_env env PR_STATES_FILE="$work/prs" ci/review-sweep.sh
check "sweep : pr-1 toujours là" exists $ns deploy/pr-1
echo "1 closed" >"$work/prs"
check "sweep : DRY_RUN, rien supprimé" \
    ci_env env PR_STATES_FILE="$work/prs" DRY_RUN=true ci/review-sweep.sh
check "sweep : pr-1 toujours là après DRY_RUN" exists $ns deploy/pr-1
check "sweep : PR fermée, review app supprimée" ci_env env PR_STATES_FILE="$work/prs" ci/review-sweep.sh
check "sweep : release et volumes supprimés" \
    equals "$(helm -n $ns list -q -f '^pr-1$')/$(kubectl -n $ns get pvc -o name)" "/"
check "review-remove : review app absente, rien à faire" ci_env ci/review-remove.sh 1

{
    echo "### Chart Helm, scénarios e2e (kind)"
    echo
    echo "| Scénario | Résultat |"
    echo "| --- | --- |"
    printf '%s\n' "${results[@]}"
} | ci_summary
if [ "$failures" -gt 0 ]; then
    echo "chart-e2e: $failures check(s) FAILED" >&2
    exit 1
fi
echo "chart-e2e: all scenarios passed."
