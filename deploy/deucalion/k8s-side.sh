#!/bin/bash
# Deucalion trial, Kubernetes side. Runs on Ulisses as your own user: no root, no sudo. Needs a kubeconfig
# with cluster-admin (default ~/.kube/config), kubectl, jq, curl, ssh, ssh-keyscan, setsid, openssl, git,
# and argo + mc ('tools' fetches them). Everything installed here lives in TRIAL_HOME (default
# ~/lisa-trial); what goes into the cluster carries app.kubernetes.io/managed-by=deucalion-trial where it
# can. See README.md.
# Two modes, one at a time: split (interLink 0.6.1 + split executor) and reverse (interLink 0.6.3 +
# reverse tunnel). 'mode' switches both sides at once; the commands below it are its steps.
#
#   check [split|reverse] read-only checks of this side (default: both modes)
#   status                the mode of each side and what runs now (asks the login node too)
#   argo                  install Argo Workflows (ARGO_VERSION) in namespace argo if it is not there, and
#                         prepare ARGO_NAMESPACE, where the test workflows run
#   tools                 argo (CLI, the controller's version) and mc into TRIAL_HOME/bin, if missing
#   install               interLink SPLIT_IL_VERSION (release binaries) and REVERSE_IL_VERSION (built from
#                         the tag when the release has no binaries) into TRIAL_HOME
#   sync                  copy this repository, with the settings, to HPC_REPO_DIR on the login node
#   hpc <command>         run hpc-side.sh <command> on the login node;  login: a shell there
#   mode split|reverse    switch both sides to that mode: hpc-side.sh on the login node over ssh, then
#                         interLink, the artifact repository and offload here. Next: 'test'
#   executor-image        the argoexec image Argo puts in every pod (must be pre-pulled on Deucalion)
#   api direct|relay      split: start interLink with that API address for offloaded containers:
#                         direct = K8S_API_HOST, relay = the relay on the login node
#   api reverse           reverse: start interLink 0.6.3 with the reverse tunnel of its ssh shadow
#   api off               stop interLink here; reverse: delete the shadow's credentials and Service
#   minio on|off          with GS_ENDPOINT=cluster: a MinIO inside the cluster as the Global Storage (the
#                         Service GS_SERVICE in ARGO_NAMESPACE); only reverse can use it
#   artifacts             make the Global Storage Argo's default artifact repository in ARGO_NAMESPACE
#                         (as the mode that is on needs it), apply the test module library, upload the
#                         test datasets (backs up what exists)
#   offload on|off        send every workflow's pods to the interLink node (Argo workflowDefaults), so
#                         the test workflows stay plain Argo; off restores the previous defaults
#   relay-health          split: is the login-node relay reachable through our tunnel?  relay-log: agent log
#   diag                  interLink's processes and logs; reverse: shadow pods and their logs
#   reset-data            put the test data in the Global Storage back as in tests/datasets, without
#                         results of earlier runs ('test' does this first)
#   test [NN ...]         run tests/argo-native (default: all) and check results in Argo AND in the
#                         Global Storage; results in ./results/<time>-<mode>/
#   evidence [run]        collect what shows how a run ran (default: the last) into results/<run>/evidence:
#                         configuration, versions, interLink's and the sidecar's logs of the run (secrets
#                         blanked, then checked), Slurm's record of the jobs
#   clean                 delete the trial's workflows (interLink then removes their job folders)
#   restore               offload off, the login node's mode and sidecar off, interLink stopped, the
#                         virtual node deleted, saved artifact repository back. Argo and TRIAL_HOME stay.
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
NS="$ARGO_NAMESPACE"
NODE="$INTERLINK_NODE_NAME"
CM=workflow-controller-configmap
OWNER=deucalion-trial            # app.kubernetes.io/managed-by of what we create

