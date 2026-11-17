#!/bin/bash
# Test T1, Kubernetes side (as root on ulisses). The workflows are plain Argo
# (lisa-pipeline-runner_ze/tests/argo-native, copied to /opt/testbed/ze/argo-native).
#   setup                  MinIO as Argo's default artifact repository (bucket, secret, ConfigMap),
#                          and the module library (WorkflowTemplate lisa-modules)
#   executor-image         the argoexec image the controller puts in workflow pods
#   offload on|off         on: Argo workflowDefaults send every workflow's pods to interlink-node
#                          (nodeSelector, toleration, Slurm flags), so the workflows stay plain Argo.
#                          off: restore (T0's resource templates must not be sent there)
#   reset-data             Global Storage: her test datasets under argo-artifacts/users/, and
#                          t1/input.txt for TC00; no results of earlier runs
#   run RUN MODE TEST      submit one test as written, wait, record steps, pods and logs, and
#                          evaluate checks.tsv against Argo and the Global Storage.
#                          Last line, e.g. "PASS  Succeeded in 0m54s, checks 2/2" (FAIL: why)
#   pods RUN MODE TEST     "<pod> <uid>" of the test's pods (to collect their job folders)
#   delete RUN MODE TEST   delete the test's workflow (interLink then removes its job folders)
#   pack RUN
source /opt/testbed/guest/lib.sh
load_ips
export KUBECONFIG=/etc/kubernetes/admin.conf
N=$TB/ze/argo-native
L=/opt/lpr
OUT=/var/tmp/t1-argo
NS=default
B=argo-artifacts

slurm_flags() {
  # Account and partition from her .env (the testbed values are appended last, so they win).
  ( set +u; source "$L/setup/kubernetes/.env"; echo "--account=$SLURM_ACCOUNT --partition=$SLURM_PARTITION" )
}
gs() { mc alias set gs http://127.0.0.1:9000 admin admin123 >/dev/null; }

case "${1:-}" in
  setup)
    [ -f "$N/modules.yaml" ] || { log "ERROR: $N missing (is lisa-pipeline-runner_ze next to the testbed?)"; exit 1; }
    gs
    mc mb -p "gs/$B" >/dev/null
    kubectl -n "$NS" create secret generic t1-minio-creds \
      --from-literal=accesskey=admin --from-literal=secretkey=admin123 \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # Endpoint = ulisses' own address: the pods run on the HPC side, not inside the cluster.
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: artifact-repositories
  namespace: $NS
  annotations:
    workflows.argoproj.io/default-artifact-repository: default-v1
data:
  default-v1: |
    s3:
      bucket: $B
      endpoint: $ULISSES_IP:9000
      insecure: true
      accessKeySecret:
        name: t1-minio-creds
        key: accesskey
      secretKeySecret:
        name: t1-minio-creds
        key: secretkey
YAML
    kubectl apply -n "$NS" -f "$N/modules.yaml" >/dev/null
    log "artifact repository: s3://$B at $ULISSES_IP:9000; WorkflowTemplate lisa-modules applied"
    ;;
  executor-image)
    img="$(kubectl -n argo get deploy workflow-controller -o json \
      | jq -r '.spec.template.spec.containers[0].args // [] | . as $a
               | (index("--executor-image") // -1) as $i | if $i >= 0 then $a[$i+1] else empty end')"
    if [ -z "$img" ]; then
      v="$( set +u; source "$L/setup/kubernetes/.env"; echo "$ARGO_VERSION")"
      img="quay.io/argoproj/argoexec:$v"
    fi
    echo "$img"
    ;;
  offload)
    CM=workflow-controller-configmap
    SAVED=/var/tmp/t1-workflowdefaults.saved
    case "$2" in
      on)
        if [ ! -f "$SAVED" ]; then
          kubectl -n argo get cm "$CM" -o json | jq -r '.data.workflowDefaults // ""' >"$SAVED"
        fi
        defaults="$(cat <<YAML
spec:
  nodeSelector:
    kubernetes.io/hostname: interlink-node
  tolerations:
  - key: virtual-node.interlink/no-schedule
    operator: Exists
  podMetadata:
    annotations:
      slurm-job.vk.io/flags: "$(slurm_flags)"
