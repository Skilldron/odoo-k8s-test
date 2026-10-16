#!/usr/bin/env bash
# End-to-end scenarios of the Helm chart (phase 2 of docs/plans/k8s-deployment.md) on a
# local kind cluster. Installs, for the test only, a local registry (real image digests),
# snapshot-controller, csi-driver-host-path, cert-manager, CNPG with the Barman Cloud
# plugin, the Gateway API CRDs and MinIO. This is not a reference cluster installation.
#
# Builds two variants of the prod image (dev_sample with a new field, then with a broken
# view) and runs: review install, restart, new image (reset); guards; recette first
# install, update with restore point, broken update then rollback to a new generation.
#
# Uses its own kubeconfig: the current kubectl context is never touched.
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
REGISTRY_IMAGE=registry:3.1.1
MINIO_IMAGE=cgr.dev/chainguard/minio:latest
MC_IMAGE=cgr.dev/chainguard/minio-client:latest
SNAPCLASS=e2e-retain

work="$(mktemp -d)"
export KUBECONFIG="$work/kubeconfig"
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
    # Recette prerequisites (§4): application Secret and Barman Cloud ObjectStore
    kubectl -n e2e-recette create secret generic odoo-app \
        --from-literal=admin-passwd="$(openssl rand -hex 16)" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata: {name: s3, namespace: e2e-recette}
stringData: {ACCESS_KEY_ID: e2e, ACCESS_SECRET_KEY: e2e-minio-password}
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata: {name: odoo-backups, namespace: e2e-recette}
spec:
  configuration:
    destinationPath: s3://backups/
    endpointURL: http://minio.minio:9000
    s3Credentials:
      accessKeyId: {name: s3, key: ACCESS_KEY_ID}
      secretAccessKey: {name: s3, key: ACCESS_SECRET_KEY}
EOF
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
# Deployment steps (what ci/deploy.sh will chain, §3.2)
# ---------------------------------------------------------------------------------------
helm_odoo() { # helm_odoo <ns> <release> <env> <digest> [helm args...]
    local ns="$1" release="$2" env="$3" digest="$4"
    shift 4
    helm upgrade --install "$release" deploy/chart -n "$ns" -f "deploy/values/$env.yaml" \
        --set image.repository="$repo" --set image.digest="$digest" \
        --set odoo.persistence.storageClass=csi-hostpath-sc \
        --set database.cnpg.storageClass=csi-hostpath-sc \
        --set snapshots.volumeSnapshotClass="$SNAPCLASS" "$@" >/dev/null
}

short() {
    local d="${1#sha256:}"
    echo "${d:0:12}"
}

generation_of() { # the generation=N among helm args, 1 by default
    local arg
    for arg in "$@"; do
        case "$arg" in generation=*) echo "${arg#generation=}" && return ;; esac
    done
    echo 1
}

stop_odoo() { # stop_odoo <ns> <release> <env> <digest> [helm args...]
    local ns="$1" release="$2"
    helm_odoo "$@" --set odoo.replicas=0 || return 1
    kubectl -n "$ns" wait pod --for=delete --timeout=300s \
        -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=odoo" >/dev/null 2>&1 || true
}

wait_database() { # wait_database <ns> <release> <env> [generation]
    if [ "$3" = review ]; then
        kubectl -n "$1" rollout status "deploy/$2-postgres" --timeout=300s >/dev/null
    else
        kubectl -n "$1" wait "cluster/$2-pg-${4:-1}" --for=condition=Ready --timeout=600s >/dev/null
    fi
}

run_migrate() { # run_migrate <ns> <release> <env> <digest> [helm args...] → job status
    local ns="$1" release="$2" digest="$4" job status
    job="$release-migrate-$(short "$digest")"
    helm_odoo "$@" --set odoo.replicas=0 --set jobs.migrate.run=true || return 1
    for _ in $(seq 1 240); do
        status="$(kubectl -n "$ns" get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}')"
        case "$status" in
        1/*) return 0 ;;
        */1)
            kubectl -n "$ns" logs "job/$job" --all-containers --ignore-errors --tail=20 \
                >"$work/job.log" 2>&1 || true
            return 1
            ;;
        esac
        sleep 5
    done
    return 1
}

start_odoo() { # start_odoo <ns> <release> <env> <digest> [helm args...]
    helm_odoo "$@" --set odoo.replicas=1 --wait --timeout 10m
}

deploy() { # deploy <ns> <release> <env> <digest> [helm args...]: stop, migrate, start
    stop_odoo "$@" || return 1
    wait_database "$1" "$2" "$3" "$(generation_of "$@")" || return 1
    run_migrate "$@" || return 1
    start_odoo "$@"
}

restore_point() { # restore_point <ns> <release> <generation> <name>: cold, Odoo at 0
    kubectl apply -f - >/dev/null <<EOF || return 1
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: $4, namespace: $1}
spec: {cluster: {name: $2-pg-$3}, method: volumeSnapshot, online: false}
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: {name: $4-filestore, namespace: $1}
spec:
  volumeSnapshotClassName: $SNAPCLASS
  source: {persistentVolumeClaimName: $2-odoo-data-$3}
