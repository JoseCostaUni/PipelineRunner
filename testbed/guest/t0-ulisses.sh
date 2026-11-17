#!/bin/bash
# Experiment T0, Kubernetes side (as root on ulisses).
#   reset-data              restore the Global Storage to the test datasets
#   run RUN MODE TEST       submit one of Isabel's test workflows, wait, record step phases,
#                           what Kubernetes reported for each HPC pod, and the Global Storage content
#   pack RUN                archive the results for the host
source /opt/testbed/guest/lib.sh
export KUBECONFIG=/etc/kubernetes/admin.conf
L=/opt/lpr
OUT=/var/tmp/t0-argo

# Record what Kubernetes reports for every pod on the virtual node, every 5 s, while the test runs
# (the Jobs delete their pods 300 s after finishing, so a single snapshot at the end misses some).
# One line per poll and pod: uid, pod, phase, exit code, reason, INPUT_URI/OUTPUT_URI.
poll_pods() {
  while :; do
    kubectl get pods -n default --field-selector spec.nodeName=interlink-node -o json 2>/dev/null \
      | jq -r '.items[] | [.metadata.uid, .metadata.name, (.status.phase // ""),
          (((.status.containerStatuses // [])[0].state.terminated.exitCode // "") | tostring),
          ((.status.containerStatuses // [])[0].state.terminated.reason // ""),
          ((.spec.containers[0].env // []) | map(select(.name == "INPUT_URI" or .name == "OUTPUT_URI")
            | "\(.name)=\(.value // "")") | join(" "))] | @tsv' 2>/dev/null >>"$1" || true
    sleep 5
  done
}

case "${1:-}" in
  reset-data)
    mc alias set gs http://127.0.0.1:9000 admin admin123 >/dev/null
    mc rm --recursive --force gs/users >/dev/null 2>&1 || true
    mc mb -p gs/users >/dev/null
    mc mirror --overwrite "$L/tests/datasets/users" gs/users >/dev/null
    log "Global Storage reset to tests/datasets"
    ;;
  run)
    RUN="$2" MODE="$3" T="$4"
    D="$OUT-$RUN/argo/$MODE"
    mkdir -p "$D"
    WF="$(ls "$L"/tests/workflows/"$T"-*.yaml)"
    if [ "$T" = 10 ]; then
      # TC10 is a CronWorkflow (daily). Suspend its schedule, start one run now, and delete it only
      # after the run: workflows created from a CronWorkflow are owned by it, so deleting it earlier
      # would delete the run too.
      NS=argo
      kubectl apply -f "$WF" >/dev/null
      kubectl patch cronworkflow test-10-full-flow -n "$NS" --type merge -p '{"spec":{"suspend":true}}' >/dev/null
      NAME="$(argo submit -n "$NS" --from cronwf/test-10-full-flow -o json | jq -r .metadata.name)"
    else
      NS=default
      NAME="$(argo submit -n "$NS" "$WF" -o json | jq -r .metadata.name)"
    fi
    start=$(date +%s)
    : >"$D/$T.pods.raw"
    poll_pods "$D/$T.pods.raw" >/dev/null 2>&1 &
    POLL=$!
    set +e
    timeout 1200 argo wait -n "$NS" "$NAME" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 124 ]; then
      argo stop -n "$NS" "$NAME" >/dev/null 2>&1 || true
      sleep 10
    fi
    sleep 6
    kill "$POLL" 2>/dev/null || true
    wait "$POLL" 2>/dev/null || true
    end=$(date +%s)
    # Last state seen for each pod -> pods.tsv: mode, test, uid, pod, phase, exit, reason, uris
    awk -F'\t' '{last[$1]=$0} END {for (u in last) print last[u]}' "$D/$T.pods.raw" \
      | awk -F'\t' -v m="$MODE" -v t="$T" 'BEGIN{OFS="\t"} {print m, t, $0}' >>"$D/pods.tsv"
    rm -f "$D/$T.pods.raw"
    # What actually reached the Global Storage
    mc ls -r gs/users >"$D/$T.minio.txt" 2>&1 || true
    if ! argo get -n "$NS" "$NAME" -o json >"$D/$T.json" 2>/dev/null; then
      echo '{"status":{"phase":"Missing","message":"workflow not found after the run"}}' >"$D/$T.json"
    fi
    [ "$T" = 10 ] && kubectl delete cronworkflow test-10-full-flow -n "$NS" --ignore-not-found >/dev/null
    jq -r --arg m "$MODE" --arg t "$T" \
      '[$m, $t, "(workflow)", (.status.phase // "Unknown"), ((.status.message // "") | gsub("[\t\n]"; " "))] | @tsv' \
      "$D/$T.json" >>"$D/steps.tsv"
    jq -r --arg m "$MODE" --arg t "$T" \
      '(.status.nodes // {}) | to_entries[] | .value | select(.type == "Pod")
       | [$m, $t, .displayName, .phase, ((.message // "") | gsub("[\t\n]"; " "))] | @tsv' \
      "$D/$T.json" | sort -k3 >>"$D/steps.tsv"
    timeout_note=""
    [ "$rc" -eq 124 ] && timeout_note=" (stopped after 20 min)"
    echo "$(jq -r '.status.phase // "Unknown"' "$D/$T.json")$timeout_note  $NAME  $((end - start))s"
    ;;
  pack)
    RUN="$2"
    tar czf "/var/tmp/t0-argo-$RUN.tar.gz" -C "$OUT-$RUN" argo
    chmod 644 "/var/tmp/t0-argo-$RUN.tar.gz"
    ;;
  *) echo "usage: $0 reset-data | run RUN MODE TEST | pack RUN" >&2; exit 2;;
esac