# Everything this script installs or writes on Ulisses.
TRIAL_HOME="${TRIAL_HOME:-$HOME/lisa-trial}"
STATE="$TRIAL_HOME/state"; RUND="$TRIAL_HOME/run"; LOGD="$TRIAL_HOME/log"; CONF="$TRIAL_HOME/conf"
# Private: interLink's verbose logs hold the pods' service-account tokens and the Secrets it passes
# on (the Global Storage keys, base64), and the state folder the login node's pinned host keys.
umask 077
mkdir -p "$STATE" "$RUND" "$LOGD" "$CONF" "$TRIAL_HOME/bin"
chmod 700 "$TRIAL_HOME" "$LOGD" 2>/dev/null; chmod 600 "$LOGD"/*.log 2>/dev/null
export PATH="$TRIAL_HOME/bin:$PATH"
# The virtual kubelet refuses a relative KUBECONFIG.
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
case "$KUBECONFIG" in /*) ;; *) KUBECONFIG="$PWD/$KUBECONFIG";; esac
export KUBECONFIG
# The API address of the kubeconfig, unless the settings name another one.
srv="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"; srv="${srv#https://}"
K8S_API_HOST="${K8S_API_HOST:-${srv%:*}}"
K8S_API_PORT="${K8S_API_PORT:-${srv##*:}}"

# interLink on Ulisses: one folder per version, its own processes, ports that are free on a machine
# other people use too.
SPLIT_IL_VERSION="${SPLIT_IL_VERSION:-0.6.1}"
REVERSE_IL_VERSION="${REVERSE_IL_VERSION:-0.6.3}"
il_dir() { echo "$TRIAL_HOME/interlink-$1"; }
SOCKF="$RUND/interlink.sock"     # interLink API <-> virtual kubelet
TUNNEL_PORT="${TUNNEL_PORT:-5100}"   # local end of the ssh tunnel to the sidecar
SIDECAR_PORT="${SIDECAR_PORT:-4100}" # the sidecar's port on the login node
VK_PORT="${VK_PORT:-5830}"           # the virtual kubelet's HTTPS port (logs); 10250 is the real kubelet's
VK_IP="${VK_IP:-$K8S_API_HOST}"      # the address the API server reaches the virtual kubelet at
SPLIT_API="${SPLIT_API:-relay}"
ARGO_VERSION="${ARGO_VERSION:-v3.7.12}"

# The login node's host key, pinned on first use in our own file.
SSHO=(-o BatchMode=yes -o LogLevel=ERROR -o ServerAliveInterval=30 -i "$SSH_KEY"
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/known_hosts")
# This repository on the login node, where 'mode' runs hpc-side.sh.
HPC_REPO_DIR="${HPC_REPO_DIR:-$HPC_PROJECT_ROOT/lisa-pipeline-runner_ze}"
HPC_DIR="$HPC_REPO_DIR/deploy/deucalion"

# Reverse mode: the shadow's credentials live in the virtual kubelet's namespace, one per virtual node.
SSH_TUNNEL_IMAGE="ghcr.io/interlink-hq/interlink/ssh-tunnel:$REVERSE_IL_VERSION"
RT_NS="${RT_NS:-$NODE}"
RT_KEY=trial-hpc-ssh-key         # Secret: SSH_KEY, for the shadow's ssh to the login node
RT_KNOWN=trial-hpc-known-hosts   # ConfigMap: the login node's host keys
# The tunnel maps names, not IP addresses: the job reaches the Global Storage through a Service name,
# and the Kubernetes API on a port an unprivileged sshd can bind.
GS_SERVICE="${GS_SERVICE:-global-storage}"
# GS_ENDPOINT=cluster: the Global Storage is a MinIO of ours inside the cluster ('minio on'), the
# Service GS_SERVICE in ARGO_NAMESPACE. Ulisses reaches it at the Service's cluster IP, the jobs of
# reverse through the tunnel under its name. The login node cannot reach it, so split cannot use it.
GS_IN_CLUSTER=false
MINIO_IMAGE="${MINIO_IMAGE:-docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z}"
if [ "$GS_ENDPOINT" = cluster ]; then
  GS_IN_CLUSTER=true
  GS_ENDPOINT="$(kubectl -n "$NS" get svc "$GS_SERVICE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null):9000"
fi
GS_HOST="${GS_ENDPOINT%:*}"
case "$GS_ENDPOINT" in *:*) GS_PORT="${GS_ENDPOINT##*:}";; *) [ "${GS_INSECURE:-true}" = true ] && GS_PORT=80 || GS_PORT=443;; esac
GS_FQDN="$GS_SERVICE.$NS.svc.cluster.local"
FORWARDS="$GS_FQDN:$GS_PORT 6443:kubernetes.default.svc.cluster.local:443"

say()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
info() { printf 'INFO  %s\n' "$*"; }
# mc's alias for the Global Storage. mc retries for minutes when the endpoint does not answer, so
# check that something answers there first, and give up after 30 s.
gs() {
  local scheme=https; [ "${GS_INSECURE:-true}" = true ] && scheme=http
  if [ "$GS_IN_CLUSTER" = true ] && [ "$GS_HOST" = "" ]; then say "ERROR: GS_ENDPOINT=cluster but there is no MinIO yet: run './k8s-side.sh minio on'"; return 1; fi
  curl -s -m 8 -o /dev/null "$scheme://$GS_ENDPOINT/minio/health/live" \
    || { say "ERROR: the Global Storage $GS_ENDPOINT does not answer from $(hostname): is it running, is GS_ENDPOINT right?"; return 1; }
  timeout 30 mc alias set gs "$scheme://$GS_ENDPOINT" "$GS_ACCESS_KEY" "$GS_SECRET_KEY" >/dev/null \
    || { say "ERROR: mc could not log in to $GS_ENDPOINT (GS_ACCESS_KEY, GS_SECRET_KEY)"; return 1; }
}
abs_root() { case "$HPC_PROJECT_ROOT" in /*) return 0;; *) say "ERROR: HPC_PROJECT_ROOT must be an absolute path; it is '$HPC_PROJECT_ROOT'"; return 1;; esac; }
port_free() { ! ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}' | grep -q "[:.]$1\$"; }
# The API server's CA, from the kubeconfig (embedded or as a file).
cluster_ca() {
  kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
    | base64 -d >"$STATE/cluster-ca.crt" 2>/dev/null
  [ -s "$STATE/cluster-ca.crt" ] && echo "$STATE/cluster-ca.crt"
}
node_ready() { kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
wait_ready() {
  local i; for i in $(seq 1 48); do [ "$(node_ready)" = True ] && { say "$NODE Ready"; return 0; }; sleep 5; done
  say "ERROR: $NODE not Ready after 4 minutes; last lines of $LOGD/il-vk.log:"; tail -n 15 "$LOGD/il-vk.log"; return 1
}
executor_image() {
  local img
  img="$(kubectl -n argo get deploy workflow-controller -o json 2>/dev/null \
    | jq -r '.spec.template.spec.containers[0].args // [] | . as $a
             | (index("--executor-image") // -1) as $i | if $i >= 0 then $a[$i+1] else empty end')"
  if [ -z "$img" ]; then
    img="$(kubectl -n argo get deploy workflow-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
      | sed 's#workflow-controller#argoexec#')"
  fi
  echo "$img"
}

# Long-running processes without systemd (no root, and no linger for user services on Ulisses): each in
# its own session, restarted 5 s after it exits, output appended to LOGD/<name>.log. They survive the
# end of the ssh session that started them.
proc_start() { # name command [args...]
  local n="$1"; shift
  proc_stop "$n"
  ( cd "$TRIAL_HOME" && export LOGF="$LOGD/$n.log" && exec setsid bash -c \
      'while :; do "$@" >>"$LOGF" 2>&1 & wait $!; rc=$?; echo "$(date -Is) exited with $rc, restarting in 5 s" >>"$LOGF"; sleep 5; done' \
      "$n" "$@" </dev/null >/dev/null 2>&1 ) &
  echo $! >"$RUND/$n.pid"
}
proc_stop() {
  local p; p="$(cat "$RUND/$1.pid" 2>/dev/null)" || return 0
  kill -TERM -- "-$p" 2>/dev/null; sleep 1; kill -KILL -- "-$p" 2>/dev/null; rm -f "$RUND/$1.pid"; return 0
}
proc_up() { local p; p="$(cat "$RUND/$1.pid" 2>/dev/null)" && kill -0 "$p" 2>/dev/null; }
PROCS="il-tunnel il-api il-vk relay-tunnel relay-agent"

k8s_mode() { local m v; if [ -f "$STATE/mode" ] && read -r m v <"$STATE/mode"; then echo "$m"; else echo none; fi; }
il_version() { local m v; if [ -f "$STATE/mode" ] && read -r m v <"$STATE/mode"; then echo "$v"; else echo none; fi; }
# hpc-side.sh on the login node, over the same ssh as the rest of this script. A login shell, so
# Slurm and Singularity are on the PATH as in an interactive session.
hpc() {
  ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" \
    "SPLIT_ENV='$HPC_DIR/$(basename "$ENV_FILE")' bash -l '$HPC_DIR/hpc-side.sh' $*"
}
hpc_mode() {
  local m; m="$(hpc mode 2>/dev/null | tail -n 1)"
  case "$m" in split|reverse|none) echo "$m";; *) echo "unknown (no up-to-date copy of this repository in $HPC_DIR on the login node? run 'sync')";; esac
}
gs_endpoint() { if [ "$(k8s_mode)" = reverse ]; then echo "$GS_FQDN:$GS_PORT"; else echo "$GS_ENDPOINT"; fi; }
# Our Slurm jobs as name|id|partition|nodes|state: squeue keeps finished jobs for a few minutes,
# sacct (where the site keeps accounting) for longer.
hpc_jobs() {
  ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" \
    "bash -lc 'squeue --me -h -t all -o \"%j|%i|%P|%N|%T\" 2>/dev/null; sacct -X -n -P -S now-2days -o JobName,JobID,Partition,NodeList,State 2>/dev/null'" 2>/dev/null
}

# The two configuration files of interLink, written from the settings for one configuration:
# split-direct, split-relay or reverse. The base is Isabel's (setup/kubernetes/3-bridge.sh) with our paths.
il_config() {
  cat >"$CONF/InterLinkConfig.yaml" <<YAML
InterlinkAddress: "unix://$SOCKF"
InterlinkPort: ""
SidecarURL: "http://127.0.0.1"
SidecarPort: "$TUNNEL_PORT"
VerboseLogging: true
ErrorsOnlyLogging: false
DataRootFolder: "$TRIAL_HOME/data/"
YAML
  {
    cat <<YAML
InterlinkURL: "unix://$SOCKF"
InterlinkPort: ""
VerboseLogging: true
ErrorsOnlyLogging: false
NodeName: "$NODE"
YAML
    case "$1" in
      split-direct) printf 'KubernetesApiAddr: "%s"\nKubernetesApiPort: "%s"\n' "$K8S_API_HOST" "$K8S_API_PORT" ;;
      split-relay)
        printf 'KubernetesApiAddr: "127.0.0.1"\nKubernetesApiPort: "%s"\nKubernetesApiCaCrt: |\n' "$RELAY_API_PORT"
        sed 's/^/  /' "$STATE/relay-ca.crt" ;;
      reverse) cat <<YAML
Namespace: "$RT_NS"
KubernetesApiAddr: "kubernetes.default.svc.cluster.local"
KubernetesApiPort: "6443"
Network:
  EnableTunnel: true
  ShadowMode: "ssh"
  SSH:
    LoginHost: "$HPC_LOGIN_HOST"
    User: "$HPC_USER"
    KeySecret: "$RT_KEY"
    KnownHostsConfigMap: "$RT_KNOWN"
    Image: "$SSH_TUNNEL_IMAGE"
    Reverse:
      Enabled: true
      NodeExec: "srun"
      Sshd: "userspace"
YAML
        ;;
    esac
  } >"$CONF/VirtualKubeletConfig.yaml"
}
# Start interLink here for one configuration: the ssh tunnel to the sidecar, the API, the virtual kubelet.
il_up() {
  local cfg="$1" v d
  case "$cfg" in reverse) v="$REVERSE_IL_VERSION";; *) v="$SPLIT_IL_VERSION";; esac
  d="$(il_dir "$v")"
  [ -x "$d/interlink" ] && [ -x "$d/virtual-kubelet" ] || { say "ERROR: interLink $v not in $d: run './k8s-side.sh install'"; return 1; }
  il_down
  il_config "$cfg"
  proc_start il-tunnel ssh -N "${SSHO[@]}" -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:$TUNNEL_PORT:127.0.0.1:$SIDECAR_PORT" "$HPC_USER@$HPC_LOGIN_HOST"
  proc_start il-api env INTERLINKCONFIGPATH="$CONF/InterLinkConfig.yaml" "$d/interlink"
  sleep 3
  proc_start il-vk env KUBECONFIG="$KUBECONFIG" KUBELET_PORT="$VK_PORT" POD_IP="$VK_IP" \
    "$d/virtual-kubelet" --nodename "$NODE" --configpath "$CONF/VirtualKubeletConfig.yaml"
  echo "${cfg%%-*} $v" >"$STATE/mode"
  wait_ready || return 1
  say "interLink $v up ($cfg); logs in $LOGD"
}
il_down() { local n; for n in il-vk il-api il-tunnel relay-agent relay-tunnel; do proc_stop "$n"; done; rm -f "$SOCKF" "$STATE/mode"; }

gs_service() { # on|off: the Global Storage under a Service name in ARGO_NAMESPACE, for the tunnel
  local mine
  [ "$GS_IN_CLUSTER" = true ] && return 0   # the MinIO in the cluster is that Service already
  if [ "$1" = off ]; then
    kubectl -n "$NS" delete svc,endpointslice -l "app.kubernetes.io/managed-by=$OWNER" --ignore-not-found >/dev/null
    return
  fi
  if kubectl -n "$NS" get svc "$GS_SERVICE" >/dev/null 2>&1; then
    mine="$(kubectl -n "$NS" get svc "$GS_SERVICE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
    [ "$mine" = "$OWNER" ] || { say "ERROR: Service $NS/$GS_SERVICE exists and is not ours: set GS_SERVICE to another name"; return 1; }
  fi
  if [[ "$GS_HOST" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata:
  name: $GS_SERVICE
  namespace: $NS
  labels: {app.kubernetes.io/managed-by: $OWNER}
spec:
  ports: [{name: s3, port: $GS_PORT, targetPort: $GS_PORT}]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: $GS_SERVICE-1
  namespace: $NS
  labels: {kubernetes.io/service-name: $GS_SERVICE, app.kubernetes.io/managed-by: $OWNER}
addressType: IPv4
ports: [{name: s3, port: $GS_PORT}]
endpoints: [{addresses: ["$GS_HOST"]}]
YAML
  else
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata:
  name: $GS_SERVICE
  namespace: $NS
  labels: {app.kubernetes.io/managed-by: $OWNER}
spec:
  type: ExternalName
  externalName: $GS_HOST
  ports: [{name: s3, port: $GS_PORT}]
YAML
  fi
}
shadow_credentials_off() {
  local kind name ns
  for kind in secret configmap; do
    if [ "$kind" = secret ]; then name="$RT_KEY"; else name="$RT_KNOWN"; fi
    kubectl -n "$RT_NS" delete "$kind" "$name" --ignore-not-found >/dev/null
    # The virtual kubelet copies them into every shadow namespace (Network.SSH.ReplicateCredentials).
    for ns in $(kubectl get "$kind" -A -o json | jq -r --arg n "$name" \
        '.items[] | select(.metadata.name == $n and .metadata.annotations["interlink.eu/replicated-from"] != null) | .metadata.namespace'); do
      kubectl -n "$ns" delete "$kind" "$name" --ignore-not-found >/dev/null && say "deleted $kind $ns/$name (interLink's copy)"
    done
  done
}
# A pod with the shadow image that reads the login node's ssh banner: what every shadow does first.
probe_shadow() {
  local out
  kubectl -n "$RT_NS" delete pod trial-shadow-probe --ignore-not-found >/dev/null 2>&1
  out="$(timeout 300 kubectl -n "$RT_NS" run trial-shadow-probe --rm -i --quiet --restart=Never \
    --image="$SSH_TUNNEL_IMAGE" --image-pull-policy=IfNotPresent --command -- ssh-keyscan -T 10 "$HPC_LOGIN_HOST" 2>&1)"
  kubectl -n "$RT_NS" delete pod trial-shadow-probe --ignore-not-found --wait=false >/dev/null 2>&1
  if printf '%s\n' "$out" | grep -q -E 'SSH-2\.0|ssh-ed25519|ssh-rsa|ecdsa-sha2'; then pass "a pod on this cluster reaches the sshd of $HPC_LOGIN_HOST (as the shadow will)"
  else fail "a pod on this cluster does not reach the sshd of $HPC_LOGIN_HOST: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; fi
}

case "${1:-}:${2:-}" in
  check:|check:split|check:reverse)
    want="${2:-both}"
    FAILED=0
    say "== Ulisses $(hostname), user $(id -un), TRIAL_HOME $TRIAL_HOME"
    for v in HPC_LOGIN_HOST HPC_USER HPC_PROJECT_ROOT SLURM_ACCOUNT SLURM_PARTITION SSH_KEY INTERLINK_NODE_NAME ARGO_NAMESPACE GS_ENDPOINT GS_BUCKET; do
      [ -n "${!v}" ] || fail "$v is empty in $ENV_FILE"
    done
    abs_root >/dev/null && pass "HPC_PROJECT_ROOT $HPC_PROJECT_ROOT" || fail "HPC_PROJECT_ROOT must be an absolute path; it is '$HPC_PROJECT_ROOT'"
    [ -r "$SSH_KEY" ] && pass "SSH_KEY $SSH_KEY readable" || fail "SSH_KEY $SSH_KEY not readable"
    for t in kubectl jq curl ssh ssh-keyscan setsid openssl git tar; do command -v "$t" >/dev/null && pass "found $t" || fail "missing $t"; done
    for t in argo mc; do command -v "$t" >/dev/null && pass "found $t ($(command -v "$t"))" || fail "missing $t: run './k8s-side.sh tools'"; done
    [ "$(kubectl auth can-i '*' '*' 2>/dev/null)" = yes ] && pass "kubeconfig $KUBECONFIG has cluster-admin" \
      || fail "kubeconfig $KUBECONFIG does not reach the cluster with cluster-admin (kubectl get nodes)"
    [ -n "$(cluster_ca)" ] && pass "cluster CA taken from the kubeconfig" || fail "no certificate-authority in $KUBECONFIG"
    if kubectl -n argo get deploy workflow-controller >/dev/null 2>&1; then
      pass "Argo controller found ($(executor_image))"
      [ "$(executor_image)" = "$ARGO_EXEC_IMAGE" ] && pass "ARGO_EXEC_IMAGE matches the controller's" \
        || fail "ARGO_EXEC_IMAGE ($ARGO_EXEC_IMAGE) differs from the controller's ($(executor_image))"
    else info "no Argo in namespace argo yet: run './k8s-side.sh argo'"; fi
    kubectl get ns "$NS" >/dev/null 2>&1 && pass "namespace $NS exists" || info "namespace $NS not there yet ('argo' creates it)"
    [ -n "$GS_ACCESS_KEY" ] && [ -n "$GS_SECRET_KEY" ] && pass "Global Storage keys set" || fail "GS_ACCESS_KEY or GS_SECRET_KEY empty in $ENV_FILE"
    [ -d "$DATASETS" ] && pass "test datasets in $DATASETS" || fail "no $DATASETS"
    ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" true 2>/dev/null && pass "ssh to $HPC_USER@$HPC_LOGIN_HOST with $SSH_KEY" \
      || fail "ssh to $HPC_USER@$HPC_LOGIN_HOST with $SSH_KEY failed"
    # Both modes: the tests reset the data and check the results from here.
    if ! command -v mc >/dev/null; then :
    elif out="$(gs)"; then
      timeout 30 mc ls "gs/$GS_BUCKET" >/dev/null 2>&1 && pass "Global Storage bucket $GS_BUCKET reachable from here" \
        || info "Global Storage $GS_ENDPOINT answers, bucket $GS_BUCKET missing ('artifacts' creates it)"
    else fail "${out#ERROR: }"; fi
    for p in "$TUNNEL_PORT" "$VK_PORT"; do
      if port_free "$p"; then pass "port $p free here"
      elif proc_up il-tunnel || proc_up il-vk; then info "port $p in use, by our interLink"
      else fail "port $p already in use on this machine: pick another (TUNNEL_PORT, VK_PORT)"; fi
    done
    if kubectl get node "$NODE" >/dev/null 2>&1 && ! proc_up il-vk; then
      info "a node $NODE exists but our virtual kubelet is not running: left by an earlier run, or someone else's (INTERLINK_NODE_NAME)"
    fi
    if kubectl -n "$NS" get cm artifact-repositories >/dev/null 2>&1; then info "namespace $NS already has an artifact-repositories ConfigMap ('artifacts' backs it up)"; fi
    wd="$(kubectl -n argo get cm "$CM" -o json 2>/dev/null | jq -r '.data.workflowDefaults // empty')"
    [ -n "$wd" ] && info "Argo already has workflowDefaults ('offload' backs them up)" || info "Argo has no workflowDefaults"
    info "mode on: Ulisses $(k8s_mode) (interLink $(il_version)), login node $(hpc_mode)"

    if [ "$want" != reverse ]; then
      say "== split (interLink $SPLIT_IL_VERSION + split executor)"
      d="$(il_dir "$SPLIT_IL_VERSION")"
      [ -x "$d/virtual-kubelet" ] && pass "interLink $SPLIT_IL_VERSION installed in $d" || info "interLink $SPLIT_IL_VERSION not installed yet: run './k8s-side.sh install'"
      [ -f "$RELAYBIN" ] && pass "relay binary $RELAYBIN" || fail "no $RELAYBIN"
      # Offloaded containers (direct) and the relay agent (relay) call the API at K8S_API_HOST, so the
      # API server's certificate must be valid for that address.
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$STATE/cluster-ca.crt" "https://$K8S_API_HOST:$K8S_API_PORT/version")"
      case "$code" in
        200|401|403) pass "Kubernetes API at $K8S_API_HOST:$K8S_API_PORT, certificate valid for that address" ;;
        *) fail "no Kubernetes API with a valid certificate at $K8S_API_HOST:$K8S_API_PORT (K8S_API_HOST; the kubeconfig says $srv)" ;;
      esac
      port_free "$RELAY_CTL_PORT" || proc_up relay-tunnel && pass "port $RELAY_CTL_PORT free here (relay tunnel)" \
        || fail "port $RELAY_CTL_PORT already in use on this machine: pick other RELAY_*_PORT values"
      [ "$GS_IN_CLUSTER" = true ] && fail "GS_ENDPOINT=cluster: the login node cannot reach a MinIO inside the cluster, so split cannot run with it"
    fi
    if [ "$want" != split ]; then
      say "== reverse (interLink $REVERSE_IL_VERSION + reverse tunnel)"
      d="$(il_dir "$REVERSE_IL_VERSION")"
      if [ -x "$d/interlink" ] && [ -x "$d/virtual-kubelet" ]; then pass "interLink $REVERSE_IL_VERSION installed in $d"
      else info "interLink $REVERSE_IL_VERSION not installed yet: 'install' builds it (needs internet, git and about 1 GB free)"; fi
      [ "$GS_PORT" -ge 1024 ] 2>/dev/null && pass "Global Storage port $GS_PORT can be bound by the job's unprivileged sshd" \
        || fail "Global Storage port $GS_PORT is below 1024: the job's sshd cannot bind it"
      if kubectl -n "$NS" get svc "$GS_SERVICE" >/dev/null 2>&1 \
         && [ "$(kubectl -n "$NS" get svc "$GS_SERVICE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" != "$OWNER" ]; then
        fail "Service $NS/$GS_SERVICE exists and is not ours: set GS_SERVICE to another name"
      else pass "Service name $GS_FQDN free (or ours) for the Global Storage"; fi
      if openssl s_client -connect "$K8S_API_HOST:$K8S_API_PORT" </dev/null 2>/dev/null | openssl x509 -noout -text 2>/dev/null \
         | grep -q 'kubernetes.default.svc.cluster.local'; then
        pass "API server certificate valid for kubernetes.default.svc.cluster.local (the name jobs use through the tunnel)"
      else info "could not confirm that the API server's certificate names kubernetes.default.svc.cluster.local"; fi
      [ -n "$(ssh-keyscan -T 10 "$HPC_LOGIN_HOST" 2>/dev/null)" ] && pass "ssh-keyscan $HPC_LOGIN_HOST works (pins the login node's key for the shadow)" \
        || fail "ssh-keyscan $HPC_LOGIN_HOST returned nothing"
    fi
    exit "$FAILED"
    ;;

  status:)
    say "== Ulisses: mode $(k8s_mode), interLink $(il_version), $NODE Ready=$(node_ready)"
    for p in $PROCS; do proc_up "$p" && say "   $p: running (log $LOGD/$p.log)"; done
    [ "$GS_IN_CLUSTER" = true ] && say "   Global Storage: MinIO in the cluster, $(kubectl -n "$NS" get deploy lisa-minio -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)/1 ready at $GS_ENDPOINT"
    say "   artifact repository endpoint: $(kubectl -n "$NS" get cm artifact-repositories -o jsonpath='{.data.default-v1}' 2>/dev/null | sed -n 's/^ *endpoint: *//p')"
    wd="$(kubectl -n argo get cm "$CM" -o json 2>/dev/null | jq -r '.data.workflowDefaults // ""')"
    case "$wd" in *"$NODE"*) o=on;; *) o=off;; esac
    case "$wd" in *reverse-forwards*) o="$o, with reverse-forwards";; esac
    say "   offload: $o"
    say "== login node $HPC_LOGIN_HOST:"
    hpc status 2>&1 | sed 's/^/   /'
    ;;

  mode:split|mode:reverse)
    m="$2"
    step() { say "-- $*"; "$@" || { say "ERROR in: $*"; say "Fix it and run './k8s-side.sh mode $m' again: every step can be repeated. './k8s-side.sh status' shows where each side is."; exit 1; }; }
    hm="$(hpc_mode)"
    case "$hm" in split|reverse|none) ;; *) say "ERROR: login node: $hm"; exit 1;; esac
    kubectl -n argo get deploy workflow-controller >/dev/null 2>&1 || { say "ERROR: no Argo: run './k8s-side.sh argo' first"; exit 1; }
    say "== switching both sides to '$m' (now: Ulisses $(k8s_mode), login node $hm)"
    step bash "$0" offload off
    # The login node first: the virtual node only becomes Ready when the plugin answers. 'install' and
    # 'enable' run even when done before, so running 'mode' again repairs a half-done switch.
    [ "$hm" = "$m" ] || [ "$hm" = none ] || step hpc disable
    step hpc install
    step hpc images
    step hpc enable "$m"
    if [ "$m" = reverse ]; then
      [ -x "$(il_dir "$REVERSE_IL_VERSION")/virtual-kubelet" ] || step bash "$0" install
      step bash "$0" api reverse
    else
      [ -x "$(il_dir "$SPLIT_IL_VERSION")/virtual-kubelet" ] || step bash "$0" install
      if [ "$SPLIT_API" = direct ]; then
        step bash "$0" api direct
      else
        step hpc relay on
        step bash "$0" api relay
      fi
    fi
    step bash "$0" artifacts
    step bash "$0" offload on
    say "== both sides in '$m'. Next: ./k8s-side.sh test 00"
    ;;

  executor-image:) executor_image ;;

  argo:)
    if kubectl -n argo get deploy workflow-controller >/dev/null 2>&1; then
      say "Argo already installed in namespace argo ($(executor_image)): not touched"
    else
      kubectl get ns argo >/dev/null 2>&1 || kubectl create ns argo >/dev/null
      kubectl apply -n argo -f "https://github.com/argoproj/argo-workflows/releases/download/$ARGO_VERSION/install.yaml" >/dev/null \
        || { say "ERROR: could not apply Argo $ARGO_VERSION"; exit 1; }
      kubectl -n argo rollout status deploy/workflow-controller --timeout=300s || exit 1
      say "Argo $ARGO_VERSION installed in namespace argo"
    fi
    # The namespace the test workflows run in, and what Argo's executor needs there: its pods run as the
    # namespace's default service account (Isabel's argo-workflow-role, setup/kubernetes/2-argo.sh).
    kubectl get ns "$NS" >/dev/null 2>&1 || { kubectl create ns "$NS" >/dev/null && kubectl label ns "$NS" "app.kubernetes.io/managed-by=$OWNER" >/dev/null; }
    kubectl apply -f - >/dev/null <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argo-workflow-role
  namespace: $NS
  labels: {app.kubernetes.io/managed-by: $OWNER}
