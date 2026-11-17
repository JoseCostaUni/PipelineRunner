#!/bin/bash
# Split executor, Kubernetes side (as root on ulisses).
#   api direct   interLink's virtual kubelet gives every offloaded container the Kubernetes API
#                address ulisses:6443 (KubernetesApiAddr/KubernetesApiPort, interLink 0.6.1). Needs a
#                login node that can reach ulisses.
#   api relay    the login node cannot reach ulisses: containers get the relay on the login node
#                (127.0.0.1:16443) and its CA (KubernetesApiCaCrt); ulisses opens an ssh -L tunnel
#                to the relay's control port and runs the agent that answers from the real API.
#                Run 'split-login.sh relay on' first.
#   api off      restore the VK configuration, stop tunnel and agent
#   relay-health is the relay reachable through the tunnel?   relay-log: the agent's log
source /opt/testbed/guest/lib.sh
load_ips
export KUBECONFIG=/etc/kubernetes/admin.conf
VKC=/opt/interlink/VirtualKubeletConfig.yaml
BAK=$VKC.pre-t2

wait_ready() {
  local i
  for i in $(seq 1 36); do
    bash "$TB/guest/probe.sh" k8s-node >/dev/null 2>&1 && { log "interlink-node Ready"; return 0; }
    sleep 5
  done
  log "ERROR: interlink-node not Ready after restart"; return 1
}

ZE=$TB/ze/split-executor
AGENT_LOG=/var/log/split-relay-agent.log

stop_relay_units() {
  local u
  for u in split-relay-agent split-relay-tunnel; do
    systemctl stop "$u" >/dev/null 2>&1 || true
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
  done
}

vk_config() { # addr port [ca-file]
  [ -f "$BAK" ] || cp -p "$VKC" "$BAK"
  cp -p "$BAK" "$VKC"
  printf '\nKubernetesApiAddr: "%s"\nKubernetesApiPort: "%s"\n' "$1" "$2" >>"$VKC"
  if [ -n "${3:-}" ]; then
    echo "KubernetesApiCaCrt: |" >>"$VKC"
    sed 's/^/  /' "$3" >>"$VKC"
  fi
  systemctl restart interlink-vk
  wait_ready
  grep -E '^KubernetesApi(Addr|Port)' "$VKC"
}

case "${1:-}:${2:-}" in
  api:on|api:direct)
    stop_relay_units
    vk_config "$ULISSES_IP" 6443
    ;;
  api:relay)
    SSHO="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i /root/.ssh/id_ed25519"
    # shellcheck disable=SC2086
    ssh $SSHO "lisa@$LOGIN_IP" "cat $HPC_ROOT/split-executor/relay/ca.crt" >/var/tmp/split-relay-ca.crt \
      || { log "ERROR: could not fetch the relay CA from the login node (split-login.sh relay on first)"; exit 1; }
    stop_relay_units
    : >"$AGENT_LOG"
    chmod 0755 "$ZE/api-relay/split-relay" "$ZE"/api-relay/bin/split-relay-linux-*
    # The tunnel is opened by ulisses, like interLink's own: the login node never connects here.
    # shellcheck disable=SC2086
    systemd-run --quiet --unit=split-relay-tunnel -p Restart=always -p RestartSec=3 \
      /usr/bin/ssh -N $SSHO -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
      -L 127.0.0.1:16444:127.0.0.1:16444 "lisa@$LOGIN_IP"
    systemd-run --quiet --unit=split-relay-agent -p Restart=always -p RestartSec=3 \
      -p StandardOutput=append:$AGENT_LOG -p StandardError=append:$AGENT_LOG \
      "$ZE/api-relay/split-relay" agent --ctl http://127.0.0.1:16444 \
      --api "https://$ULISSES_IP:6443" --ca /etc/kubernetes/pki/ca.crt
    vk_config 127.0.0.1 16443 /var/tmp/split-relay-ca.crt
    ;;
  api:off)
    stop_relay_units
    if [ -f "$BAK" ]; then
      cp -p "$BAK" "$VKC"; rm -f "$BAK"
      systemctl restart interlink-vk
      wait_ready
    fi
    ;;
  relay-health:)
    for i in $(seq 1 10); do
      out="$(curl -s -m 5 http://127.0.0.1:16444/health 2>/dev/null)" && [ -n "$out" ] && { echo "relay reachable through the tunnel: $out"; exit 0; }
      sleep 2
    done
    echo "relay NOT reachable through the tunnel"; exit 1
    ;;
  relay-log:)
    cat "$AGENT_LOG" 2>/dev/null || true
    ;;
  *) echo "usage: $0 api direct|relay|off | relay-health | relay-log" >&2; exit 2;;
esac
