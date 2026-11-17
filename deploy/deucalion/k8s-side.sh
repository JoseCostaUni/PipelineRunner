#!/bin/bash
# Deucalion trial, Kubernetes side. Run as root on Ulisses (the machine of Isabel's Kubernetes
# cluster, Argo and interLink). Needs kubectl, jq, argo (CLI), mc, ssh and curl. See README.md.
# Two modes, one at a time: split (interLink 0.6.1 + split executor) and reverse (interLink 0.6.3 +
# reverse tunnel). 'mode' switches both sides at once; the commands below it are its steps.
#
#   check [split|reverse] read-only checks of the Kubernetes side (default: both modes)
#   status                the mode of each side and what is configured now (asks the login node too)
#   mode split|reverse    switch both sides to that mode: hpc-side.sh on the login node over ssh, then
#                         interLink, the artifact repository and offload here. Next: 'test'
#   executor-image        the argoexec image Argo puts in every pod (must be pre-pulled on Deucalion)
#   install               reverse, once: interLink 0.6.3 next to Isabel's 0.6.1 (release binaries, or
#                         built from the tag) and the ssh shadow image
#   api direct|relay      split: the Kubernetes API address offloaded containers get (virtual kubelet):
#                         direct = K8S_API_HOST, relay = the relay on the login node
#   api reverse           reverse: interLink 0.6.3 with the reverse tunnel of its ssh shadow
#   api off               Isabel's interLink and virtual kubelet configuration back, as before
#   artifacts             make the Global Storage Argo's default artifact repository in ARGO_NAMESPACE
#                         (as the mode that is on needs it), apply the test module library, upload the
#                         test datasets (backs up what exists)
#   offload on|off        send every workflow's pods to the interLink node (Argo workflowDefaults), so
#                         the test workflows stay plain Argo; off restores the previous defaults
#   relay-health          split: is the login-node relay reachable through our tunnel?  relay-log: agent log
#   diag                  reverse: shadow pods, their logs, virtual kubelet log
#   reset-data            put the test data in the Global Storage back as in tests/datasets, without
#                         results of earlier runs ('test' does this first)
#   test [NN ...]         run tests/argo-native (default: all) and check results in Argo AND in the
#                         Global Storage; results in ./results/<time>-<mode>/
#   clean                 delete the trial's workflows (interLink then removes their job folders)
#   restore               offload off, the login node's mode off (hpc-side.sh disable over ssh), api off,
#                         saved artifact repository back: both sides as before the trial
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
VKBAK="$VKC.pre-split"       # exists while split's API address is set
VKBAK_RT="$VKC.pre-reverse"  # exists while reverse is on
STATE=/var/lib/split-executor
mkdir -p "$STATE"
AGENT_LOG=/var/log/split-relay-agent.log
# Isabel's tunnel turns host-key checks off, so root may have no known_hosts entry for the login
# node: pin its key on first use in our own file.
SSHO=(-o BatchMode=yes -o LogLevel=ERROR -o ServerAliveInterval=30 -i "$SSH_KEY"
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/known_hosts")
CM=workflow-controller-configmap
# This repository on the login node, where 'mode' runs hpc-side.sh.
HPC_DIR="${HPC_REPO_DIR:-$HPC_PROJECT_ROOT/lisa-pipeline-runner_ze}/deploy/deucalion"
SPLIT_API="${SPLIT_API:-relay}"

# Reverse mode: interLink 0.6.3 runs from its own folder through systemd drop-ins next to Isabel's
# units, which stay as they are.
REVERSE_IL_VERSION="${REVERSE_IL_VERSION:-0.6.3}"
NEW="$INTERLINK_INSTALL_DIR-$REVERSE_IL_VERSION"
DROPIN=trial-reverse.conf
SSH_TUNNEL_IMAGE="ghcr.io/interlink-hq/interlink/ssh-tunnel:$REVERSE_IL_VERSION"
RT_NS=interlink                  # the virtual kubelet's namespace: the shadow's credentials live here
RT_KEY=trial-hpc-ssh-key         # Secret: SSH_KEY, for the shadow's ssh to the login node
RT_KNOWN=trial-hpc-known-hosts   # ConfigMap: the login node's host keys
OWNER=deucalion-trial            # app.kubernetes.io/managed-by of what we create
# The tunnel maps names, not IP addresses: the job reaches the Global Storage through a Service name,
# and the Kubernetes API on a port an unprivileged sshd can bind.
GS_SERVICE="${GS_SERVICE:-global-storage}"
GS_HOST="${GS_ENDPOINT%:*}"
case "$GS_ENDPOINT" in *:*) GS_PORT="${GS_ENDPOINT##*:}";; *) [ "${GS_INSECURE:-true}" = true ] && GS_PORT=80 || GS_PORT=443;; esac
GS_FQDN="$GS_SERVICE.$NS.svc.cluster.local"
FORWARDS="$GS_FQDN:$GS_PORT 6443:kubernetes.default.svc.cluster.local:443"

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
  local i; for i in $(seq 1 48); do [ "$(node_ready)" = True ] && { say "$INTERLINK_NODE_NAME Ready"; return 0; }; sleep 5; done
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

