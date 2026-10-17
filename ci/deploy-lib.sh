# shellcheck shell=bash
# Helpers of ci/deploy.sh and ci/deploy-rollback.sh (sourced), see §3.2 and §3.3 of
# docs/plans/k8s-deployment.md. Globals set by the caller: env (review | recette |
# production), release, namespace, work (temporary directory), repository and digest (the
# image). Env: EXTRA_VALUES, a values file added after those of the environment (tests).
# shellcheck disable=SC2154 # those globals

log() { echo "--- $*"; }

fail() { # fail <message>: stops the script; the message also goes to the job summary
    echo "deploy: $*" >&2
    printf '\n**Échec** : %s\n' "$*" | ci_summary
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

save_state() { # $work/state.json: state of the environment, carried over by every deployment
    if [ "$env" = review ]; then
        echo '{}' >"$work/state.json"
    else
        release_values | jq '{state: (.state // {})}' >"$work/state.json"
    fi
}

helm_odoo() { # helm_odoo [helm args...]: the chart with the values of the environment, its
    # state and the image; the caller adds the settings of the step
    local extra=()
    if [ -n "${EXTRA_VALUES:-}" ]; then
        extra=(-f "$EXTRA_VALUES")
    fi
    helm upgrade --install "$release" deploy/chart -n "$namespace" \
        -f "deploy/values/$env.yaml" ${extra[@]+"${extra[@]}"} -f "$work/state.json" \
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

cnpg_ready() { # cnpg_ready <cluster>: ready, archiving its WAL, volume snapshots enabled
    local cluster="$1" json
    json="$(kubectl -n "$namespace" get clusters.postgresql.cnpg.io "$cluster" -o json)" ||
        fail "CNPG Cluster $cluster not found in $namespace"
    condition() { jq -r --arg t "$1" '.status.conditions[]? | select(.type == $t) | .status' <<<"$json"; }
    [ "$(condition Ready)" = True ] || fail "CNPG Cluster $cluster is not ready"
    [ "$(condition ContinuousArchiving)" = True ] ||
        fail "CNPG Cluster $cluster does not archive its WAL (ContinuousArchiving)"
    [ -n "$(jq -r '.spec.backup.volumeSnapshot.className // empty' <<<"$json")" ] ||
        fail "CNPG Cluster $cluster has no spec.backup.volumeSnapshot, no restore point possible. Apply the patch of deploy/examples/cnpg-cluster.values.yaml: kubectl -n $namespace patch cluster $cluster --type merge -p '{\"spec\":{\"backup\":{\"volumeSnapshot\":{\"className\":\"<VolumeSnapshotClass>\",\"online\":false}}}}'"
}

wait_pods_gone() { # Odoo pods of the release terminated
    kubectl -n "$namespace" wait pod --for=delete --timeout=300s \
        -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=odoo" >/dev/null 2>&1 || true
}

wait_job() { # wait_job <job> <timeout s>: 0 when complete; otherwise 1, with the logs of
    # every container in $work/<job>.log
    local job="$1" deadline=$((SECONDS + $2)) state
    while [ "$SECONDS" -lt "$deadline" ]; do
        state="$(kubectl -n "$namespace" get job "$job" \
            -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null || true)"
        case "$state" in
        *Complete*) return 0 ;;
        *Failed*) break ;;
        esac
        sleep 5
    done
    kubectl -n "$namespace" logs "job/$job" --all-containers --ignore-errors --prefix --tail=100 \
        >"$work/$job.log" 2>&1 || true
    return 1
}

job_logs_summary() { # job_logs_summary <job>: last lines of its logs in the job summary
    {
        echo
        echo "<details><summary>Logs du Job $1</summary>"
        echo
        echo '```'
        tail -40 "$work/$1.log"
        echo '```'
        echo "</details>"
    } | ci_summary
    tail -40 "$work/$1.log" >&2
}

odoo_url() { # public URL of Odoo, empty without HTTPRoute
    jq -r --arg release "$release" '
        if (.route.parentRefs // [] | length) == 0 then empty
        elif .environment == "review" then "https://\(.project)-\($release).\(.route.reviewDomain)"
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