EOF
    kubectl -n "$1" wait "backup/$4" --for=jsonpath='{.status.phase}'=completed --timeout=300s >/dev/null &&
        kubectl -n "$1" wait "volumesnapshot/$4" --for=jsonpath='{.status.readyToUse}'=true --timeout=300s >/dev/null &&
        kubectl -n "$1" wait "volumesnapshot/$4-filestore" --for=jsonpath='{.status.readyToUse}'=true --timeout=300s >/dev/null
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

# ---------------------------------------------------------------------------------------
log "Cluster $cluster, registry localhost:$reg_port"
setup_cluster
log "Test components (snapshots, CSI, cert-manager, CNPG, Barman Cloud, Gateway API, MinIO)"
install_components
log "Images"
build_images

# Review ------------------------------------------------------------------------------
ns=e2e-review
rel=pr-1
log "Review: install (Odoo at 0, migrate with db init, Odoo at 1)"
check "review : installation" deploy $ns $rel review "$DIGEST_A"
check "review : /web/health et /web/login à 200" http_ok $ns $rel
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
check "review : nouvelle image" deploy $ns $rel review "$DIGEST_B"
kubectl -n $ns wait --for=delete --timeout=120s "pvc/$rel-pgdata-$(short "$DIGEST_A")" \
    "pvc/$rel-odoo-data-$(short "$DIGEST_A")" >/dev/null 2>&1 || true
pvcs_b="$(pvc_names $ns)"
echo "    volumes: $pvcs_a-> $pvcs_b"
check "review : volumes neufs ($(short "$DIGEST_B"))" contains "$pvcs_b" "pgdata-$(short "$DIGEST_B")"
check "review : anciens volumes supprimés" not_contains "$pvcs_b" "$(short "$DIGEST_A")"
check "review : mot de passe conservé, base recréée (marqueur absent)" \
    equals "$(marker_count $ns $rel "$review_pw" e2e-marker)" 0
check "review : nouveau champ installé" equals "$(has_e2e_field $ns $rel "$review_pw")" True

log "Guards"
check "garde-fou : db init refuse une base existante (Job en échec)" \
    fails run_migrate $ns $rel review "$DIGEST_B"
check "garde-fou : message « exists, aborting » dans les logs du Job" \
    grep -q "exists, aborting" "$work/job.log"
start_odoo $ns $rel review "$DIGEST_B"
check "garde-fou : review intacte après le refus" http_ok $ns $rel
check "garde-fou : base ephemeral refusée en recette" \
    fails helm_odoo e2e-recette guard recette "$DIGEST_A" --set database.type=ephemeral
check "garde-fou : aucune release créée" equals "$(helm -n e2e-recette list -q -f '^guard$')" ""

# Recette -----------------------------------------------------------------------------
ns=e2e-recette
rel=odoo
# odoo -i on an empty database sets the admin password to "admin"
admin_pw="admin"
log "Recette: first install (CNPG, migrate on an empty database)"
check "recette : première installation" deploy $ns $rel recette "$DIGEST_A"
check "recette : /web/health et /web/login à 200" http_ok $ns $rel
rpc $ns $rel $admin_pw "call('res.partner', 'create', {'name': 'before-update'})" >/dev/null
check "recette : données saisies" equals "$(marker_count $ns $rel $admin_pw before-update)" 1

log "Recette: update with restore point"
stop_odoo $ns $rel recette "$DIGEST_A"
check "recette : point de restauration rp-1 (base à froid + filestore)" restore_point $ns $rel 1 rp-1
check "recette : mise à jour (Job migrate)" run_migrate $ns $rel recette "$DIGEST_B"
check "recette : démarrage" start_odoo $ns $rel recette "$DIGEST_B"
check "recette : nouveau champ créé par click-odoo-update" \
    equals "$(has_e2e_field $ns $rel $admin_pw)" True
check "recette : données conservées" equals "$(marker_count $ns $rel $admin_pw before-update)" 1
rpc $ns $rel $admin_pw "call('res.partner', 'create', {'name': 'after-update'})" >/dev/null

log "Recette: broken module, then rollback to generation 2"
stop_odoo $ns $rel recette "$DIGEST_B"
check "recette : point de restauration rp-2" restore_point $ns $rel 1 rp-2
check "recette : module cassé, Job migrate en échec" fails run_migrate $ns $rel recette "$DIGEST_C"
tail -3 "$work/job.log" | sed 's/^/    /'
rollback=(--set generation=2 --set restore.database=rp-2 --set restore.filestore=rp-2-filestore)
helm_odoo $ns $rel recette "$DIGEST_B" --set odoo.replicas=0 "${rollback[@]}"
check "recette : génération 2 restaurée depuis rp-2" wait_database $ns $rel recette 2
check "recette : redémarrage sur le digest précédent, sans Job" \
    start_odoo $ns $rel recette "$DIGEST_B" "${rollback[@]}"
check "recette : /web/health et /web/login à 200 après rollback" http_ok $ns $rel
check "recette : données du point de restauration" \
    equals "$(marker_count $ns $rel $admin_pw after-update)" 1
check "recette : génération 1 conservée pour analyse" \
    kubectl -n $ns get "cluster/$rel-pg-1" "pvc/$rel-odoo-data-1" -o name
check "recette : filestore créé depuis le snapshot" \
    equals "$(kubectl -n $ns get pvc $rel-odoo-data-2 -o jsonpath='{.spec.dataSource.name}')" rp-2-filestore

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
