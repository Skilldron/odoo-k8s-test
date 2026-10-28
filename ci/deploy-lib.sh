# shellcheck shell=bash
# Helpers of ci/deploy.sh and ci/deploy-restore.sh (sourced). Globals set by the caller:
# env (name of the environment), release, namespace, work (temporary directory),
# repository, digest and version (the image, ci/deploy.sh). Env: EXTRA_VALUES, a values file added after those of the
# environment (tests); CHART, a local chart directory instead of the version of
# deploy/chart.env.
# shellcheck disable=SC2154 # those globals

# shellcheck source=deploy/chart.env
source deploy/chart.env
if [ -n "${CHART:-}" ]; then
    chart=("$CHART")
else
    chart=("$CHART_REF" --version "$CHART_VERSION")
fi

log() { echo "--- $*"; }

fail() { # fail <message>: stops the script; the message also goes to the job summary
    echo "deploy: $*" >&2
    printf '\n**Failed**: %s\n' "$*" | ci_summary
    exit 1
}

namespace_of_context() {
    kubectl config view --minify -o jsonpath='{..namespace}'
}

release_values() { # user-supplied values of the current release (JSON), {} without release
    { helm get values "$release" -n "$namespace" -o json 2>/dev/null || echo '{}'; } | jq -c '. // {}'
}

release_status() { # status of the current release, "none" without release
    helm status "$release" -n "$namespace" -o json 2>/dev/null | jq -r '.info.status' || echo none
}

