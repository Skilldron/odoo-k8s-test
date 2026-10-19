#!/usr/bin/env bash
# End-to-end scenarios of the chart and of the deployment scripts (phases 2, 3 and 3 bis of
# docs/plans/k8s-deployment.md) on a local kind cluster. Installs, for the test only, a
# local registry (real image digests), snapshot-controller, csi-driver-host-path,
# cert-manager, CNPG with the Barman Cloud plugin, the Gateway API CRDs and MinIO. This is
# not a reference cluster installation. The recette database is installed apart, as an
# administrator would, with the CNPG "cluster" chart and deploy/examples (declared role,
# stable Service, volumeSnapshot patch).
#
# Builds three variants of the prod image (dev_sample with a new field, the same with a
# broken view, a fix) and deploys them with ci/deploy.sh and ci/deploy-restore.sh: review
# install, restart, new image (reset), same image again, cap; guards; recette first
# installation, update with its restore point, broken update and automatic restoration,
# retry after a failure, retention, failed snapshots, orphan restore point, filestore
# without PVC; ci/review-sweep.sh on a fake list of pull requests. Failures are injected
# with helm upgrade run by hand, as an operator could.
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
SNAPCLASS=e2e-delete
PREFIX=odoo.haroldd.dev

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
deletionPolicy: Delete
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata: {name: e2e-retain}
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

    # Fresh namespaces and bucket at every run (a kept cluster holds the previous run)
    kubectl delete namespace e2e-review e2e-recette trial --ignore-not-found --wait \
        --timeout=600s >/dev/null
    kubectl -n minio run mc --rm -i --restart=Never --image="$MC_IMAGE" \
        --env MC_HOST_m=http://e2e:e2e-minio-password@minio:9000 -- \
        rb --force m/backups >/dev/null 2>&1 || true
    kubectl -n minio run mc --rm -i --restart=Never --image="$MC_IMAGE" \
        --env MC_HOST_m=http://e2e:e2e-minio-password@minio:9000 -- mb -p m/backups >/dev/null 2>&1
    for ns in e2e-review e2e-recette; do
        kubectl create namespace "$ns" >/dev/null
        kubectl label --overwrite namespace "$ns" pod-security.kubernetes.io/enforce=restricted >/dev/null
    done
    # Recette prerequisites (§4): application Secret, credentials of the declared role
    # odoo, S3 credentials of the database, stable Service
    kubectl -n e2e-recette create secret generic odoo-app \
        --from-literal=admin-passwd="$(openssl rand -hex 16)" \
        --from-literal=admin-user-password="$(openssl rand -hex 16)" >/dev/null
    deploy/examples/database-credentials.example.sh e2e-recette >/dev/null
    kubectl -n e2e-recette create secret generic odoo-db-s3 \
        --from-literal=ACCESS_KEY_ID=e2e --from-literal=ACCESS_SECRET_KEY=e2e-minio-password >/dev/null
    kubectl -n e2e-recette apply -f deploy/examples/database-service.yaml >/dev/null
}

# The database of the recette, installed apart with the CNPG cluster chart (an
# administrator's task)
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
# Images: A = the prod image, B = dev_sample with a new field, C = B with a broken view,
# D = B with another field (the fix of C)
# ---------------------------------------------------------------------------------------
push() { # push <tag> → prints the digest
    docker push -q "$repo:$1" >/dev/null
    docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$repo:$1" |
        grep "^$repo@" | head -1 | sed 's/.*@//'
}