k8s_mode() { if [ -f "$VKBAK_RT" ]; then echo reverse; elif [ -f "$VKBAK" ]; then echo split; else echo none; fi; }
il_bin() { systemctl show -p ExecStart interlink-vk 2>/dev/null | grep -o 'path=[^ ;]*' | head -n 1 | cut -d= -f2; }
# hpc-side.sh on the login node, over the same ssh as the rest of this script. A login shell, so
# Slurm and Singularity are on the PATH as in an interactive session.
hpc() {
  ssh "${SSHO[@]}" "$HPC_USER@$HPC_LOGIN_HOST" \
    "SPLIT_ENV='$HPC_DIR/$(basename "$ENV_FILE")' bash -l '$HPC_DIR/hpc-side.sh' $*"
}
hpc_mode() {
  local m; m="$(hpc mode 2>/dev/null | tail -n 1)"
  case "$m" in split|reverse|none) echo "$m";; *) echo "unknown (no up-to-date copy of this repository in $HPC_DIR on the login node?)";; esac
}
gs_endpoint() { if [ "$(k8s_mode)" = reverse ]; then echo "$GS_FQDN:$GS_PORT"; else echo "$GS_ENDPOINT"; fi; }

il_units() { # new|old: which interLink binaries Isabel's units run (a drop-in each)
  local u d ex bin args nb
  for u in interlink-api interlink-vk; do
    d="/etc/systemd/system/$u.service.d"
    if [ "$1" = new ]; then
      mkdir -p "$d"
      ex="$(systemctl cat "$u" | awk '/^ExecStart=/{l=$0; while (l ~ /\\$/) {getline n; sub(/\\$/, "", l); l = l " " n}; print l; exit}')"
      ex="${ex#ExecStart=}"; bin="${ex%% *}"; args="${ex#"$bin"}"
      [ -n "$bin" ] || { say "ERROR: no ExecStart found in unit $u"; return 1; }
      case "$u" in interlink-api) nb="$NEW/interlink";; *) nb="$NEW/virtual-kubelet";; esac
      printf '[Service]\nExecStart=\nExecStart=%s%s\n' "$nb" "$args" >"$d/$DROPIN"
    else
      rm -f "$d/$DROPIN"; rmdir "$d" 2>/dev/null || true
    fi
  done
  systemctl daemon-reload
  systemctl restart interlink-api; sleep 2; systemctl restart interlink-vk
}
gs_service() { # on|off: the Global Storage under a Service name in ARGO_NAMESPACE, for the tunnel
  local mine
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
  out="$(timeout 180 kubectl -n "$RT_NS" run trial-shadow-probe --rm -i --quiet --restart=Never \
    --image="$SSH_TUNNEL_IMAGE" --image-pull-policy=IfNotPresent --command -- ssh-keyscan -T 10 "$HPC_LOGIN_HOST" 2>&1)"
  kubectl -n "$RT_NS" delete pod trial-shadow-probe --ignore-not-found --wait=false >/dev/null 2>&1
  if printf '%s\n' "$out" | grep -q -E 'SSH-2\.0|ssh-ed25519|ssh-rsa|ecdsa-sha2'; then pass "a pod on this cluster reaches the sshd of $HPC_LOGIN_HOST (as the shadow will)"
  else fail "a pod on this cluster does not reach the sshd of $HPC_LOGIN_HOST: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; fi
}