rules:
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get", "list", "watch", "create", "delete", "patch"]
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["argoproj.io"]
  resources: ["workflows", "workflowtemplates", "workflowtaskresults"]
  verbs: ["get", "list", "watch", "create", "delete", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argo-workflow-rolebinding
  namespace: $NS
  labels: {app.kubernetes.io/managed-by: $OWNER}
subjects:
- kind: ServiceAccount
  name: default
  namespace: $NS
roleRef:
  kind: Role
  name: argo-workflow-role
  apiGroup: rbac.authorization.k8s.io
YAML
    say "namespace $NS ready for the test workflows; argoexec image: $(executor_image)"
    [ "$(executor_image)" = "$ARGO_EXEC_IMAGE" ] || say "NOTE: set ARGO_EXEC_IMAGE=$(executor_image) in $(basename "$ENV_FILE"), then 'sync'"
    ;;

  tools:)
    case "$(uname -m)" in aarch64|arm64) a=arm64;; *) a=amd64;; esac
    bin="$TRIAL_HOME/bin"
    if command -v argo >/dev/null; then say "argo: $(command -v argo)"
    else
      # The CLI of the controller's version (the tag of its argoexec image).
      v="$(executor_image)"; v="${v##*:}"; [ -n "$v" ] || v="$ARGO_VERSION"
      curl -fsSL "https://github.com/argoproj/argo-workflows/releases/download/$v/argo-linux-$a.gz" | gunzip >"$bin/argo.dl" \
        && chmod 0755 "$bin/argo.dl" && mv -f "$bin/argo.dl" "$bin/argo" || { rm -f "$bin/argo.dl"; say "ERROR: download of argo $v failed"; exit 1; }
      say "argo $v: $bin/argo"
    fi
    if command -v mc >/dev/null; then say "mc: $(command -v mc)"
    else
      # dl.min.io no longer serves mc (HTTP 410 since late 2025): the pgsty fork publishes it as mcli.
      u="https://github.com/pgsty/mc/releases/download/RELEASE.2026-11-12T00-00-00Z/mcli_20261112000000.0.0_linux_$a.tar.gz"
      curl -fsSL "$u" | tar -xzO mcli >"$bin/mc.dl" && chmod 0755 "$bin/mc.dl" && mv -f "$bin/mc.dl" "$bin/mc" \
        || { rm -f "$bin/mc.dl"; say "ERROR: download of mc failed: $u"; exit 1; }
      say "mc: $bin/mc"
    fi
    ;;

  install:)
    case "$(uname -m)" in aarch64|arm64) arch=arm64; goarch=arm64;; *) arch=x86_64; goarch=amd64;; esac
    for v in "$SPLIT_IL_VERSION" "$REVERSE_IL_VERSION"; do
      d="$(il_dir "$v")"; mkdir -p "$d"
      base="https://github.com/interlink-hq/interLink/releases/download/$v"
      if [ -x "$d/interlink" ] && [ -x "$d/virtual-kubelet" ]; then
        say "interLink $v already in $d"
      elif curl -fsSL --retry 3 -o "$d/interlink.dl" "$base/interlink_Linux_$arch" \
           && curl -fsSL --retry 3 -o "$d/virtual-kubelet.dl" "$base/virtual-kubelet_Linux_$arch"; then
        mv "$d/interlink.dl" "$d/interlink"; mv "$d/virtual-kubelet.dl" "$d/virtual-kubelet"
        chmod 0755 "$d/interlink" "$d/virtual-kubelet"
        say "interLink $v: release binaries in $d"
      else
        # The 0.6.3 release was published without binaries: build them from the tag, with a Go of the
        # version its go.mod asks for, all inside TRIAL_HOME.
        rm -f "$d"/*.dl
        say "interLink $v: no release binaries, building from the tag (a few minutes)"
        src="$TRIAL_HOME/src/interlink-$v"
        rm -rf "$src"; mkdir -p "$TRIAL_HOME/src"
        git -c advice.detachedHead=false clone -q --depth 1 --branch "$v" https://github.com/interlink-hq/interLink.git "$src" || { say "ERROR: git clone failed"; exit 1; }
        gov="$(awk '/^go /{print $2; exit}' "$src/go.mod")"; case "$gov" in *.*.*) ;; *) gov="$gov.0";; esac
        goroot="$TRIAL_HOME/go-$gov"
        if [ ! -x "$goroot/bin/go" ]; then
          curl -fsSL --retry 3 -o "$TRIAL_HOME/go.tgz" "https://go.dev/dl/go$gov.linux-$goarch.tar.gz" || { say "ERROR: download of Go $gov failed"; exit 1; }
          rm -rf "$goroot"; mkdir -p "$goroot"
          tar xzf "$TRIAL_HOME/go.tgz" -C "$goroot" --strip-components=1; rm -f "$TRIAL_HOME/go.tgz"
        fi
        ( cd "$src" && export PATH="$goroot/bin:$PATH" GOTOOLCHAIN=local CGO_ENABLED=0 GOFLAGS=-mod=mod \
            GOPATH="$TRIAL_HOME/gopath" GOCACHE="$TRIAL_HOME/gocache" \
          && go build -o "$d/interlink" ./cmd/interlink && go build -o "$d/virtual-kubelet" ./cmd/virtual-kubelet ) \
          || { rm -f "$d/interlink" "$d/virtual-kubelet"; say "ERROR: build failed"; exit 1; }
        chmod 0755 "$d/interlink" "$d/virtual-kubelet"
        say "interLink $v built with Go $gov in $d"
      fi
    done
    say "The shadow image ($SSH_TUNNEL_IMAGE) is pulled by the kubelet when 'api reverse' runs its probe pod."
    ;;

  sync:)
    # Everything but the results and the settings, then the settings without the Global Storage keys:
    # hpc-side.sh does not use them, and HPC_PROJECT_ROOT may be a folder other people can read.
    abs_root || exit 1
    envname="$(basename "$ENV_FILE")"
    # Only what hpc-side.sh uses, and no settings file: a copy such as deucalion.env.old holds the keys.
    tar -C "$ZE" --exclude=./deploy/deucalion/results --exclude='./deploy/deucalion/*.env*' -cz ./deploy/deucalion ./setup/hpc \
      | ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" "mkdir -p '$HPC_REPO_DIR' && tar -xzm -C '$HPC_REPO_DIR' && rm -f '$HPC_DIR'/*.env.*" \
      || { say "ERROR: copy to $HPC_USER@$HPC_LOGIN_HOST:$HPC_REPO_DIR failed"; exit 1; }
    # The API and Global Storage addresses as used here (the API from the kubeconfig unless set):
    # hpc-side.sh checks whether the login node reaches them.
    { grep -v -E '^GS_(ACCESS|SECRET)_KEY=' "$ENV_FILE"
      printf '\n# added by k8s-side.sh sync\nK8S_API_HOST=%s\nK8S_API_PORT=%s\n' "$K8S_API_HOST" "$K8S_API_PORT"
      [ "$GS_IN_CLUSTER" = true ] && printf 'GS_ENDPOINT=%s   # the MinIO in the cluster\n' "$GS_ENDPOINT"; } \
      | ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" "umask 077 && cat >'$HPC_DIR/$envname'" \
      || { say "ERROR: copy of the settings failed"; exit 1; }
    say "copied to $HPC_REPO_DIR on $HPC_LOGIN_HOST (settings without the Global Storage keys); login node mode: $(hpc_mode)"
    ;;
  hpc:*) shift; hpc "$@" ;;
  login:) exec ssh -t "${SSHO[@]/BatchMode=yes/BatchMode=no}" "$HPC_USER@$HPC_LOGIN_HOST" "cd '$HPC_DIR' && exec bash -l" ;;

  minio:on)
    # A Global Storage inside the cluster, for when no external one is reachable. Data in an emptyDir:
    # the tests put back their own data before every run ('reset-data').
    [ "$GS_IN_CLUSTER" = true ] || { say "ERROR: set GS_ENDPOINT=cluster in $(basename "$ENV_FILE") to use a MinIO in the cluster"; exit 1; }
    [ "${#GS_ACCESS_KEY}" -ge 3 ] && [ "${#GS_SECRET_KEY}" -ge 8 ] \
      || { say "ERROR: GS_ACCESS_KEY (3 or more characters) and GS_SECRET_KEY (8 or more) become this MinIO's credentials: set them"; exit 1; }
    kubectl get ns "$NS" >/dev/null 2>&1 || { say "ERROR: no namespace $NS: run './k8s-side.sh argo' first"; exit 1; }
    kubectl -n "$NS" create secret generic lisa-minio-root \
      --from-literal=MINIO_ROOT_USER="$GS_ACCESS_KEY" --from-literal=MINIO_ROOT_PASSWORD="$GS_SECRET_KEY" --dry-run=client -o yaml \
      | kubectl label --local -f - -o yaml "app.kubernetes.io/managed-by=$OWNER" | kubectl apply -f - >/dev/null
    kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lisa-minio
  namespace: $NS
  labels: {app: lisa-minio, app.kubernetes.io/managed-by: $OWNER}
spec:
  replicas: 1
  selector: {matchLabels: {app: lisa-minio}}
  template:
    metadata:
      labels: {app: lisa-minio}
    spec:
      containers:
      - name: minio
        image: $MINIO_IMAGE
        args: ["server", "/data", "--console-address", ":9001"]
        envFrom: [{secretRef: {name: lisa-minio-root}}]
        ports: [{containerPort: 9000}]
        readinessProbe: {httpGet: {path: /minio/health/ready, port: 9000}, periodSeconds: 5}
        volumeMounts: [{name: data, mountPath: /data}]
      volumes: [{name: data, emptyDir: {sizeLimit: 20Gi}}]
---
apiVersion: v1
kind: Service
metadata:
  name: $GS_SERVICE
  namespace: $NS
  labels: {app: lisa-minio, app.kubernetes.io/managed-by: $OWNER}
spec:
  selector: {app: lisa-minio}
  ports: [{name: s3, port: 9000, targetPort: 9000}]
YAML
    kubectl -n "$NS" rollout status deploy/lisa-minio --timeout=300s || { say "ERROR: MinIO did not start: kubectl -n $NS describe pod -l app=lisa-minio"; exit 1; }
    ip="$(kubectl -n "$NS" get svc "$GS_SERVICE" -o jsonpath='{.spec.clusterIP}')"
    say "MinIO ($MINIO_IMAGE) in $NS: $ip:9000 from Ulisses, $GS_FQDN:9000 for the jobs of reverse"
    GS_ENDPOINT="$ip:9000"; GS_HOST="$ip"
    # The pod is ready before kube-proxy routes the new Service: until then it refuses connections.
    for _ in $(seq 1 30); do curl -s -m 3 -o /dev/null "http://$GS_ENDPOINT/minio/health/live" && break; sleep 2; done
    gs && mc mb -p "gs/$GS_BUCKET" >/dev/null && say "bucket $GS_BUCKET ready"
    ;;
  minio:off)
    kubectl -n "$NS" delete deploy/lisa-minio svc/"$GS_SERVICE" secret/lisa-minio-root --ignore-not-found >/dev/null
    say "MinIO in $NS deleted, with its data"
    ;;

  artifacts:)
    [ -f "$N/modules.yaml" ] || { say "ERROR: $N missing"; exit 1; }
    gs || exit 1
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
    # split: init and wait reach it from the login node; reverse: from the compute node, through the
    # tunnel, under the Service name.
    ep="$(gs_endpoint)"
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
      endpoint: $ep
      insecure: ${GS_INSECURE:-true}
      accessKeySecret:
        name: split-gs-creds
        key: accesskey
      secretKeySecret:
        name: split-gs-creds
        key: secretkey
YAML
    kubectl apply -n "$NS" -f "$N/modules.yaml" >/dev/null
    say "artifact repository ($(k8s_mode)): s3://$GS_BUCKET at $ep; WorkflowTemplate lisa-modules applied in $NS"
    bash "$0" reset-data
    ;;

  reset-data:)
    # Results of an earlier run would make the object checks pass without this run having written them.
    [ -d "$DATASETS" ] || { say "ERROR: $DATASETS missing"; exit 1; }
    gs || exit 1
    mc rm --recursive --force "gs/$GS_BUCKET/users" >/dev/null 2>&1 || true
    mc rm --recursive --force "gs/$GS_BUCKET/t1" >/dev/null 2>&1 || true
    mc mirror --overwrite "$DATASETS" "gs/$GS_BUCKET/users" >/dev/null || { say "ERROR: upload to $GS_BUCKET failed"; exit 1; }
    printf 'hello from the global storage\n' | mc pipe "gs/$GS_BUCKET/t1/input.txt" >/dev/null
    say "Global Storage reset: $GS_BUCKET/users = tests/datasets, $GS_BUCKET/t1/input.txt"
    ;;

  offload:on)
    # Saved as JSON, so 'off' can tell "absent" (null) from any value and put back exactly what was there.
    SAVED="$STATE/workflowDefaults.json"
    [ -f "$SAVED" ] || kubectl -n argo get cm "$CM" -o json | jq '.data.workflowDefaults' >"$SAVED"
    defaults="spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE
  tolerations:
  - key: virtual-node.interlink/no-schedule
    operator: Exists
  podMetadata:
    annotations:
      slurm-job.vk.io/flags: \"--account=$SLURM_ACCOUNT --partition=$SLURM_PARTITION\""
    # reverse: every pod asks for the tunnel to the Global Storage and the Kubernetes API.
    [ "$(k8s_mode)" = reverse ] && defaults="$defaults
      interlink.eu/reverse-forwards: \"$FORWARDS\""
    kubectl -n argo patch cm "$CM" --type merge -p "$(jq -n --arg v "$defaults" '{data: {workflowDefaults: $v}}')" >/dev/null
    sleep 5
    say "offload ON ($(k8s_mode)): every workflow's pods go to $NODE, partition $SLURM_PARTITION"
    say "Note: this applies to ALL workflows of this Argo, other users' too. Switch off after the trial."
    ;;
  offload:off)
    SAVED="$STATE/workflowDefaults.json"
    [ -f "$SAVED" ] || { say "offload already off"; exit 0; }
    if [ "$(cat "$SAVED")" = null ]; then
      kubectl -n argo patch cm "$CM" --type json -p '[{"op":"remove","path":"/data/workflowDefaults"}]' >/dev/null 2>&1 || true
    else
      kubectl -n argo patch cm "$CM" --type merge -p "$(jq -n --slurpfile v "$SAVED" '{data: {workflowDefaults: $v[0]}}')" >/dev/null \
        || { say "ERROR: could not restore workflowDefaults from $SAVED"; exit 1; }
    fi
    rm -f "$SAVED"; sleep 5; say "offload OFF: workflowDefaults restored"
    ;;

  api:direct)
    [ "$(k8s_mode)" = reverse ] && { bash "$0" api off || exit 1; }
    il_up split-direct
    ;;
  api:relay)
    [ "$(k8s_mode)" = reverse ] && { bash "$0" api off || exit 1; }
    [ -x "$RELAYBIN" ] || chmod 0755 "$RELAYBIN" "$(dirname "$RELAYBIN")"/bin/split-relay-linux-* 2>/dev/null
    ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" "cat '$HPC_PROJECT_ROOT/split-executor/relay/ca.crt'" >"$STATE/relay-ca.crt" \
      || { say "ERROR: could not fetch the relay CA (run './k8s-side.sh hpc relay on' first)"; exit 1; }
    ca="$(cluster_ca)" || { say "ERROR: no certificate-authority in $KUBECONFIG"; exit 1; }
    il_up split-relay || exit 1
    # The tunnel is opened from here, like interLink's own: the login node never connects to Ulisses.
    proc_start relay-tunnel ssh -N "${SSHO[@]}" -o ExitOnForwardFailure=yes \
      -L "127.0.0.1:$RELAY_CTL_PORT:127.0.0.1:$RELAY_CTL_PORT" "$HPC_USER@$HPC_LOGIN_HOST"
    proc_start relay-agent "$RELAYBIN" agent --ctl "http://127.0.0.1:$RELAY_CTL_PORT" \
      --api "https://$K8S_API_HOST:$K8S_API_PORT" --ca "$ca"
    bash "$0" relay-health
    ;;
  api:reverse)
    [ -x "$(il_dir "$REVERSE_IL_VERSION")/virtual-kubelet" ] || { say "ERROR: interLink $REVERSE_IL_VERSION not installed: run './k8s-side.sh install' first"; exit 1; }
    [ "$GS_PORT" -ge 1024 ] 2>/dev/null || { say "ERROR: Global Storage port $GS_PORT is below 1024: the job's unprivileged sshd cannot bind it"; exit 1; }
    hm="$(hpc_mode)"
    [ "$hm" = reverse ] || { say "ERROR: the login node is in '$hm', not reverse: run './k8s-side.sh hpc enable reverse' first"; exit 1; }
    kubectl get ns "$RT_NS" >/dev/null 2>&1 || { kubectl create ns "$RT_NS" >/dev/null && touch "$STATE/created-ns-$RT_NS"; }
    # The shadow logs in to the login node as HPC_USER with SSH_KEY, which is why 'api off' deletes it
    # again, with every copy. interLink's docs advise a key for the tunnel only on a real site.
    kubectl -n "$RT_NS" create secret generic "$RT_KEY" --from-file=id_ed25519="$SSH_KEY" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ssh-keyscan -T 10 "$HPC_LOGIN_HOST" 2>/dev/null >"$STATE/reverse-known_hosts"
    [ -s "$STATE/reverse-known_hosts" ] || { say "ERROR: ssh-keyscan of $HPC_LOGIN_HOST failed"; exit 1; }
    # The shadow checks the login node strictly against these keys: make sure ssh accepts them.
    ssh -o BatchMode=yes -o LogLevel=ERROR -i "$SSH_KEY" -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$STATE/reverse-known_hosts" "$HPC_USER@$HPC_LOGIN_HOST" true \
      || { say "ERROR: ssh to $HPC_USER@$HPC_LOGIN_HOST with the scanned host keys failed"; exit 1; }
    kubectl -n "$RT_NS" create configmap "$RT_KNOWN" --from-file=known_hosts="$STATE/reverse-known_hosts" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    gs_service on || exit 1
    il_up reverse || exit 1
    FAILED=0; probe_shadow
    say "reverse ON: offloaded pods reach $GS_FQDN:$GS_PORT and the Kubernetes API through the login node"
    exit "$FAILED"
    ;;
  api:off)
    was="$(k8s_mode)"
    il_down
    if [ "$was" = reverse ]; then
      shadow_credentials_off
      gs_service off
      if [ -f "$STATE/created-ns-$RT_NS" ]; then kubectl delete ns "$RT_NS" --wait=false >/dev/null 2>&1; rm -f "$STATE/created-ns-$RT_NS"; fi
      say "interLink stopped; SSH key Secrets and the Global Storage Service deleted"
    else
      say "interLink stopped"
    fi
    ;;
  relay-health:)
    for _ in $(seq 1 10); do
      out="$(curl -s -m 5 "http://127.0.0.1:$RELAY_CTL_PORT/health" 2>/dev/null)" && [ -n "$out" ] && { say "relay reachable through the tunnel: $out"; exit 0; }
      sleep 2
    done
    say "relay NOT reachable through the tunnel ($LOGD/relay-tunnel.log)"; exit 1
    ;;
  relay-log:) cat "$LOGD/relay-agent.log" 2>/dev/null || say "no agent log" ;;

  diag:)
    say "== mode $(k8s_mode), interLink $(il_version), $NODE Ready=$(node_ready)"
    for p in $PROCS; do if proc_up "$p"; then say "   $p: running"; else say "   $p: not running"; fi; done
    for p in il-tunnel il-api il-vk; do
      say "== $LOGD/$p.log (last 30 lines)"; tail -n 30 "$LOGD/$p.log" 2>/dev/null | cut -c1-300
    done
    say "== shadow pods"; kubectl get pods -A -o wide 2>/dev/null | awk 'NR == 1 || $1 ~ /-shadow$/'
    for p in $(kubectl get pods -A --no-headers 2>/dev/null | awk '$1 ~ /-shadow$/ {print $1 "/" $2}' | tail -n 3); do
      say "== logs $p"; kubectl -n "${p%%/*}" logs "${p#*/}" --all-containers --tail=40 2>&1
    done
    ;;

  test:*)
    shift
    m="$(k8s_mode)"
    # Both sides, the artifact repository and the offload settings must agree on the mode.
    [ "$m" != none ] || { say "ERROR: no mode on here: run './k8s-side.sh mode split|reverse'"; exit 1; }
    hm="$(hpc_mode)"
    [ "$hm" = "$m" ] || { say "ERROR: Ulisses is in '$m' but the login node in '$hm': run './k8s-side.sh mode $m'"; exit 1; }
    ep="$(kubectl -n "$NS" get cm artifact-repositories -o jsonpath='{.data.default-v1}' 2>/dev/null | sed -n 's/^ *endpoint: *//p')"
    [ "$ep" = "$(gs_endpoint)" ] || { say "ERROR: the artifact repository points to '$ep', '$m' needs '$(gs_endpoint)': run './k8s-side.sh artifacts'"; exit 1; }
    wd="$(kubectl -n argo get cm "$CM" -o json | jq -r '.data.workflowDefaults // ""')"
    case "$wd" in *"$NODE"*) ;; *) say "ERROR: offload is off: run './k8s-side.sh offload on'"; exit 1;; esac
    case "$wd" in *reverse-forwards*) wm=reverse;; *) wm=split;; esac
    [ "$wm" = "$m" ] || { say "ERROR: offload is set for '$wm', not '$m': run './k8s-side.sh offload on'"; exit 1; }
    tests="$*"; [ -n "$tests" ] || tests="$(ls "$N" | sed -n 's/^\([0-9][0-9]\)-.*\.yaml$/\1/p' | tr '\n' ' ')"
    RUN="$(date +%Y%m%d-%H%M%S)"; OUT="$HERE/results/$RUN-$m"; mkdir -p "$OUT"
    bash "$0" reset-data || exit 1
    gs || exit 1
    say "run $RUN, mode $m (interLink $(il_version)): tests $tests -> $OUT"
    echo "mode $m, interLink $(il_version), partition $SLURM_PARTITION" >"$OUT/summary.txt"
    printf 'test\tpod\tkubernetes node\tslurm job\tpartition\tcompute node\tslurm state\n' >"$OUT/where.tsv"
    # The configuration of both sides as this run uses it ('evidence' later sees only what is on then).
    mkdir -p "$OUT/config"; cp "$CONF"/*.yaml "$OUT/config/" 2>/dev/null
    hpc status >"$OUT/config/login-node-status.txt" 2>&1
    trap 'say ""; say "interrupted: results so far in $OUT/summary.txt. The workflow already submitted keeps running on the HPC side; ./k8s-side.sh clean (make clean) deletes it and cancels its job."; exit 130' INT TERM
    for T in $tests; do
      WF="$(ls "$N/$T"-*.yaml 2>/dev/null | head -n 1)"; [ -n "$WF" ] || { say "TC$T  no workflow file"; continue; }
      D="$OUT/TC$T"; mkdir -p "$D"; cp "$WF" "$D/workflow.yaml"
      start=$(date +%s)
      NAME="$(argo submit -n "$NS" "$WF" -l "$LABEL" -o json | jq -r .metadata.name)" || { say "TC$T  submit failed"; continue; }
      # --foreground: without it timeout runs in its own process group, out of reach of Ctrl-C.
      rc=0; timeout --foreground 1800 argo wait -n "$NS" "$NAME" >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 124 ] && { argo stop -n "$NS" "$NAME" >/dev/null 2>&1; sleep 10; }
      secs=$(( $(date +%s) - start ))
      argo get -n "$NS" "$NAME" -o json >"$D/workflow.json" 2>/dev/null || echo '{}' >"$D/workflow.json"
      argo logs -n "$NS" "$NAME" >"$D/logs.txt" 2>&1 || true
      PHASE="$(jq -r '.status.phase // "Unknown"' "$D/workflow.json")"
      jq -r '(.status.nodes // {}) | to_entries[] | .value | select(.type == "Pod") | [.displayName, .phase] | @tsv' \
        "$D/workflow.json" | sort >"$D/steps.tsv"
      # Where each step ran: its pod, and the Slurm job named after the pod's UID, as Slurm records it.
      kubectl -n "$NS" get pods -l "workflows.argoproj.io/workflow=$NAME" -o json 2>/dev/null \
        | jq -r '.items[] | [.metadata.name, .metadata.uid, .spec.nodeName] | @tsv' >"$D/pods.tsv"
      jobs="$(hpc_jobs)"
      while IFS=$'\t' read -r pod uid knode; do
        j="$(printf '%s\n' "$jobs" | awk -F'|' -v u="$uid" '$1 == u {print $2 "\t" $3 "\t" $4 "\t" $5; exit}')"
        printf 'TC%s\t%s\t%s\t%s\n' "$T" "$pod" "$knode" "${j:-no Slurm record}"
      done <"$D/pods.tsv" | tee "$D/where.tsv" >>"$OUT/where.tsv"
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
      [ "$v" = FAIL ] && bash "$0" diag >"$D/diag.txt" 2>&1
    done
    n="$(($(wc -l <"$OUT/where.tsv") - 1))"
    parts="$(awk -F'\t' 'NR > 1 && $5 != "" {print $5}' "$OUT/where.tsv" | sort -u | tr '\n' ' ')"
    hosts="$(awk -F'\t' 'NR > 1 && $6 != "" {print $6}' "$OUT/where.tsv" | sort -u | tr '\n' ' ')"
    line="where: $n step pods; Slurm partitions: ${parts:-none recorded}; compute nodes: ${hosts:-none recorded} ($OUT/where.tsv)"
    say "$line"; echo "$line" >>"$OUT/summary.txt"
    say "summary: $OUT/summary.txt  (keep the whole folder as evidence)"
    ;;

  evidence:*)
    shift
    run="${1:-$(ls -td "$HERE"/results/*-split "$HERE"/results/*-reverse 2>/dev/null | head -n 1)}"
    run="$HERE/results/$(basename "$run")"
    [ -f "$run/summary.txt" ] || { say "ERROR: no run in $run"; exit 1; }
    id="$(basename "$run")"; id="${id%-*}"                     # 20261124-011219 (local time)
    since="${id:0:4}-${id:4:2}-${id:6:2}T${id:9:2}:${id:11:2}:${id:13:2}"
    t0="$(date -u -d "${since/T/ }" +%Y-%m-%dT%H:%M:%S)"     # the logs are in UTC
    t1="$(date -u -d "@$(( $(date -r "$run/summary.txt" +%s) + 300 ))" +%Y-%m-%dT%H:%M:%S)"
    E="$run/evidence"; rm -rf "$E"; mkdir -p "$E/ulisses"
    cp "$CONF"/*.yaml "$E/ulisses/" 2>/dev/null
    { cat "$STATE/mode" 2>/dev/null || echo none; } >"$E/ulisses/mode-now"
    go="$(ls -d "$TRIAL_HOME"/go-*/bin/go 2>/dev/null | tail -n 1)"
    {
      for v in "$SPLIT_IL_VERSION" "$REVERSE_IL_VERSION"; do
        echo "== interLink $v, tag commit: $(git ls-remote https://github.com/interlink-hq/interLink "refs/tags/$v" 2>/dev/null | cut -c1-40)"
        for b in interlink virtual-kubelet; do
          f="$(il_dir "$v")/$b"; [ -x "$f" ] || continue
          sha256sum "$f"
          [ -n "$go" ] && "$go" version -m "$f" 2>/dev/null | grep -E '^[^[:space:]]|path|vcs\.(revision|time|modified)'
        done
      done
      echo "== Argo controller: $(kubectl -n argo get deploy workflow-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
      kubectl version 2>/dev/null
    } >"$E/ulisses/versions.txt" 2>&1
    # interLink's lines of the run only, with every Secret's data and every service-account token blanked.
    for p in il-vk il-api il-tunnel relay-agent relay-tunnel; do
      [ -s "$LOGD/$p.log" ] || continue
      awk -v a="$t0" -v b="$t1" 'match($0, /time="[^"]*"/) { t = substr($0, RSTART + 6, 19); if (t >= a && t <= b) print }' "$LOGD/$p.log" \
        | sed -E -e 's/(\\*"data\\*":\{)[^}]*/\1<redacted>/g' -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<token>/g' >"$E/ulisses/$p.log"
    done
    if hpc evidence "$since" "$t0" "$t1" >"$E/login-node.tgz"; then tar -xzf "$E/login-node.tgz" -C "$E" && rm -f "$E/login-node.tgz"
    else say "WARNING: could not collect the login node's part"; fi
    # Check before anything leaves this machine: no Global Storage key (plain or base64), no token.
    leak=""
    for s in "$GS_ACCESS_KEY" "$GS_SECRET_KEY"; do
      [ "${#s}" -ge 4 ] || continue
      grep -r -q -F -e "$s" -e "$(printf %s "$s" | base64)" "$E" && leak="a Global Storage key"
    done
    grep -r -q -e 'eyJhbGciOi' "$E" && leak="${leak:+$leak and }a token"
    [ -z "$leak" ] || { rm -rf "$E"; say "ERROR: $leak found in the evidence; removed it, nothing kept"; exit 1; }
    cat >"$E/README.txt" <<TXT