build_images() {
    docker tag "$image" "$repo:a"
    mkdir -p "$work/b" "$work/c" "$work/d"
    cp -R addons/dev_sample "$work/b/dev_sample"
    perl -pi -e 's/^(    done = fields\.Boolean\(\)\n)/$1    e2e_field = fields.Char()\n/' \
        "$work/b/dev_sample/models/dev_sample_note.py"
    grep -q e2e_field "$work/b/dev_sample/models/dev_sample_note.py"
    cp -R "$work/b/dev_sample" "$work/c/dev_sample"
    perl -0pi -e 's/(<field name="done" \/>)/$1<field name="e2e_missing" \/>/' \
        "$work/c/dev_sample/views/dev_sample_note_views.xml"
    grep -q e2e_missing "$work/c/dev_sample/views/dev_sample_note_views.xml"
    cp -R "$work/b/dev_sample" "$work/d/dev_sample"
    perl -pi -e 's/^(    e2e_field = fields\.Char\(\)\n)/$1    e2e_fix = fields.Char()\n/' \
        "$work/d/dev_sample/models/dev_sample_note.py"
    grep -q e2e_fix "$work/d/dev_sample/models/dev_sample_note.py"
    for variant in b c d; do
        printf 'FROM %s\nCOPY --chown=odoo:odoo dev_sample /opt/odoo/addons/dev_sample\n' \
            "$repo:a" >"$work/$variant/Dockerfile"
        docker build -q -t "$repo:$variant" "$work/$variant" >/dev/null
    done
    DIGEST_A="$(push a)"
    DIGEST_B="$(push b)"
    DIGEST_C="$(push c)"
    DIGEST_D="$(push d)"
    echo "A=$DIGEST_A"
    echo "B=$DIGEST_B"
    echo "C=$DIGEST_C"
    echo "D=$DIGEST_D"
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
        REVIEW_MAX_APPS="${REVIEW_MAX_APPS:-5}" DEPLOY_TIMEOUT=20m GITHUB_OUTPUT="$work/ci.out" \
        GITHUB_STEP_SUMMARY="$work/ci.md" "$@" >"$work/ci.log" 2>&1 && return 0
    tail -4 "$work/ci.log" | sed 's/^/    /' >&2
    return 1
}
deploy() { ci_env ci/deploy.sh "$1" "$repo@$2"; } # deploy <env> <digest>
restore() { ci_env ci/deploy-restore.sh recette "$@"; } # restore [point]: the restore job
ci_output() { sed -n "s/^$1=//p" "$work/ci.out" | tail -1; }
in_log() { grep -q -- "$1" "$work/ci.log"; }

helm_raw() { # helm_raw <release> <env> <digest> [helm args...]: the chart without the
    # scripts, as an operator could run it (guards, injected failures); output in
    # $work/helm.log
    helm upgrade --install "$1" deploy/chart -n "$ns" -f "deploy/values/$2.yaml" \
        -f "$work/kind-values.yaml" --set image.repository="$repo" --set image.digest="$3" \
        --timeout 20m "${@:4}" >"$work/helm.log" 2>&1
}