case "${1:-}:${2:-}" in
  check:|check:split|check:reverse)
    want="${2:-both}"
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
    info "mode on: Ulisses $(k8s_mode) (interLink $(il_bin)), login node $(hpc_mode)"

    if [ "$want" != reverse ]; then
      say "== split (interLink 0.6.1 + split executor)"
      [ -f "$RELAYBIN" ] && pass "relay binary $RELAYBIN" || fail "no $RELAYBIN"
      grep -q '^KubernetesApiAddr' "$VKC" 2>/dev/null && info "virtual kubelet: $(grep -E '^KubernetesApi(Addr|Port)' "$VKC" | tr '\n' ' ')" \
        || info "virtual kubelet: default API address"
    fi
    if [ "$want" != split ]; then
      say "== reverse (interLink $REVERSE_IL_VERSION + reverse tunnel)"
      if [ -x "$NEW/interlink" ] && [ -x "$NEW/virtual-kubelet" ]; then pass "interLink $REVERSE_IL_VERSION installed in $NEW"
      else info "interLink $REVERSE_IL_VERSION not installed yet: 'install' fetches or builds it (needs internet, git and about 1 GB free)"; fi
      command -v ssh-keyscan >/dev/null && pass "found ssh-keyscan" || fail "missing ssh-keyscan"
      if crictl inspecti "$SSH_TUNNEL_IMAGE" >/dev/null 2>&1; then pass "shadow image $SSH_TUNNEL_IMAGE present"
      else info "shadow image $SSH_TUNNEL_IMAGE not present yet ('install' pulls it, or the kubelet does)"; fi
      [ "$GS_PORT" -ge 1024 ] 2>/dev/null && pass "Global Storage port $GS_PORT can be bound by the job's unprivileged sshd" \
        || fail "Global Storage port $GS_PORT is below 1024: the job's sshd cannot bind it"
      if kubectl -n "$NS" get svc "$GS_SERVICE" >/dev/null 2>&1 \
         && [ "$(kubectl -n "$NS" get svc "$GS_SERVICE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" != "$OWNER" ]; then
        fail "Service $NS/$GS_SERVICE exists and is not ours: set GS_SERVICE to another name"
      else pass "Service name $GS_FQDN free (or ours) for the Global Storage"; fi
      if openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text 2>/dev/null | grep -q 'kubernetes.default.svc.cluster.local'; then
        pass "API server certificate valid for kubernetes.default.svc.cluster.local (the name jobs use through the tunnel)"
      else info "could not confirm that /etc/kubernetes/pki/apiserver.crt names kubernetes.default.svc.cluster.local"; fi
      [ -n "$(ssh-keyscan -T 10 "$HPC_LOGIN_HOST" 2>/dev/null)" ] && pass "ssh-keyscan $HPC_LOGIN_HOST works (pins the login node's key for the shadow)" \
        || fail "ssh-keyscan $HPC_LOGIN_HOST returned nothing"
      others="$(ls /etc/systemd/system/interlink-api.service.d /etc/systemd/system/interlink-vk.service.d 2>/dev/null | grep -v -e '^/' -e '^$' -e "^$DROPIN\$" | sort -u | tr '\n' ' ')"
      [ -z "$others" ] || info "other drop-ins also change Isabel's interLink units: $others"
    fi
    exit "$FAILED"
    ;;

  status:)
    say "== Ulisses: mode $(k8s_mode), interLink $(il_bin), $INTERLINK_NODE_NAME Ready=$(node_ready)"
    grep -E '^KubernetesApi(Addr|Port)|^ *(ShadowMode|NodeExec|Sshd):' "$VKC" 2>/dev/null | sed 's/^ */   /'
    say "   artifact repository endpoint: $(kubectl -n "$NS" get cm artifact-repositories -o jsonpath='{.data.default-v1}' 2>/dev/null | sed -n 's/^ *endpoint: *//p')"
    wd="$(kubectl -n argo get cm "$CM" -o json 2>/dev/null | jq -r '.data.workflowDefaults // ""')"
    case "$wd" in *"$INTERLINK_NODE_NAME"*) o=on;; *) o=off;; esac
    case "$wd" in *reverse-forwards*) o="$o, with reverse-forwards";; esac
    say "   offload: $o"
    say "   relay units: tunnel $(systemctl is-active split-relay-tunnel 2>&1), agent $(systemctl is-active split-relay-agent 2>&1)"
    say "== login node $HPC_LOGIN_HOST:"
    hpc status 2>&1 | sed 's/^/   /'
    ;;

  mode:split|mode:reverse)
    m="$2"
    step() { say "-- $*"; "$@" || { say "ERROR in: $*"; say "Fix it and run './k8s-side.sh mode $m' again: every step can be repeated. './k8s-side.sh status' shows where each side is."; exit 1; }; }
    hm="$(hpc_mode)"
    case "$hm" in split|reverse|none) ;; *) say "ERROR: login node: $hm"; exit 1;; esac
    say "== switching both sides to '$m' (now: Ulisses $(k8s_mode), login node $hm)"
    step bash "$0" offload off
    # The login node first: the virtual node only becomes Ready when the plugin answers. 'enable' runs
    # even if the mode is already on, so running 'mode' again repairs a half-done switch.
    [ "$hm" = "$m" ] || [ "$hm" = none ] || step hpc disable
    step hpc images
    step hpc enable "$m"
    if [ "$m" = reverse ]; then
      [ -x "$NEW/interlink" ] && [ -x "$NEW/virtual-kubelet" ] || step bash "$0" install
      step bash "$0" api reverse
    elif [ "$SPLIT_API" = direct ]; then
      step bash "$0" api direct
    else
      step hpc relay on
      step bash "$0" api relay
    fi
    step bash "$0" artifacts
    step bash "$0" offload on
    say "== both sides in '$m'. Next: ./k8s-side.sh test 00"
    ;;

  executor-image:) executor_image ;;

  install:)
    case "$(uname -m)" in aarch64|arm64) arch=arm64; goarch=arm64;; *) arch=x86_64; goarch=amd64;; esac
    mkdir -p "$NEW"
    base="https://github.com/interlink-hq/interLink/releases/download/$REVERSE_IL_VERSION"
    if [ -x "$NEW/interlink" ] && [ -x "$NEW/virtual-kubelet" ]; then
      say "interLink $REVERSE_IL_VERSION already in $NEW"
    elif curl -fsSL --retry 3 -o "$NEW/interlink.dl" "$base/interlink_Linux_$arch" \
         && curl -fsSL --retry 3 -o "$NEW/virtual-kubelet.dl" "$base/virtual-kubelet_Linux_$arch"; then
      mv "$NEW/interlink.dl" "$NEW/interlink"; mv "$NEW/virtual-kubelet.dl" "$NEW/virtual-kubelet"
      chmod 0755 "$NEW/interlink" "$NEW/virtual-kubelet"
      say "interLink $REVERSE_IL_VERSION: release binaries in $NEW"
    else
      # The 0.6.3 release was published without binaries: build them from the tag.
      rm -f "$NEW"/*.dl
      say "interLink $REVERSE_IL_VERSION: no release binaries, building from the tag (a few minutes)"
      command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git >/dev/null; } || { say "ERROR: no git"; exit 1; }
      src=/var/tmp/trial-interlink-src
      rm -rf "$src"
      git -c advice.detachedHead=false clone -q --depth 1 --branch "$REVERSE_IL_VERSION" https://github.com/interlink-hq/interLink.git "$src" || { say "ERROR: git clone failed"; exit 1; }
      gov="$(awk '/^go /{print $2; exit}' "$src/go.mod")"; case "$gov" in *.*.*) ;; *) gov="$gov.0";; esac
      if [ ! -x "/usr/local/go-$gov/bin/go" ]; then
        curl -fsSL --retry 3 -o /var/tmp/go.tgz "https://go.dev/dl/go$gov.linux-$goarch.tar.gz" || { say "ERROR: download of Go $gov failed"; exit 1; }
        rm -rf "/usr/local/go-$gov"; mkdir -p "/usr/local/go-$gov"
        tar xzf /var/tmp/go.tgz -C "/usr/local/go-$gov" --strip-components=1; rm -f /var/tmp/go.tgz
      fi
      ( cd "$src" && export PATH="/usr/local/go-$gov/bin:$PATH" GOTOOLCHAIN=local CGO_ENABLED=0 GOFLAGS=-mod=mod \
        && go build -o "$NEW/interlink" ./cmd/interlink && go build -o "$NEW/virtual-kubelet" ./cmd/virtual-kubelet ) \
        || { rm -f "$NEW/interlink" "$NEW/virtual-kubelet"; say "ERROR: build failed"; exit 1; }
      chmod 0755 "$NEW/interlink" "$NEW/virtual-kubelet"
      say "built with Go $gov: $(ls -l "$NEW" | tail -n +2 | awk '{print $NF, $5}' | tr '\n' ' ')"
    fi
    # The shadow image (debian, openssh-client, socat), published for amd64 and arm64. Pulled now so
    # the first pod does not wait for it; if that fails, the same Dockerfile is built here, and
    # otherwise the kubelet pulls it when 'api reverse' runs its probe pod.
    if ! command -v crictl >/dev/null; then say "no crictl: the kubelet pulls $SSH_TUNNEL_IMAGE when a pod needs it"
    elif crictl inspecti "$SSH_TUNNEL_IMAGE" >/dev/null 2>&1; then say "image $SSH_TUNNEL_IMAGE present"
    elif crictl pull "$SSH_TUNNEL_IMAGE" >/dev/null 2>&1; then say "image $SSH_TUNNEL_IMAGE pulled"
    elif command -v docker >/dev/null; then
      say "pull of $SSH_TUNNEL_IMAGE failed, building it"
      d=/var/tmp/trial-ssh-tunnel; rm -rf "$d"; mkdir -p "$d"
      curl -fsSL "https://raw.githubusercontent.com/interlink-hq/interLink/$REVERSE_IL_VERSION/docker/Dockerfile.ssh-tunnel" -o "$d/Dockerfile" \
        && docker build -q -t "$SSH_TUNNEL_IMAGE" "$d" >/dev/null \
        && docker save "$SSH_TUNNEL_IMAGE" | ctr -n k8s.io images import - >/dev/null \
        || { say "ERROR: could not build the shadow image"; exit 1; }
      say "image $SSH_TUNNEL_IMAGE built and imported"
    else say "WARNING: could not pull $SSH_TUNNEL_IMAGE now; the kubelet tries again when a pod needs it"; fi
    say "installed; Isabel's interLink is untouched until 'api reverse'"
    ;;

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
    gs
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
    kubernetes.io/hostname: $INTERLINK_NODE_NAME
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
    say "offload ON ($(k8s_mode)): every workflow's pods go to $INTERLINK_NODE_NAME, partition $SLURM_PARTITION"
    say "Note: this applies to ALL workflows of this Argo, including Isabel's own tests. Switch off after the trial."
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
    stop_relay_units
    vk_config "$K8S_API_HOST" "$K8S_API_PORT"
    ;;
  api:relay)
    [ "$(k8s_mode)" = reverse ] && { bash "$0" api off || exit 1; }
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
  api:reverse)
    [ -x "$NEW/interlink" ] && [ -x "$NEW/virtual-kubelet" ] || { say "ERROR: interLink $REVERSE_IL_VERSION not in $NEW: run './k8s-side.sh install' first"; exit 1; }
    [ "$GS_PORT" -ge 1024 ] 2>/dev/null || { say "ERROR: Global Storage port $GS_PORT is below 1024: the job's unprivileged sshd cannot bind it"; exit 1; }
    hm="$(hpc_mode)"
    [ "$hm" = reverse ] || { say "ERROR: the login node is in '$hm', not reverse: run './hpc-side.sh enable reverse' there first"; exit 1; }
    [ "$(k8s_mode)" = split ] && { bash "$0" api off || exit 1; }
    stop_relay_units
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
    [ -f "$VKBAK_RT" ] || cp -p "$VKC" "$VKBAK_RT"
    cp -p "$VKBAK_RT" "$VKC"
    cat >>"$VKC" <<YAML

# --- Deucalion trial, reverse mode (k8s-side.sh api reverse; backup: $VKBAK_RT) ---
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
    il_units new || exit 1
    wait_ready || exit 1
    say "interLink now: $(il_bin)"
    FAILED=0; probe_shadow
    say "reverse ON: offloaded pods reach $GS_FQDN:$GS_PORT and the Kubernetes API through the login node"
    exit "$FAILED"
    ;;
  api:off)
    stop_relay_units
    case "$(k8s_mode)" in
      reverse)
        cp -p "$VKBAK_RT" "$VKC"; rm -f "$VKBAK_RT"
        il_units old
        wait_ready
        shadow_credentials_off
        gs_service off
        if [ -f "$STATE/created-ns-$RT_NS" ]; then kubectl delete ns "$RT_NS" --wait=false >/dev/null 2>&1; rm -f "$STATE/created-ns-$RT_NS"; fi
        say "reverse OFF: Isabel's interLink ($(il_bin)) and virtual kubelet config restored, SSH key Secrets deleted"
        ;;
      split)
        cp -p "$VKBAK" "$VKC"; rm -f "$VKBAK"; systemctl restart interlink-vk; wait_ready; say "virtual kubelet config restored"
        ;;
      *) say "virtual kubelet config was not changed";;
    esac
    ;;
  relay-health:)
    for _ in $(seq 1 10); do
      out="$(curl -s -m 5 "http://127.0.0.1:$RELAY_CTL_PORT/health" 2>/dev/null)" && [ -n "$out" ] && { say "relay reachable through the tunnel: $out"; exit 0; }
      sleep 2
    done
    say "relay NOT reachable through the tunnel (systemctl status split-relay-tunnel)"; exit 1
    ;;
  relay-log:) cat "$AGENT_LOG" 2>/dev/null || say "no agent log" ;;

  diag:)
    say "== mode $(k8s_mode), interLink $(il_bin), $INTERLINK_NODE_NAME Ready=$(node_ready)"
    say "== shadow pods"; kubectl get pods -A -o wide 2>/dev/null | awk 'NR == 1 || $1 ~ /-shadow$/'
    for p in $(kubectl get pods -A --no-headers 2>/dev/null | awk '$1 ~ /-shadow$/ {print $1 "/" $2}' | tail -n 3); do
      say "== logs $p"; kubectl -n "${p%%/*}" logs "${p#*/}" --all-containers --tail=40 2>&1
    done
    say "== virtual kubelet (last 60 lines)"; journalctl -u interlink-vk -n 60 --no-pager 2>&1 | cut -c1-300
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
    case "$wd" in *"$INTERLINK_NODE_NAME"*) ;; *) say "ERROR: offload is off: run './k8s-side.sh offload on'"; exit 1;; esac
    case "$wd" in *reverse-forwards*) wm=reverse;; *) wm=split;; esac
    [ "$wm" = "$m" ] || { say "ERROR: offload is set for '$wm', not '$m': run './k8s-side.sh offload on'"; exit 1; }
    tests="$*"; [ -n "$tests" ] || tests="$(ls "$N" | sed -n 's/^\([0-9][0-9]\)-.*\.yaml$/\1/p' | tr '\n' ' ')"
    RUN="$(date +%Y%m%d-%H%M%S)"; OUT="$HERE/results/$RUN-$m"; mkdir -p "$OUT"
    bash "$0" reset-data || exit 1
    gs
    say "run $RUN, mode $m (interLink $(il_bin)): tests $tests -> $OUT"
    echo "mode $m, interLink $(il_bin), partition $SLURM_PARTITION" >"$OUT/summary.txt"
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
      [ "$v" = FAIL ] && [ "$m" = reverse ] && bash "$0" diag >"$D/diag.txt" 2>&1
    done
    say "summary: $OUT/summary.txt  (keep the whole folder as evidence)"
    ;;

  clean:)
    argo delete -n "$NS" -l "$LABEL" 2>&1 | tail -n 20
    say "trial workflows deleted; interLink removes their job folders on the login node"
    ;;

  restore:)
    bash "$0" offload off
    # The login node first, as when switching modes.
    hm="$(hpc_mode)"
    case "$hm" in
      none) say "login node: nothing on";;
      split|reverse) hpc disable || say "WARNING: could not switch '$hm' off on the login node: run './hpc-side.sh disable' there";;
      *) say "WARNING: login node: $hm. Run './hpc-side.sh disable' there";;
    esac
    bash "$0" api off
    if [ -f "$STATE/artifact-repositories.yaml" ]; then
      kubectl replace -f "$STATE/artifact-repositories.yaml" >/dev/null \
        && rm -f "$STATE/artifact-repositories.yaml" && say "artifact-repositories ConfigMap restored"
    fi
    ;;

  *) awk 'NR > 1 && !/^#/ {exit} NR > 1' "$0"; exit 2;;
esac
