#!/bin/bash
# Diagnostics of the interLink chain (as root). Prints everything; never fails.
source /opt/testbed/guest/lib.sh
set +e
ROLE="$(cat /etc/testbed/role 2>/dev/null || echo unknown)"
sec() { echo; echo "----- [$ROLE] $* -----"; }

case "$ROLE" in
  ulisses)
    export KUBECONFIG=/etc/kubernetes/admin.conf
    sec "services"
    for s in interlink-tunnel interlink-api interlink-vk; do echo "$s: $(systemctl is-active "$s")"; done
    sec "listening sockets (5000 = tunnel end, /tmp/interlink.sock = API)"
    ss -tlnp | grep -E ':5000|:6443' ; ls -l /tmp/interlink.sock
    sec "tunnel test: HTTP to 127.0.0.1:5000 (should reach the sidecar on login)"
    curl -sS -m 5 -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:5000/ 2>&1
    sec "journal: interlink-tunnel"; journalctl -u interlink-tunnel --no-pager -n 25
    sec "journal: interlink-api"; journalctl -u interlink-api --no-pager -n 40
    sec "journal: interlink-vk"; journalctl -u interlink-vk --no-pager -n 40
    sec "config files"; cat /opt/interlink/InterLinkConfig.yaml /opt/interlink/VirtualKubeletConfig.yaml
    sec "nodes"; kubectl get nodes -o wide
    sec "interlink-node conditions"; kubectl describe node interlink-node | sed -n '/Conditions/,/Addresses/p'
    sec "ssh to login as lisa (the tunnel's login)"
    ssh -i /root/.ssh/id_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 lisa@"$(awk -F= '/^LOGIN_IP=/ {print $2}' /etc/testbed/ips.env)" 'echo ok: $(hostname)' 2>&1
    ;;
  login)
    sec "sidecar service (lisa)"
    lisa_ssh "systemctl --user --no-pager status interlink-sidecar | head -n 8" 2>&1
    sec "listening sockets (4000 = sidecar)"
    ss -tlnp | grep -E ':4000|:22 '
    sec "sidecar answers locally?"
    curl -sS -m 5 -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:4000/ 2>&1
    sec "sidecar.log (last 40 lines)"
    tail -n 40 "$HPC_ROOT/.interlink/sidecar.log" 2>&1
    sec "sidecar config"
    cat "$HPC_ROOT/.interlink/SlurmConfig.yaml" 2>&1
    sec "sshd journal (last 20 lines)"
    journalctl -u sshd --no-pager -n 20
    ;;
  *) sec "nothing to report for role $ROLE";;
esac
exit 0
