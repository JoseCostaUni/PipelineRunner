#!/bin/bash
# Reverse-tunnel experiment, Kubernetes side (as root on ulisses).
#   install            interLink $IL_VERSION (API + virtual kubelet) next to Isabel's 0.6.1: release
#                      binaries if published, otherwise built from the tag; the ssh shadow image
#   use 0.6.1|new      which interLink runs (systemd drop-ins; 0.6.1 = Isabel's units untouched)
#   reverse on|off     virtual kubelet: ssh shadow with the reverse tunnel (srun carrier, user-space
#                      sshd), API address for offloaded pods = kubernetes.default.svc.cluster.local:6443
#                      through the tunnel; Service 'minio' for the Global Storage; NAT for pod -> VM
#   artifacts          Argo's default artifact repository = minio.default.svc.cluster.local:9000
#   offload on|off     Argo workflowDefaults: every pod to interlink-node, Slurm flags, reverse-forwards
#   diag               shadow pods, their logs, virtual kubelet log
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
load_ips
export KUBECONFIG=/etc/kubernetes/admin.conf
NEW=/opt/interlink-$IL_VERSION
VKC=/opt/interlink/VirtualKubeletConfig.yaml
VKBAK=$VKC.pre-rt
NS=default
FORWARDS="minio.default.svc.cluster.local:9000 6443:kubernetes.default.svc.cluster.local:443"
NAT_COMMENT=rt-shadow-to-vms

node_wait() {
  local i
  for _ in $(seq 1 48); do bash "$TB/guest/probe.sh" k8s-node >/dev/null 2>&1 && { log "interlink-node Ready"; return 0; }; sleep 5; done
  log "ERROR: interlink-node not Ready (journalctl -u interlink-vk -n 50)"; journalctl -u interlink-vk -n 30 --no-pager; return 1
}

dl() { curl -fsSL --retry 3 -o "$2" "$1"; }

