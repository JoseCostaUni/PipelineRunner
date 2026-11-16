#!/bin/bash
# Split executor on Deucalion, Kubernetes side. Run as root on Ulisses (the machine of Isabel's
# Kubernetes cluster, Argo and interLink). Needs kubectl, jq, argo (CLI) and mc. See README.md.
#
#   check                 read-only checks of the Kubernetes side
#   executor-image        the argoexec image Argo puts in every pod (must be pre-pulled on Deucalion)
#   artifacts             make the Global Storage Argo's default artifact repository in ARGO_NAMESPACE,
#                         apply the test module library, upload the test datasets (backs up what exists)
#   offload on|off        send every workflow's pods to the interLink node (Argo workflowDefaults), so
#                         the test workflows stay plain Argo; off restores the previous defaults
#   api direct|relay|off  which Kubernetes API address offloaded containers get (virtual kubelet):
#                         direct = K8S_API_HOST, relay = the relay on the login node, off = restore
#   relay-health          is the login-node relay reachable through our tunnel?    relay-log: agent log
#   reset-data            put the test data in the Global Storage back as in tests/datasets, without
#                         results of earlier runs ('test' does this first)
#   test [NN ...]         run tests/argo-native (default: all) and check results in Argo AND in the
#                         Global Storage; results in ./results/<time>/
#   clean                 delete the trial's workflows (interLink then removes their job folders)
#   restore               offload off + api off + saved artifact repository back (the cluster is as before)
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ZE="$(cd "$HERE/../.." && pwd)"
N="$ZE/tests/argo-native"
RELAYBIN="$ZE/setup/hpc/split-executor/api-relay/split-relay"
# Settings: deucalion.env next to this script, or the file named in SPLIT_ENV (the testbed rehearsal
# uses testbed.env).
ENV_FILE="${SPLIT_ENV:-$HERE/deucalion.env}"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy deucalion.env.example)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
DATASETS="$ZE/tests/datasets/users"
LABEL=split-trial=true
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NS="$ARGO_NAMESPACE"
VKC="$INTERLINK_INSTALL_DIR/VirtualKubeletConfig.yaml"
VKBAK="$VKC.pre-split"
STATE=/var/lib/split-executor
mkdir -p "$STATE"
AGENT_LOG=/var/log/split-relay-agent.log
# Isabel's tunnel turns host-key checks off, so root may have no known_hosts entry for the login
# node: pin its key on first use in our own file.
SSHO=(-o BatchMode=yes -o LogLevel=ERROR -o ServerAliveInterval=30 -i "$SSH_KEY"
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/known_hosts")
CM=workflow-controller-configmap

say()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
info() { printf 'INFO  %s\n' "$*"; }
gs() {
  local scheme=https; [ "${GS_INSECURE:-true}" = true ] && scheme=http
  mc alias set gs "$scheme://$GS_ENDPOINT" "$GS_ACCESS_KEY" "$GS_SECRET_KEY" >/dev/null
}
node_ready() { kubectl get node "$INTERLINK_NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
wait_ready() {
  local i; for i in $(seq 1 36); do [ "$(node_ready)" = True ] && { say "$INTERLINK_NODE_NAME Ready"; return 0; }; sleep 5; done
  say "ERROR: $INTERLINK_NODE_NAME not Ready after restart (journalctl -u interlink-vk)"; return 1
}
stop_relay_units() { local u; for u in split-relay-agent split-relay-tunnel; do systemctl stop "$u" >/dev/null 2>&1; systemctl reset-failed "$u" >/dev/null 2>&1; done; true; }
vk_config() { # addr port [ca-file]
  [ -f "$VKBAK" ] || cp -p "$VKC" "$VKBAK"
  cp -p "$VKBAK" "$VKC"
  printf '\nKubernetesApiAddr: "%s"\nKubernetesApiPort: "%s"\n' "$1" "$2" >>"$VKC"
  if [ -n "${3:-}" ]; then echo "KubernetesApiCaCrt: |" >>"$VKC"; sed 's/^/  /' "$3" >>"$VKC"; fi
  systemctl restart interlink-vk
  wait_ready
  grep -E '^KubernetesApi(Addr|Port)' "$VKC"
}
executor_image() {
  local img
  img="$(kubectl -n argo get deploy workflow-controller -o json \
    | jq -r '.spec.template.spec.containers[0].args // [] | . as $a
             | (index("--executor-image") // -1) as $i | if $i >= 0 then $a[$i+1] else empty end')"
  if [ -z "$img" ]; then
    img="$(kubectl -n argo get deploy workflow-controller -o jsonpath='{.spec.template.spec.containers[0].image}' \
      | sed 's#workflow-controller#argoexec#')"
  fi
  echo "$img"
}

case "${1:-}:${2:-}" in
  check:)
    FAILED=0
    for t in kubectl jq argo mc ssh curl; do command -v "$t" >/dev/null && pass "found $t" || fail "missing $t"; done
    [ -n "$GS_ACCESS_KEY" ] && [ -n "$GS_SECRET_KEY" ] && pass "Global Storage keys set" || fail "GS_ACCESS_KEY or GS_SECRET_KEY empty in $ENV_FILE"
    [ -d "$DATASETS" ] && pass "test datasets in $DATASETS" || fail "no $DATASETS"
    [ "$(node_ready)" = True ] && pass "node $INTERLINK_NODE_NAME Ready" || fail "node $INTERLINK_NODE_NAME not Ready"
    [ -f "$VKC" ] && pass "virtual kubelet config $VKC" || fail "no $VKC"
    kubectl -n argo get deploy workflow-controller >/dev/null 2>&1 && pass "Argo controller found" || fail "no Argo controller in namespace argo"
    info "argoexec image: $(executor_image)  (ARGO_EXEC_IMAGE in deucalion.env must be this)"
    [ "$(executor_image)" = "$ARGO_EXEC_IMAGE" ] && pass "ARGO_EXEC_IMAGE matches" || fail "ARGO_EXEC_IMAGE ($ARGO_EXEC_IMAGE) differs from the controller's"
    ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" true 2>/dev/null && pass "ssh to $HPC_USER@$HPC_LOGIN_HOST with $SSH_KEY" \
      || fail "ssh to $HPC_USER@$HPC_LOGIN_HOST with $SSH_KEY failed"
    gs; mc ls "gs/$GS_BUCKET" >/dev/null 2>&1 && pass "Global Storage bucket $GS_BUCKET reachable from Ulisses" \
      || info "bucket $GS_BUCKET not reachable or missing (created by 'artifacts')"
    if kubectl -n "$NS" get cm artifact-repositories >/dev/null 2>&1; then info "namespace $NS already has an artifact-repositories ConfigMap ('artifacts' backs it up)"; fi
    wd="$(kubectl -n argo get cm "$CM" -o json 2>/dev/null | jq -r '.data.workflowDefaults // empty')"
    [ -n "$wd" ] && info "Argo already has workflowDefaults ('offload' backs them up)" || info "Argo has no workflowDefaults"
    grep -q '^KubernetesApiAddr' "$VKC" 2>/dev/null && info "virtual kubelet: $(grep -E '^KubernetesApi(Addr|Port)' "$VKC" | tr '\n' ' ')" \
      || info "virtual kubelet: default API address"
    exit "$FAILED"
    ;;

  executor-image:) executor_image ;;

  artifacts:)
    [ -f "$N/modules.yaml" ] || { say "ERROR: $N missing"; exit 1; }
    gs
    mc mb -p "gs/$GS_BUCKET" >/dev/null
    if kubectl -n "$NS" get cm artifact-repositories >/dev/null 2>&1 && [ ! -f "$STATE/artifact-repositories.yaml" ]; then
      # Without the server-side fields, so 'restore' can put it back over the one applied here.
      kubectl -n "$NS" get cm artifact-repositories -o yaml \
        | grep -v -E '^  (resourceVersion|uid|creationTimestamp|managedFields):' >"$STATE/artifact-repositories.yaml"
      say "existing artifact-repositories saved to $STATE/artifact-repositories.yaml"
    fi
    kubectl -n "$NS" create secret generic split-gs-creds \
      --from-literal=accesskey="$GS_ACCESS_KEY" --from-literal=secretkey="$GS_SECRET_KEY" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
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
      bucket: $GS_BUCKET
      endpoint: $GS_ENDPOINT
      insecure: ${GS_INSECURE:-true}
      accessKeySecret:
        name: split-gs-creds
        key: accesskey
      secretKeySecret:
        name: split-gs-creds
        key: secretkey