Evidence for run $(basename "$run") (collected $(date -Is) by k8s-side.sh evidence). Window: $t0 to $t1 UTC.
Secrets were blanked (Secret data, service-account tokens) and the folder checked for the Global Storage keys.

../summary.txt               what passed; the last line lists the Slurm partitions and compute nodes
../where.tsv                 every step pod -> its Slurm job, partition, compute node, state
../config/                   both sides' configuration as the run started (runs since 24 Nov 2026)
ulisses/mode-now             the mode on Ulisses when this was collected
ulisses/*Config.yaml         interLink's configuration as used (in reverse: Network.SSH.Reverse, the tunnel)
ulisses/versions.txt         interLink binaries: sha256, Go build info (module, commit); Argo; Kubernetes
ulisses/il-vk.log            the virtual kubelet: pods, shadow pods of the reverse tunnel, node status
ulisses/il-api.log           interLink's API: calls to the sidecar on the login node
login-node/SlurmConfig.yaml  the plugin's configuration (in reverse: SocketDirRoot, the subPath fix as SbatchPath)
login-node/sidecar-unit.txt  the plugin binary the user service runs (a drop-in in reverse)
login-node/versions.txt      plugin binaries' sha256 next to the release's published checksums; Singularity; Slurm
login-node/slurm-jobs.txt    Slurm's record of the jobs since the run started (job name = pod UID)
login-node/sidecar.log       the plugin's log of the run: submissions, the per-pod socket folders, deletions
login-node/probe-compute.out the last probe of a compute node of the partition (network, python3, sshd)
TXT
    say "evidence in $E:"; (cd "$E" && find . -type f | sort | sed 's|^\./|   |')
    ;;

  clean:)
    argo delete -n "$NS" -l "$LABEL" 2>&1 | tail -n 20
    # interLink removes a pod's job folder when it deletes the pod. Wait for that, so that a mode switch
    # or 'restore' right after does not stop interLink first and leave job folders (keys, tokens) behind.
    if proc_up il-vk; then
      for _ in $(seq 1 40); do
        [ -z "$(kubectl get pods -A --field-selector "spec.nodeName=$NODE" --no-headers 2>/dev/null)" ] && break
        sleep 3
      done
    fi
    left="$(kubectl get pods -A --field-selector "spec.nodeName=$NODE" --no-headers 2>/dev/null | wc -l)"
    if [ "$left" -eq 0 ]; then say "trial workflows deleted, no pod left on $NODE: interLink removed their job folders"
    else say "WARNING: $left pods still on $NODE; their job folders stay on the login node until interLink deletes them"; fi
    ;;

  restore:)
    bash "$0" offload off
    # The login node first, as when switching modes.
    hm="$(hpc_mode)"
    case "$hm" in
      none) say "login node: no mode on";;
      split|reverse) hpc disable || say "WARNING: could not switch '$hm' off on the login node: run './k8s-side.sh hpc disable'";;
      *) say "WARNING: login node: $hm";;
    esac
    hpc uninstall || say "WARNING: could not stop the sidecar on the login node: run './k8s-side.sh hpc uninstall'"
    bash "$0" api off
    kubectl delete node "$NODE" --ignore-not-found >/dev/null && say "virtual node $NODE deleted"
    if [ -f "$STATE/artifact-repositories.yaml" ]; then
      kubectl replace -f "$STATE/artifact-repositories.yaml" >/dev/null \
        && rm -f "$STATE/artifact-repositories.yaml" && say "artifact-repositories ConfigMap restored"
    fi
    say "Argo, namespace $NS and $TRIAL_HOME stay (rm -rf $TRIAL_HOME removes the binaries, configs and logs)"
    ;;

  *) awk 'NR > 1 && !/^#/ {exit} NR > 1' "$0"; exit 2;;
esac