YAML
)"
        kubectl -n argo patch cm "$CM" --type merge \
          -p "$(jq -n --arg v "$defaults" '{data: {workflowDefaults: $v}}')" >/dev/null
        ;;
      off)
        [ -f "$SAVED" ] || { log "offload already off"; exit 0; }
        if [ -s "$SAVED" ]; then
          kubectl -n argo patch cm "$CM" --type merge \
            -p "$(jq -n --rawfile v "$SAVED" '{data: {workflowDefaults: $v}}')" >/dev/null
        else
          kubectl -n argo patch cm "$CM" --type json -p '[{"op":"remove","path":"/data/workflowDefaults"}]' >/dev/null 2>&1 || true
        fi
        rm -f "$SAVED"
        ;;
      *) echo "offload on|off" >&2; exit 2;;
    esac
    sleep 5   # the controller watches its ConfigMap and reloads it
    log "workflowDefaults: $(kubectl -n argo get cm "$CM" -o json | jq -c '.data.workflowDefaults // "none"')"
    ;;
  reset-data)
    gs
    mc rm --recursive --force "gs/$B/users" >/dev/null 2>&1 || true
    mc rm --recursive --force "gs/$B/t1" >/dev/null 2>&1 || true
    mc mirror --overwrite "$L/tests/datasets/users" "gs/$B/users" >/dev/null
    printf 'hello from the global storage\n' | mc pipe "gs/$B/t1/input.txt" >/dev/null
    log "Global Storage reset: $B/users = her test datasets, $B/t1/input.txt"
    ;;
  run)
    RUN="$2" MODE="$3" T="$4"
    D="$OUT-$RUN/$MODE/TC$T"
    mkdir -p "$D"
    # Never end without a result line: say which command failed.
    trap 'echo "ERROR line $LINENO: $BASH_COMMAND" >&2; echo "ERROR in the test runner (line $LINENO), see t1.log"' ERR
    WF="$(ls "$N/$T"-*.yaml)"
    cp "$WF" "$D/workflow.yaml"          # submitted exactly as written
    gs
    start=$(date +%s)
    NAME="$(argo submit -n "$NS" "$WF" -o json | jq -r .metadata.name)"
    echo "$NAME" >"$D/name"
    rc=0
    timeout 1200 argo wait -n "$NS" "$NAME" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && { argo stop -n "$NS" "$NAME" >/dev/null 2>&1 || true; sleep 10; }
    end=$(date +%s)
    argo get -n "$NS" "$NAME" -o json >"$D/workflow.json" 2>/dev/null || echo '{}' >"$D/workflow.json"
    kubectl get pods -n "$NS" -l "workflows.argoproj.io/workflow=$NAME" -o json >"$D/pods.json" 2>/dev/null || echo '{"items":[]}' >"$D/pods.json"
    jq -r '.items[] | "\(.metadata.name) \(.metadata.uid)"' "$D/pods.json" >"$D/pods.txt" || true
    jq -r '(.status.nodes // {}) | to_entries[] | .value | select(.type == "Pod")
           | [.displayName, .phase, ((.message // "") | gsub("[\t\n|]"; " ") | .[0:160])] | @tsv' \
      "$D/workflow.json" 2>/dev/null | sort >"$D/steps.tsv" || true
    mc ls -r "gs/$B/" >"$D/minio.txt" 2>&1 || true
    PHASE="$(jq -r '.status.phase // "Unknown"' "$D/workflow.json" 2>/dev/null || echo Unknown)"
    # What the test must have produced (checks.tsv), checked in Argo and in the Global Storage.
    : >"$D/checks.tsv"
    ok=0; tot=0
    while IFS=$'\t' read -r t kind what exp; do
      case "$t" in ''|'#'*) continue;; esac
      [ "$t" = "$T" ] || continue
      tot=$((tot + 1))
      case "$kind" in
        phase)  got="$PHASE";;
        step)   got="$(awk -F'\t' -v s="$what" '$1==s {print $2}' "$D/steps.tsv" | head -n 1)"; got="${got:-missing}";;
        object) if body="$(mc cat "gs/$B/$what" 2>/dev/null)"; then
                  case "$body" in *"$exp"*) got="$exp";; *) got="content: $(printf '%s' "$body" | head -c 80 | tr '\n' ' ')";; esac
                else got="no such object"; fi;;
        *)      got="unknown check";;
      esac
      if [ "$got" = "$exp" ]; then r=PASS; ok=$((ok + 1)); else r=FAIL; fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$kind" "$what" "$exp" "$got" >>"$D/checks.tsv"
    done <"$N/checks.tsv"
    secs=$((end - start))
    took="$((secs / 60))m$(printf '%02d' $((secs % 60)))s"
    why=""
    [ "$rc" -eq 124 ] && why="; stopped after 20 min"
    first="$(awk -F'\t' '$2!="Succeeded" {print $1 ": " $3; exit}' "$D/steps.tsv" 2>/dev/null)"
    [ "$PHASE" != Succeeded ] && [ -n "$first" ] && why="$why; $first"
    fails="$(awk -F'\t' '$1=="FAIL" {printf "%s%s %s", (n++?", ":""), $2, $3}' "$D/checks.tsv")"
    [ -n "$fails" ] && why="$why; failed checks: $fails"
    # The verdict comes from the checks (TC02 is meant to end Failed).
    if [ "$tot" -gt 0 ] && [ "$ok" -eq "$tot" ]; then verdict=PASS; else verdict=FAIL; fi
    [ "$verdict" = PASS ] && [ "$PHASE" != Succeeded ] && why="; $PHASE as expected"
    echo "$verdict  $PHASE in $took, checks $ok/$tot$why"
    ;;
  pods)
    cat "$OUT-$2/$3/TC$4/pods.txt" 2>/dev/null || true
    ;;
  delete) # RUN MODE TEST
    n="$(cat "$OUT-$2/$3/TC$4/name" 2>/dev/null || true)"
    [ -n "$n" ] && argo delete -n "$NS" "$n" >/dev/null 2>&1 || true
    ;;
  pack)
    tar czf "/var/tmp/t1-argo-$2.tar.gz" -C "$OUT-$2" .
    chmod 644 "/var/tmp/t1-argo-$2.tar.gz"
    ;;
  *) echo "usage: $0 setup | executor-image | offload on|off | reset-data | run RUN MODE TEST | pods RUN MODE TEST | delete RUN MODE TEST | pack RUN" >&2; exit 2;;
esac