YAML
    kubectl apply -n "$NS" -f "$N/modules.yaml" >/dev/null
    say "artifact repository: s3://$GS_BUCKET at $GS_ENDPOINT; WorkflowTemplate lisa-modules applied in $NS"
    bash "$0" reset-data
    ;;

  reset-data:)
    # Results of an earlier run would make the object checks pass without this run having written them.
    [ -d "$DATASETS" ] || { say "ERROR: $DATASETS missing"; exit 1; }
    gs
    mc rm --recursive --force "gs/$GS_BUCKET/users" >/dev/null 2>&1 || true
    mc rm --recursive --force "gs/$GS_BUCKET/t1" >/dev/null 2>&1 || true
    mc mirror --overwrite "$DATASETS" "gs/$GS_BUCKET/users" >/dev/null || { say "ERROR: upload to $GS_BUCKET failed"; exit 1; }
    printf 'hello from the global storage\n' | mc pipe "gs/$GS_BUCKET/t1/input.txt" >/dev/null
    say "Global Storage reset: $GS_BUCKET/users = tests/datasets, $GS_BUCKET/t1/input.txt"
    ;;

  offload:on)
    SAVED="$STATE/workflowDefaults.saved"
    [ -f "$SAVED" ] || kubectl -n argo get cm "$CM" -o json | jq -r '.data.workflowDefaults // ""' >"$SAVED"
    defaults="spec:
  nodeSelector:
    kubernetes.io/hostname: $INTERLINK_NODE_NAME
  tolerations:
  - key: virtual-node.interlink/no-schedule
    operator: Exists
  podMetadata:
    annotations:
      slurm-job.vk.io/flags: \"--account=$SLURM_ACCOUNT --partition=$SLURM_PARTITION\""
    kubectl -n argo patch cm "$CM" --type merge -p "$(jq -n --arg v "$defaults" '{data: {workflowDefaults: $v}}')" >/dev/null
    sleep 5
    say "offload ON: every workflow's pods go to $INTERLINK_NODE_NAME, partition $SLURM_PARTITION"
    say "Note: this applies to ALL workflows of this Argo, including Isabel's own tests. Switch off after the trial."
    ;;
  offload:off)
    SAVED="$STATE/workflowDefaults.saved"
    [ -f "$SAVED" ] || { say "offload already off"; exit 0; }
    if [ -s "$SAVED" ]; then
      kubectl -n argo patch cm "$CM" --type merge -p "$(jq -n --rawfile v "$SAVED" '{data: {workflowDefaults: $v}}')" >/dev/null
    else
      kubectl -n argo patch cm "$CM" --type json -p '[{"op":"remove","path":"/data/workflowDefaults"}]' >/dev/null 2>&1 || true
    fi
    rm -f "$SAVED"; sleep 5; say "offload OFF: workflowDefaults restored"
    ;;

  api:direct)
    stop_relay_units
    vk_config "$K8S_API_HOST" "$K8S_API_PORT"
    ;;
  api:relay)
    [ -x "$RELAYBIN" ] || chmod 0755 "$RELAYBIN" "$(dirname "$RELAYBIN")"/bin/split-relay-linux-* 2>/dev/null
    ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" "cat '$HPC_PROJECT_ROOT/split-executor/relay/ca.crt'" >"$STATE/relay-ca.crt" \
      || { say "ERROR: could not fetch the relay CA (run './hpc-side.sh relay on' on the login node first)"; exit 1; }
    stop_relay_units
    : >"$AGENT_LOG"
    # The tunnel is opened from here, like interLink's own: the login node never connects to Ulisses.
    systemd-run --quiet --unit=split-relay-tunnel -p Restart=always -p RestartSec=3 \
      /usr/bin/ssh -N "${SSHO[@]}" -o ExitOnForwardFailure=yes \
      -L "127.0.0.1:$RELAY_CTL_PORT:127.0.0.1:$RELAY_CTL_PORT" "$HPC_USER@$HPC_LOGIN_HOST"
    systemd-run --quiet --unit=split-relay-agent -p Restart=always -p RestartSec=3 \
      -p StandardOutput=append:$AGENT_LOG -p StandardError=append:$AGENT_LOG \
      "$RELAYBIN" agent --ctl "http://127.0.0.1:$RELAY_CTL_PORT" \
      --api "https://$K8S_API_HOST:$K8S_API_PORT" --ca /etc/kubernetes/pki/ca.crt
    vk_config 127.0.0.1 "$RELAY_API_PORT" "$STATE/relay-ca.crt"
    bash "$0" relay-health
    ;;
  api:off)
    stop_relay_units
    if [ -f "$VKBAK" ]; then cp -p "$VKBAK" "$VKC"; rm -f "$VKBAK"; systemctl restart interlink-vk; wait_ready; say "virtual kubelet config restored"
    else say "virtual kubelet config was not changed"; fi
    ;;
  relay-health:)
    for _ in $(seq 1 10); do
      out="$(curl -s -m 5 "http://127.0.0.1:$RELAY_CTL_PORT/health" 2>/dev/null)" && [ -n "$out" ] && { say "relay reachable through the tunnel: $out"; exit 0; }
      sleep 2
    done
    say "relay NOT reachable through the tunnel (systemctl status split-relay-tunnel)"; exit 1
    ;;
  relay-log:) cat "$AGENT_LOG" 2>/dev/null || say "no agent log" ;;

  test:*)
    shift
    tests="$*"; [ -n "$tests" ] || tests="$(ls "$N" | sed -n 's/^\([0-9][0-9]\)-.*\.yaml$/\1/p' | tr '\n' ' ')"
    RUN="$(date +%Y%m%d-%H%M%S)"; OUT="$HERE/results/$RUN"; mkdir -p "$OUT"
    bash "$0" reset-data || exit 1
    gs
    say "run $RUN: tests $tests -> $OUT"
    for T in $tests; do
      WF="$(ls "$N/$T"-*.yaml 2>/dev/null | head -n 1)"; [ -n "$WF" ] || { say "TC$T  no workflow file"; continue; }
      D="$OUT/TC$T"; mkdir -p "$D"; cp "$WF" "$D/workflow.yaml"
      start=$(date +%s)
      NAME="$(argo submit -n "$NS" "$WF" -l "$LABEL" -o json | jq -r .metadata.name)" || { say "TC$T  submit failed"; continue; }
      rc=0; timeout 1800 argo wait -n "$NS" "$NAME" >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 124 ] && { argo stop -n "$NS" "$NAME" >/dev/null 2>&1; sleep 10; }
      secs=$(( $(date +%s) - start ))
      argo get -n "$NS" "$NAME" -o json >"$D/workflow.json" 2>/dev/null || echo '{}' >"$D/workflow.json"
      argo logs -n "$NS" "$NAME" >"$D/logs.txt" 2>&1 || true
      PHASE="$(jq -r '.status.phase // "Unknown"' "$D/workflow.json")"
      jq -r '(.status.nodes // {}) | to_entries[] | .value | select(.type == "Pod") | [.displayName, .phase] | @tsv' \
        "$D/workflow.json" | sort >"$D/steps.tsv"
      ok=0; tot=0; : >"$D/checks.tsv"
      while IFS=$'\t' read -r t kind what exp; do
        case "$t" in ''|'#'*) continue;; esac
        [ "$t" = "$T" ] || continue
        tot=$((tot + 1))
        case "$kind" in
          phase)  got="$PHASE";;
          step)   got="$(awk -F'\t' -v s="$what" '$1==s {print $2}' "$D/steps.tsv" | head -n 1)"; got="${got:-missing}";;
          object) if body="$(mc cat "gs/$GS_BUCKET/$what" 2>/dev/null)"; then
                    case "$body" in *"$exp"*) got="$exp";; *) got="content: $(printf '%s' "$body" | head -c 60 | tr '\n' ' ')";; esac
                  else got="no such object"; fi;;
          *) got="unknown check";;
        esac
        if [ "$got" = "$exp" ]; then r=PASS; ok=$((ok + 1)); else r=FAIL; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$kind" "$what" "$exp" "$got" >>"$D/checks.tsv"
      done <"$N/checks.tsv"
      if [ "$tot" -gt 0 ] && [ "$ok" -eq "$tot" ]; then v=PASS; else v=FAIL; fi
      line="TC$T  $v  $PHASE in $((secs / 60))m$(printf '%02d' $((secs % 60)))s, checks $ok/$tot  ($NAME)"
      say "$line"; echo "$line" >>"$OUT/summary.txt"
      awk -F'\t' '$1=="FAIL" {print "        failed: " $2 " " $3 " (expected " $4 ", got " $5 ")"}' "$D/checks.tsv" | tee -a "$OUT/summary.txt"
    done
    say "summary: $OUT/summary.txt  (keep the whole folder as evidence)"
    ;;

  clean:)
    argo delete -n "$NS" -l "$LABEL" 2>&1 | tail -n 20
    say "trial workflows deleted; interLink removes their job folders on the login node"
    ;;

  restore:)
    bash "$0" offload off
    bash "$0" api off
    if [ -f "$STATE/artifact-repositories.yaml" ]; then
      kubectl replace -f "$STATE/artifact-repositories.yaml" >/dev/null \
        && rm -f "$STATE/artifact-repositories.yaml" && say "artifact-repositories ConfigMap restored"
    fi
    ;;

  *) awk 'NR > 1 && !/^#/ {exit} NR > 1' "$0"; exit 2;;
esac