replicas() { kubectl -n "$ns" get deploy "$rel" -o jsonpath='{.spec.replicas}'; }
revision() { helm status "$rel" -n "$ns" -o json | jq -r .version; }
job_uid() { kubectl -n "$ns" get job "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null; }
job_log_has() { # job_log_has <job> <container> <text>
    kubectl -n "$ns" logs "job/$1" -c "$2" 2>&1 | grep -q -- "$3"
}

enable_snapshots() { # enable_snapshots <cluster> [class]: the administrator's patch after
    # every install of the database (the CNPG cluster chart cannot set this section)
    kubectl -n "$ns" patch "cluster/$1" --type merge -p \
        "{\"spec\":{\"backup\":{\"volumeSnapshot\":{\"className\":\"${2:-$SNAPCLASS}\",\"online\":false,\"snapshotOwnerReference\":\"backup\"}}}}" >/dev/null
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

# Restore points: CNPG Backups labelled by the chart
state_of() { # state_of <backup> → its upgrade-state, empty when absent
    kubectl -n "$ns" get backups.postgresql.cnpg.io "$1" \
        -o jsonpath="{.metadata.labels.${PREFIX//./\\.}/upgrade-state}" 2>/dev/null || true
}
points_in() { # points_in <states> → names, oldest first
    kubectl -n "$ns" get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp \
        -l "app.kubernetes.io/instance=$rel,$PREFIX/backup-type=pre-upgrade,$PREFIX/upgrade-state in ($1)" \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'
}
point_count() { points_in "$1" | wc -w | tr -d ' '; }
snapshots_of() { # snapshots_of <backup> → its VolumeSnapshots (database, filestore)
    kubectl -n "$ns" get volumesnapshots -o json | jq -r --arg b "$1" '.items[] |
        select(.metadata.labels["cnpg.io/backupName"] == $b or .metadata.name == "\($b)-filestore") |
        .metadata.name'
}
gone() { # gone <backup>: the Backup and its snapshots are deleted (garbage collection)
    for _ in $(seq 1 60); do
        if ! kubectl -n "$ns" get backups.postgresql.cnpg.io "$1" >/dev/null 2>&1 &&
            [ -z "$(snapshots_of "$1")" ]; then
            return 0
        fi
        sleep 5
    done
    return 1
}
contents_gone() { # contents_gone <backup>: the storage snapshots are deleted too
    for _ in $(seq 1 60); do
        [ "$(kubectl get volumesnapshotcontents -o json | jq --arg b "$1" '[.items[] |
            select(.spec.volumeSnapshotRef.name | startswith($b))] | length')" = 0 ] && return 0
        sleep 5
    done
    return 1
}
hook_of_job() { kubectl -n "$ns" get job "$1" -o jsonpath='{.metadata.annotations.helm\.sh/hook}'; }
filestore_owned() { # filestore_owned <backup>: the filestore snapshot is owned by its Backup
    # (its UID), without blockOwnerDeletion
    [ "$(kubectl -n "$ns" get volumesnapshot "$1-filestore" -o json | jq -r '.metadata.ownerReferences[0] |
        "\(.kind)/\(.name)/\(.uid)/\(.blockOwnerDeletion // "unset")"')" = \
        "Backup/$1/$(kubectl -n "$ns" get backups.postgresql.cnpg.io "$1" -o jsonpath='{.metadata.uid}')/unset" ]
}
service_cluster() { kubectl -n "$ns" get service odoo-db -o jsonpath='{.spec.selector.cnpg\.io/cluster}'; }
psql_in() { # psql_in <cluster> <sql>: on its primary, database odoo
    kubectl -n "$ns" exec "$(kubectl -n "$ns" get pod -o name \
        -l "cnpg.io/cluster=$1,cnpg.io/instanceRole=primary")" -c postgres -- psql -d odoo -tAc "$2"
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
has_field() { # has_field <ns> <release> <password> <field> → True/False
    rpc "$1" "$2" "$3" "'$4' in call('dev.sample.note', 'fields_get')"
}

pvc_names() { kubectl -n "$1" get pvc -o name | sort | tr '\n' ' '; }
equals() { [ "$1" = "$2" ]; }
contains() { [[ "$1" == *"$2"* ]]; }
not_contains() { [[ "$1" != *"$2"* ]]; }
fails() { ! "$@"; }
exists() { kubectl -n "$1" get "${@:2}" -o name >/dev/null; } # exists <ns> <resource...>
waited_for_db() { # waited_for_db <ns> <release>: the Odoo pod waited in wait-db
    kubectl -n "$1" logs "deploy/$2" -c wait-db 2>/dev/null | grep -q "waiting for the database"
}

# ---------------------------------------------------------------------------------------
log "Cluster $cluster, registry localhost:$reg_port"
setup_cluster
log "Test components (snapshots, CSI, cert-manager, CNPG, Barman Cloud, Gateway API, MinIO)"
install_components
log "Images"
build_images

cat >"$work/kind-values.yaml" <<EOF
odoo: {persistence: {storageClass: csi-hostpath-sc}}
restorePoints: {volumeSnapshotClass: $SNAPCLASS}
EOF

# Review ------------------------------------------------------------------------------
ns=e2e-review
rel=pr-1
log "Review: install (migrate Job in post-install, Odoo waits for its database)"
check "review : installation" deploy review "$DIGEST_A"
check "review : pod Odoo en attente de la base (wait-db)" waited_for_db $ns $rel
check "review : /web/health et /web/login à 200" http_ok $ns $rel
# shellcheck disable=SC2016 # Markdown backticks
check "review : identifiants dans le résumé du job" grep -qF 'Connexion : `admin`' "$work/ci.md"
review_pw="$(secret_value $ns $rel-secrets review-admin-password)"
rpc $ns $rel "$review_pw" "call('res.partner', 'create', {'name': 'e2e-marker'})" >/dev/null
check "review : connexion admin avec le mot de passe généré" \
    equals "$(marker_count $ns $rel "$review_pw" e2e-marker)" 1
check "review : base de démo (partenaires de démo présents)" \
    test "$(rpc $ns $rel "$review_pw" "call('res.partner', 'search_count', [])")" -gt 10
check "review : aucun compte ni Job de point de restauration" \
    equals "$(kubectl -n $ns get serviceaccount,job -o name | grep -cE 'hooks|stop-snapshot|validate')" 0

log "Review: restart of the pod"
migrate_uid="$(job_uid $rel-migrate)"
kubectl -n $ns delete pod -l "app.kubernetes.io/instance=$rel,app.kubernetes.io/component=odoo" >/dev/null
kubectl -n $ns rollout status deploy/$rel --timeout=300s >/dev/null
check "review : redémarrage, aucun nouveau Job" equals "$(job_uid $rel-migrate)" "$migrate_uid"
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
check "review : nouveau pod en attente de la base (wait-db)" waited_for_db $ns $rel
check "review : mot de passe conservé, base recréée (marqueur absent)" \
    equals "$(marker_count $ns $rel "$review_pw" e2e-marker)" 0
check "review : nouveau champ installé" equals "$(has_field $ns $rel "$review_pw" e2e_field)" True

log "Review: same image again (workflow re-run)"
rpc $ns $rel "$review_pw" "call('res.partner', 'create', {'name': 'e2e-rerun'})" >/dev/null
migrate_uid="$(job_uid $rel-migrate)"
check "review : même image redéployée" deploy review "$DIGEST_B"
check "review : même image, rien à faire" in_log "Image already deployed"
check "review : même image, aucun Job relancé" equals "$(job_uid $rel-migrate)" "$migrate_uid"
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
# shellcheck disable=SC2016 # $PGDATABASE is expanded in the pod
check "garde-fou : odoo db init refuse une base existante" \
    fails kubectl -n $ns exec deploy/$rel -c odoo -- \
    sh -c '/opt/odoo/entrypoint.sh odoo db init --password x "$PGDATABASE" >/tmp/init.log 2>&1'
check "garde-fou : message « exists, aborting »" \
    kubectl -n $ns exec deploy/$rel -c odoo -- grep -q "exists, aborting" /tmp/init.log
check "garde-fou : review intacte après le refus" http_ok $ns $rel
ns=e2e-recette
check "garde-fou : base ephemeral refusée en recette" \
    fails helm_raw guard recette "$DIGEST_A" --set database.type=ephemeral
check "garde-fou : aucune release créée" equals "$(helm -n $ns list -q -f '^guard$')" ""

# Recette -----------------------------------------------------------------------------
ns=e2e-recette
rel=odoo
admin_pw="$(secret_value $ns odoo-app admin-user-password)"
log "Recette: database installed apart (CNPG cluster chart, declared role), NetworkPolicy example"
check "recette : base installée avec le chart CNPG officiel" install_database $ns odoo-db
check "recette : rôle odoo déclaré, CREATEDB, non superutilisateur" \
    equals "$(kubectl -n $ns exec odoo-db-1 -c postgres -- psql -tAc \
        "select rolcreatedb::text || rolsuper::text from pg_roles where rolname = 'odoo'")" truefalse
check "recette : pg_create_restore_point accordé à odoo (base postgres)" \
    equals "$(kubectl -n $ns exec odoo-db-1 -c postgres -- psql -tAc \
        "select has_function_privilege('odoo', 'pg_create_restore_point(text)', 'execute')")" t
kubectl -n $ns apply -f deploy/examples/database-networkpolicy.yaml >/dev/null

log "Recette: deployment refused without the volumeSnapshot patch, or with a Retain class"
check "garde-fou : base sans section volumeSnapshot, déploiement refusé" \
    fails deploy recette "$DIGEST_A"
check "garde-fou : message du contrôle préalable" in_log "no restore point possible"
enable_snapshots odoo-db e2e-retain
check "garde-fou : classe de snapshots en Retain, déploiement refusé" fails deploy recette "$DIGEST_A"
check "garde-fou : message deletionPolicy" in_log "deletionPolicy Retain"
check "garde-fou : rien déployé" equals "$(helm -n $ns list -q -f '^odoo$')" ""
check "recette : patch volumeSnapshot de la base (administrateur)" enable_snapshots odoo-db
check "recette : helm upgrade de la base" install_database $ns odoo-db --set backups.retentionPolicy=31d
check "recette : patch conservé par helm upgrade" snapshots_enabled odoo-db

log "Recette: first installation (migrate Job in post-install, Odoo creates its database)"
check "recette : première installation" deploy recette "$DIGEST_A"
created_by_post_install() { # the migrate Job ran in post-install and created the database
    equals "$(hook_of_job $rel-migrate)" post-install && fails job_log_has $rel-migrate db-init "exists"
}
check "recette : Job migrate en post-install, base créée par db-init" created_by_post_install
check "recette : pas de point de restauration à la première installation" \
    equals "$(point_count pending,validated,restored)" 0
check "recette : /web/health et /web/login à 200" http_ok $ns $rel
check "recette : admin/admin refusé, mot de passe du Secret accepté" only_password $ns $rel "$admin_pw"
check "recette : base sans démo" \
    test "$(rpc $ns $rel "$admin_pw" "call('res.partner', 'search_count', [])")" -lt 10
rpc $ns $rel "$admin_pw" "call('res.partner', 'create', {'name': 'before-update'})" >/dev/null

log "Recette: update (hooks: stop, restore point, migrate, validate)"
check "recette : mise à jour" deploy recette "$DIGEST_B"
p2="odoo-db-preupgrade-r$(revision)"
check "recette : point de restauration $p2 validé" equals "$(state_of "$p2")" validated
check "recette : snapshot de la base et du filestore du point" \
    equals "$(snapshots_of "$p2" | wc -l | tr -d ' ')" 2
check "recette : snapshot du filestore rattaché à la Backup (UID, sans blockOwnerDeletion)" \
    filestore_owned "$p2"
check "recette : point nommé dans les WAL avant le snapshot" \
    job_log_has $rel-stop-snapshot restore-point "$p2"
check "recette : nouveau champ créé par click-odoo-update" \
    equals "$(has_field $ns $rel "$admin_pw" e2e_field)" True
check "recette : données conservées" equals "$(marker_count $ns $rel "$admin_pw" before-update)" 1
rpc $ns $rel "$admin_pw" "call('res.partner', 'create', {'name': 'after-update'})" >/dev/null

log "Recette: broken module, Odoo stays stopped"
check "recette : module cassé, déploiement en échec" fails deploy recette "$DIGEST_C"
p3="odoo-db-preupgrade-r$(revision)"
check "recette : point $p3 en attente (pending)" equals "$(state_of "$p3")" pending
check "recette : logs du Job migrate (vue cassée) dans le résumé du job" grep -q e2e_missing "$work/ci.md"
check "recette : Odoo reste arrêté" equals "$(replicas)" 0
# A write after the restore point, which the restoration must not bring back
psql_in odoo-db "create table e2e_after_restore_point (id int)" >/dev/null

log "Recette: retry after the failure, no new restore point"
check "recette : relance du module cassé, en échec" fails deploy recette "$DIGEST_C"
check "recette : relance, pas de nouveau point" \
    job_log_has $rel-stop-snapshot stop "$p3 still pending (previous attempt)"
check "recette : relance, un seul point en attente" equals "$(points_in pending)" "$p3 "

log "Recette: restore job (new cluster from the pending restore point)"
check "restauration : job restore" restore
r3="odoo-db-r${p3##*-r}"
check "restauration : nouveau cluster $r3, Service stable basculé" equals "$(service_cluster)" "$r3"
check "restauration : volume de $r3 créé depuis le snapshot du point" \
    equals "$(kubectl -n $ns get pvc "$r3-1" -o jsonpath='{.spec.dataSource.name}')" "$p3"
check "restauration : point $p3 restored" equals "$(state_of "$p3")" restored
check "restauration : section volumeSnapshot recopiée sur $r3" snapshots_enabled "$r3"
check "restauration : image d'avant le point" \
    equals "$(helm get values $rel -n $ns -o json | jq -r .image.digest)" "$DIGEST_B"
check "restauration : /web/health et /web/login à 200" http_ok $ns $rel
check "restauration : données du point de restauration présentes" \
    equals "$(marker_count $ns $rel "$admin_pw" after-update)" 1
check "restauration : écriture postérieure au point absente" \
    equals "$(psql_in "$r3" "select to_regclass('e2e_after_restore_point') is null")" t
check "restauration : même mot de passe par le Service stable (rôle déclaré)" \
    only_password $ns $rel "$admin_pw"
check "restauration : ancien cluster conservé" exists $ns cluster/odoo-db
check "restauration : archivage des WAL de $r3" archive_current_wal $ns "$r3"

log "Recette: next update, on the restored cluster"
check "recette : mise à jour (correctif)" deploy recette "$DIGEST_D"
p6="$r3-preupgrade-r$(revision)"
check "recette : point $p6 pris sur $r3 et validé" equals "$(state_of "$p6")" validated
check "recette : champ du correctif" equals "$(has_field $ns $rel "$admin_pw" e2e_fix)" True

log "Recette: failure then successful retry, which validates the first point"
check "recette : module cassé, en échec" fails deploy recette "$DIGEST_C"
p7="$r3-preupgrade-r$(revision)"
check "recette : correctif, réussi" deploy recette "$DIGEST_D"
check "recette : le correctif n'a pas pris de nouveau point" \
    job_log_has $rel-stop-snapshot stop "$p7 still pending (previous attempt)"
check "recette : premier point $p7 validé" equals "$(state_of "$p7")" validated

log "Recette: retention (3 restore points kept, a Backup takes its snapshots along)"
check "rétention : trois points gardés ($p3 $p6 $p7)" \
    equals "$(points_in validated,restored)" "$p3 $p6 $p7 "
check "rétention : $p2 supprimé avec ses snapshots" gone "$p2"
check "rétention : VolumeSnapshotContent de $p2 supprimés (classe en Delete)" contents_gone "$p2"

log "Recette: a purge error does not fail the update"
kubectl apply -f - >/dev/null <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: e2e-protect-backups}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - {apiGroups: [postgresql.cnpg.io], apiVersions: ["*"], operations: [DELETE], resources: [backups]}
  validations:
    - expression: "!has(oldObject.metadata.labels) || !('e2e-protect' in oldObject.metadata.labels)"
      message: protected by the e2e
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: e2e-protect-backups}
spec:
  policyName: e2e-protect-backups
  validationActions: [Deny]
EOF
kubectl -n $ns label backups.postgresql.cnpg.io "$p3" e2e-protect=true >/dev/null
sleep 5
check "rétention : mise à jour réussie malgré une purge refusée" \
    helm_raw $rel recette "$DIGEST_D" --set odoo.config.options.max_cron_threads=2 --wait
check "rétention : erreur de purge signalée dans les logs" \
    job_log_has $rel-validate validate "WARNING: could not delete the restore point $p3"
check "rétention : point protégé conservé" equals "$(state_of "$p3")" restored
kubectl -n $ns label backups.postgresql.cnpg.io "$p3" e2e-protect- >/dev/null
kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy e2e-protect-backups >/dev/null

log "Recette: database snapshot failure (no restore point, database untouched)"
rpc $ns $rel "$admin_pw" "call('res.partner', 'create', {'name': 'before-snapshot-failure'})" >/dev/null
kubectl -n $ns patch "cluster/$r3" --type json \
    -p '[{"op": "remove", "path": "/spec/backup/volumeSnapshot"}]' >/dev/null
check "snapshot de la base en échec : mise à jour en échec" \
    fails helm_raw $rel recette "$DIGEST_D" --set odoo.config.options.max_cron_threads=3 \
    --set restorePoints.timeoutSeconds=60 --wait
check "snapshot de la base en échec : stop-snapshot en échec" \
    equals "$(kubectl -n $ns get job $rel-stop-snapshot -o jsonpath='{.status.failed}')" 1
enable_snapshots "$r3"
check "snapshot de la base en échec : job restore, helm rollback seul" restore
check "snapshot de la base en échec : aucun point restauré" in_log "No restore point"
check "snapshot de la base en échec : base intacte, Odoo répond" \
    equals "$(marker_count $ns $rel "$admin_pw" before-snapshot-failure)" 1

log "Recette: filestore snapshot failure (incomplete restore point)"
check "snapshot du filestore en échec : mise à jour en échec" \
    fails helm_raw $rel recette "$DIGEST_D" --set odoo.config.options.max_cron_threads=4 \
    --set restorePoints.volumeSnapshotClass=e2e-missing --set restorePoints.timeoutSeconds=60 --wait
incomplete="$(points_in pending)"
echo "    incomplete pending point(s): $incomplete"
check "snapshot du filestore en échec : point incomplet, non restauré" restore
check "snapshot du filestore en échec : helm rollback seul" in_log "No restore point"
check "snapshot du filestore en échec : base intacte, Odoo répond" \
    equals "$(marker_count $ns $rel "$admin_pw" before-snapshot-failure)" 1
check "mise à jour suivante" helm_raw $rel recette "$DIGEST_D" \
    --set odoo.config.options.max_cron_threads=5 --wait
all_gone() { # all_gone <backup...>
    local point
    for point in "$@"; do gone "$point" || return 1; done
}
# shellcheck disable=SC2086 # list of names
check "mise à jour suivante : points incomplets supprimés" all_gone $incomplete
check "mise à jour suivante : aucun point en attente" equals "$(point_count pending)" 0
check "rétention : trois points au plus" equals "$(point_count validated,restored)" 3

log "Recette: restore job with the release deployed and no pending point (nothing to undo)"
before="$(revision)"
check "rien à restaurer : job restore sans effet" restore
check "rien à restaurer : message" in_log "nothing to restore"
check "rien à restaurer : révision inchangée" equals "$(revision)" "$before"

log "Recette: orphan restore point (validated by nobody after a successful update)"
orphan="$(points_in validated | awk '{print $NF}')"
kubectl -n $ns label backups.postgresql.cnpg.io "$orphan" "$PREFIX/upgrade-state=pending" --overwrite >/dev/null
check "point orphelin : la CI refuse la mise à jour" fails deploy recette "$DIGEST_B"
check "point orphelin : message de la CI" in_log "is still pending while the release is deployed"
check "point orphelin : stop-snapshot refuse une mise à jour à la main" \
    fails helm_raw $rel recette "$DIGEST_D" --set odoo.config.options.max_cron_threads=6
check "point orphelin : message de stop-snapshot" \
    job_log_has $rel-stop-snapshot stop "its validation failed"
check "point orphelin : Odoo continue de servir" http_ok $ns $rel
check "point orphelin : le job restore ne restaure pas" fails restore
check "point orphelin : message du job restore" in_log "update applied and served"
check "point orphelin : Service stable inchangé" equals "$(service_cluster)" "$r3"
kubectl -n $ns label backups.postgresql.cnpg.io "$orphan" "$PREFIX/upgrade-state=validated" --overwrite >/dev/null

log "Recette: filestore without PVC (restore point = the Backup only)"
check "sans PVC : mise à jour" helm_raw $rel recette "$DIGEST_D" \
    --set odoo.persistence.enabled=false --wait
pn="$(points_in validated | awk '{print $NF}')"
check "sans PVC : point $pn validé, snapshot de la base seul" \
    equals "$(snapshots_of "$pn" | grep -c .)/$(snapshots_of "$pn" | grep -c -- -filestore)" 1/0
check "retour au PVC" helm_raw $rel recette "$DIGEST_D" --wait
check "retour au PVC : filestore d'origine" \
    equals "$(kubectl -n $ns get deploy $rel -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')" "$rel-odoo-data"
check "rétention : trois points au plus à la fin" equals "$(point_count validated,restored)" 3

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
check "sweep : release, volumes et ressources de hook supprimés" \
    equals "$(helm -n $ns list -q -f '^pr-1$')/$(kubectl -n $ns get pvc,jobs,configmaps -o name |
        grep -v kube-root-ca)" "/"
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