case "${1:-}:${2:-}" in
  install:)
    mkdir -p "$NEW"
    base="https://github.com/interlink-hq/interLink/releases/download/$IL_VERSION"
    if [ ! -x "$NEW/interlink" ] || [ ! -x "$NEW/virtual-kubelet" ]; then
      if dl "$base/interlink_Linux_arm64" "$NEW/interlink.dl" && dl "$base/virtual-kubelet_Linux_arm64" "$NEW/virtual-kubelet.dl"; then
        mv "$NEW/interlink.dl" "$NEW/interlink"; mv "$NEW/virtual-kubelet.dl" "$NEW/virtual-kubelet"
        log "interLink $IL_VERSION: release binaries"
      else
        rm -f "$NEW"/*.dl
        log "interLink $IL_VERSION: no release binaries, building from the tag"
        command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git >/dev/null; }
        src=/var/tmp/rt-interlink
        rm -rf "$src"; git clone -q --depth 1 --branch "$IL_VERSION" https://github.com/interlink-hq/interLink.git "$src"
        gov="$(awk '/^go /{print $2; exit}' "$src/go.mod")"; case "$gov" in *.*.*) ;; *) gov="$gov.0";; esac
        if [ ! -x "/usr/local/go-$gov/bin/go" ]; then
          dl "https://go.dev/dl/go$gov.linux-arm64.tar.gz" /var/tmp/go.tgz
          rm -rf "/usr/local/go-$gov"; mkdir -p "/usr/local/go-$gov"; tar xzf /var/tmp/go.tgz -C "/usr/local/go-$gov" --strip-components=1; rm -f /var/tmp/go.tgz
        fi
        ( cd "$src" && export PATH="/usr/local/go-$gov/bin:$PATH" GOTOOLCHAIN=local CGO_ENABLED=0 GOFLAGS=-mod=mod \
          && go build -o "$NEW/interlink" ./cmd/interlink && go build -o "$NEW/virtual-kubelet" ./cmd/virtual-kubelet )
        log "built: $(ls -l "$NEW" | tail -n +2 | awk '{print $NF, $5}' | tr '\n' ' ')"
      fi
      chmod 0755 "$NEW/interlink" "$NEW/virtual-kubelet"
    fi
    # The shadow image (debian + openssh-client + socat). Published multi-arch on ghcr.io; if the
    # pull fails, build the same Dockerfile here and import it into containerd.
    if crictl inspecti "$SSH_TUNNEL_IMAGE" >/dev/null 2>&1; then log "image $SSH_TUNNEL_IMAGE present"
    elif crictl pull "$SSH_TUNNEL_IMAGE" >/dev/null 2>&1; then log "image $SSH_TUNNEL_IMAGE pulled"
    else
      log "pull of $SSH_TUNNEL_IMAGE failed, building it"
      command -v docker >/dev/null || { log "ERROR: no docker to build the shadow image"; exit 1; }
      d=/var/tmp/rt-ssh-tunnel; rm -rf "$d"; mkdir -p "$d"
      curl -fsSL "https://raw.githubusercontent.com/interlink-hq/interLink/$IL_VERSION/docker/Dockerfile.ssh-tunnel" -o "$d/Dockerfile"
      docker build -q -t "$SSH_TUNNEL_IMAGE" "$d" >/dev/null
      docker save "$SSH_TUNNEL_IMAGE" | ctr -n k8s.io images import - >/dev/null
      log "image $SSH_TUNNEL_IMAGE built and imported"
    fi
    ;;

  use:new|use:0.6.1)
    for u in interlink-api interlink-vk; do
      d="/etc/systemd/system/$u.service.d"
      if [ "$2" = new ]; then
        mkdir -p "$d"
        ex="$(systemctl cat "$u" | awk '/^ExecStart=/{l=$0; while (l ~ /\\$/) {getline n; sub(/\\$/, "", l); l = l " " n}; print l; exit}')"
        ex="${ex#ExecStart=}"
        bin="${ex%% *}"; args="${ex#"$bin"}"
        case "$u" in interlink-api) nb="$NEW/interlink";; *) nb="$NEW/virtual-kubelet";; esac
        printf '[Service]\nExecStart=\nExecStart=%s%s\n' "$nb" "$args" >"$d/rt.conf"
      else
        rm -f "$d/rt.conf"; rmdir "$d" 2>/dev/null || true
      fi
    done
    systemctl daemon-reload
    systemctl restart interlink-api; sleep 2; systemctl restart interlink-vk
    node_wait
    log "interLink now: $(systemctl show -p ExecStart interlink-vk | grep -o 'path=[^ ;]*')"
    ;;

  reverse:on)
    [ -f "$VKBAK" ] || cp -p "$VKC" "$VKBAK"
    kubectl get ns interlink >/dev/null 2>&1 || kubectl create ns interlink >/dev/null
    # The shadow logs in to the login node as lisa, with the key of Isabel's tunnel. On a real
    # site use a key for the tunnel only (interLink docs, "A key for the tunnel only").
    kubectl -n interlink create secret generic hpc-ssh-key --from-file=id_ed25519=/root/.ssh/id_ed25519 \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ssh-keyscan -T 5 "$LOGIN_IP" 2>/dev/null >/var/tmp/rt-known_hosts
    [ -s /var/tmp/rt-known_hosts ] || { log "ERROR: ssh-keyscan of the login node failed"; exit 1; }
    kubectl -n interlink create configmap hpc-known-hosts --from-file=known_hosts=/var/tmp/rt-known_hosts \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    cp -p "$VKBAK" "$VKC"
    cat >>"$VKC" <<YAML

# --- reverse-tunnel experiment (backup: $VKBAK) ---
Namespace: "interlink"
KubernetesApiAddr: "kubernetes.default.svc.cluster.local"
KubernetesApiPort: "6443"
Network:
  EnableTunnel: true
  ShadowMode: "ssh"
  SSH:
    LoginHost: "$LOGIN_IP"
    User: "lisa"
    KeySecret: "hpc-ssh-key"
    KnownHostsConfigMap: "hpc-known-hosts"
    Image: "$SSH_TUNNEL_IMAGE"
    Reverse:
      Enabled: true
      NodeExec: "srun"
      Sshd: "userspace"
YAML
    # The Global Storage under a Service name: the reverse tunnel maps names, not IPs. In the
    # testbed MinIO runs in Docker on ulisses itself; on Deucalion it is Isabel's VM.
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: {name: minio, namespace: $NS}
spec:
  ports: [{name: s3, port: 9000, targetPort: 9000}]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: minio-1
  namespace: $NS
  labels: {kubernetes.io/service-name: minio}
addressType: IPv4
ports: [{name: s3, port: 9000}]
endpoints: [{addresses: ["$ULISSES_IP"]}]
YAML
    # Calico's default pod range (192.168.0.0/16) contains the VM network, so it does not NAT a
    # shadow pod's connection to the login node and the reply never comes back. Masquerade it.
    dev="$(ip -4 route get "$LOGIN_IP" | awk '{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}')"
    iptables -t nat -C POSTROUTING -s 192.168.0.0/16 -d "$SUBNET" -o "$dev" -m comment --comment "$NAT_COMMENT" -j MASQUERADE 2>/dev/null \
      || iptables -t nat -I POSTROUTING 1 -s 192.168.0.0/16 -d "$SUBNET" -o "$dev" -m comment --comment "$NAT_COMMENT" -j MASQUERADE
    systemctl restart interlink-vk
    node_wait
    journalctl -u interlink-vk -n 200 --no-pager | grep -iE 'shadow|ssh|reverse|forward' | tail -n 8 || true
    ;;
  reverse:off)
    while iptables -t nat -D POSTROUTING -s 192.168.0.0/16 -d "$SUBNET" -o "$(ip -4 route get "$LOGIN_IP" | awk '{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}')" -m comment --comment "$NAT_COMMENT" -j MASQUERADE 2>/dev/null; do :; done
    if [ -f "$VKBAK" ]; then cp -p "$VKBAK" "$VKC"; rm -f "$VKBAK"; systemctl restart interlink-vk; node_wait; fi
    log "reverse tunnel off (Service minio, namespace interlink and its secret are left; harmless)"
    ;;

  artifacts:)
    kubectl -n "$NS" get cm artifact-repositories -o json \
      | jq '.data["default-v1"] |= sub("endpoint: [^\n]*"; "endpoint: minio.default.svc.cluster.local:9000")' \
      | kubectl apply -f - >/dev/null
    log "artifact repository endpoint: $(kubectl -n "$NS" get cm artifact-repositories -o jsonpath='{.data.default-v1}' | grep endpoint)"
    ;;

  offload:on|offload:off)
    CM=workflow-controller-configmap; SAVED=/var/tmp/rt-workflowdefaults.saved
    if [ "$2" = on ]; then
      [ -f "$SAVED" ] || kubectl -n argo get cm "$CM" -o json | jq -r '.data.workflowDefaults // ""' >"$SAVED"
      flags="$( set +u; source /opt/lpr/setup/kubernetes/.env; echo "--account=$SLURM_ACCOUNT --partition=$SLURM_PARTITION" )"
      defaults="spec:
  nodeSelector:
    kubernetes.io/hostname: interlink-node
  tolerations:
  - key: virtual-node.interlink/no-schedule
    operator: Exists
  podMetadata:
    annotations:
      slurm-job.vk.io/flags: \"$flags\"
      interlink.eu/reverse-forwards: \"$FORWARDS\""
      kubectl -n argo patch cm "$CM" --type merge -p "$(jq -n --arg v "$defaults" '{data: {workflowDefaults: $v}}')" >/dev/null
    else
      [ -f "$SAVED" ] || { log "offload already off"; exit 0; }
      if [ -s "$SAVED" ]; then kubectl -n argo patch cm "$CM" --type merge -p "$(jq -n --rawfile v "$SAVED" '{data: {workflowDefaults: $v}}')" >/dev/null
      else kubectl -n argo patch cm "$CM" --type json -p '[{"op":"remove","path":"/data/workflowDefaults"}]' >/dev/null 2>&1 || true; fi
      rm -f "$SAVED"
    fi
    sleep 5
    log "workflowDefaults: $(kubectl -n argo get cm "$CM" -o json | jq -c '.data.workflowDefaults // "none"')"
    ;;

  diag:)
    echo "== interLink: $(systemctl show -p ExecStart interlink-vk | grep -o 'path=[^ ;]*')"
    echo "== shadow pods"; kubectl get pods -A -o wide 2>/dev/null | grep -E 'shadow|NAMESPACE' || true
    for p in $(kubectl get pods -A --no-headers 2>/dev/null | awk '$1 ~ /-shadow$/ {print $1 "/" $2}' | tail -n 3); do
      echo "== logs $p"; kubectl -n "${p%%/*}" logs "${p#*/}" --all-containers --tail=40 2>&1 || true
    done
    echo "== virtual kubelet (last 60 lines)"; journalctl -u interlink-vk -n 60 --no-pager 2>&1 | cut -c1-300
    ;;

  *) sed -n '2,13p' "$0"; exit 2;;
esac