pull_chart() { # the pinned chart, pulled once into $work: helm install and upgrade of an
    # OCI reference print "Pulled:" and "Digest:" on stdout, ahead of their -o json output
    [ -z "${CHART:-}" ] && [ ! -d "$work/chart" ] || return 0
    mkdir "$work/chart"
    helm pull "$CHART_REF" --version "$CHART_VERSION" -d "$work/chart" >&2 ||
        fail "chart $CHART_REF $CHART_VERSION not pulled"
    chart=("$work"/chart/*.tgz)
}

helm_odoo() { # helm_odoo [helm args...]: the chart with the values of the environment and
    # the image; its version as tag (label app.kubernetes.io/version), the digest decides
    pull_chart
    local extra=()
    if [ -n "${EXTRA_VALUES:-}" ]; then
        extra=(-f "$EXTRA_VALUES")
    fi
    if [ -n "${version:-}" ]; then
        extra+=(--set image.tag="$version")
    fi
    helm upgrade --install "$release" "${chart[@]}" -n "$namespace" \
        -f deploy/values.yaml -f "deploy/values/$env.yaml" ${extra[@]+"${extra[@]}"} \
        --set image.repository="$repository" --set image.digest="$digest" \
        --history-max 10 "$@"
}

render_values() { # render_values [helm args...] → $work/values.json: server-side dry run
    # (rendering and admission checks), and the merged values of the chart
    helm_odoo --dry-run=server -o json "$@" >"$work/dry.json" 2>"$work/dry.err" || {
        cat "$work/dry.err" >&2
        fail "rendering refused by Helm or the API server (see the log)"
    }
    jq '.chart.values * .config' "$work/dry.json" >"$work/values.json"
}

value() { # value <jq path>: one merged value, empty when null
    jq -r "($1) // empty" "$work/values.json"
}

require_keys() { # require_keys <secret> <key...>
    local secret="$1" keys key
    shift
    keys="$(kubectl -n "$namespace" get secret "$secret" -o json 2>/dev/null |
        jq -r '.data // {} | keys[]')" || fail "Secret $secret not found in $namespace"
    for key in "$@"; do
        grep -qx "$key" <<<"$keys" || fail "Secret $secret has no key $key"
    done
}

cluster_object() { # cluster_object <resource> <name>: cluster-scoped object of the
    # administrator; not checked when the CI may not read it
    local out
    out="$(kubectl get "$1" "$2" -o name 2>&1)" && return 0
    case "$out" in
    *[Ff]orbidden*) echo "    $1/$2: not readable by the CI, not checked" ;;
    *) fail "$1 $2 not found" ;;
    esac
}

active_cluster() { # active_cluster <service>: CNPG cluster in the selector of the stable Service
    kubectl -n "$namespace" get service "$1" -o jsonpath='{.spec.selector.cnpg\.io/cluster}'
}

cnpg_ready() { # cnpg_ready <cluster>: ready, archiving its WAL, cold volume snapshots owned
    # by their Backup (the administrator's patch)
    local cluster="$1" json snapshot
    json="$(kubectl -n "$namespace" get clusters.postgresql.cnpg.io "$cluster" -o json)" ||
        fail "CNPG Cluster $cluster not found in $namespace"
    condition() { jq -r --arg t "$1" '.status.conditions[]? | select(.type == $t) | .status' <<<"$json"; }
    [ "$(condition Ready)" = True ] || fail "CNPG Cluster $cluster is not ready"
    [ "$(condition ContinuousArchiving)" = True ] ||
        fail "CNPG Cluster $cluster does not archive its WAL (ContinuousArchiving)"
    snapshot="$(jq -c '.spec.backup.volumeSnapshot // {} |
        {className, online, snapshotOwnerReference}' <<<"$json")"
    [ "$(jq -r '.className != null and .online == false and .snapshotOwnerReference == "backup"' \
        <<<"$snapshot")" = true ] ||
        fail "CNPG Cluster $cluster: spec.backup.volumeSnapshot is $snapshot, no restore point possible. Required by the Odoo chart (README, Database of a persistent instance): kubectl -n $namespace patch cluster $cluster --type merge -p '{\"spec\":{\"backup\":{\"volumeSnapshot\":{\"className\":\"<VolumeSnapshotClass>\",\"online\":false,\"snapshotOwnerReference\":\"backup\"}}}}'"
}

snapshot_class_deletes() { # snapshot_class_deletes <class>: deletionPolicy Delete, or the
    # purge of the restore points frees nothing; not checked when the CI may not read it
    local out
    out="$(kubectl get volumesnapshotclasses.snapshot.storage.k8s.io "$1" \
        -o jsonpath='{.deletionPolicy}' 2>&1)" || case "$out" in
    *[Ff]orbidden*)
        echo "    VolumeSnapshotClass $1: not readable by the CI, deletionPolicy not checked"
        return 0
        ;;
    *) fail "VolumeSnapshotClass $1 not found" ;;
    esac
    [ "$out" = Delete ] ||
        fail "VolumeSnapshotClass $1 has deletionPolicy $out: deleting a restore point would not free its space (deletionPolicy: Delete required)"
}

points() { # points <states> [prefix]: "<name> <phase> <filestore snapshot> <target image>"
    # per restore point of the release in those states (comma-separated), oldest first
    local prefix="${2:-$(value .labelPrefix)}"
    kubectl -n "$namespace" get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp \
        -l "app.kubernetes.io/instance=$release,$prefix/backup-type=pre-upgrade,$prefix/upgrade-state in ($1)" \
        -o json | jq -r --arg p "$prefix" '.items[] | [.metadata.name, (.status.phase // "-"),
            (.metadata.annotations["\($p)/filestore"] // "" | if . == "" then "-" else . end),
            (.metadata.annotations["\($p)/target-image"] // "-")] | join(" ")'
}

complete_point() { # complete_point <phase> <filestore snapshot>: Backup completed and its
    # filestore snapshot, if any, ready to use
    [ "$1" = completed ] || return 1
    [ "$2" = - ] && return 0
    [ "$(kubectl -n "$namespace" get volumesnapshots.snapshot.storage.k8s.io "$2" \
        -o jsonpath='{.status.readyToUse}' 2>/dev/null)" = true ]
}

complete_pending() { # complete_pending [prefix]: "<name> <target image>" of the complete
    # pending restore points of the release
    local name phase fs target
    points pending "$@" | while read -r name phase fs target; do
        if complete_point "$phase" "$fs"; then
            echo "$name $target"
        fi
    done
}

serving() { # serving <image>: the Odoo Deployments of the release run that image and are
    # available
    kubectl -n "$namespace" get deployments \
        -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=odoo" -o json |
        jq -e --arg i "$1" '[.items[] | select(.spec.template.spec.containers[0].image == $i
            and (.status.availableReplicas // 0) > 0)] | length > 0' >/dev/null
}

hook_jobs() { # hook_jobs <condition>: hook Jobs of the release with that condition true
    # (Failed, Complete) or still active (Active)
    kubectl -n "$namespace" get jobs -l "app.kubernetes.io/instance=$release" -o json |
        jq -r --arg c "$1" '.items[] | select(
            if $c == "Active" then (.status.active // 0) > 0
            else any(.status.conditions[]?; .type == $c and .status == "True") end) |
            .metadata.name'
}

failed_jobs_summary() { # logs of the failed hook Jobs of the release, in the job summary
    local job
    for job in $(hook_jobs Failed); do
        kubectl -n "$namespace" logs "job/$job" --all-containers --ignore-errors --prefix \
            --tail=100 >"$work/$job.log" 2>&1 || true
        {
            echo
            echo "<details><summary>Logs of the Job $job</summary>"
            echo
            echo '```'
            tail -40 "$work/$job.log"
            echo '```'
            echo "</details>"
        } | ci_summary
        echo "--- logs of the Job $job" >&2
        tail -40 "$work/$job.log" >&2
    done
}

odoo_url() { # public URL of Odoo, empty without HTTPRoute
    jq -r --arg release "$release" '
        if (.route.parentRefs // [] | length) == 0 then empty
        elif .ephemeral then "https://\(.project)-\($release).\(.route.reviewDomain)"
        else "https://\(.route.host)" end' "$work/values.json"
}

smoke() { # smoke <url>: /web/health and /web/login answer 200 through the Gateway
    local path code
    for path in /web/health /web/login; do
        code=""
        for _ in $(seq 1 30); do
            code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$1$path" 2>/dev/null || true)"
            [ "$code" = 200 ] && break
            sleep 5
        done
        [ "$code" = 200 ] || {
            echo "smoke: $1$path answered ${code:-nothing}" >&2
            return 1
        }
    done
}

output() { # output <name> <value>: step output on GitHub Actions
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "$1=$2" >>"$GITHUB_OUTPUT"
    fi
}
