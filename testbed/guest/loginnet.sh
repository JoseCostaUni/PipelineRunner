#!/bin/bash
# The login node cannot open connections to ulisses (the Kubernetes side), as on Deucalion, where
# ulisses is on a private FEUP address: it cannot reach the Kubernetes API, Argo, Dex or ulisses'
# SSH. Connections ulisses opens (its SSH tunnels into the login node) keep working. Only MinIO
# (9000) stays reachable: it stands for the Global Storage, a separate host on Deucalion (Isabel's
# Azure VM) that the login node reaches. 8099 is the testbed's own file server (mc download during
# provisioning), not part of the prototype. (as root, on login)
#   apply    load the rules (also at boot: testbed-loginnet.service)      status   show them
set -euo pipefail
IPS=/etc/testbed/ips.env

case "${1:-apply}" in
  apply) ;;
  status) nft list table inet testbed-login 2>/dev/null || echo "(no rules loaded)"; exit 0;;
  *) echo "usage: $0 apply|status" >&2; exit 2;;
esac

install -m 755 "$0" /usr/local/sbin/testbed-loginnet 2>/dev/null || true
if [ ! -f /etc/systemd/system/testbed-loginnet.service ]; then
  cat >/etc/systemd/system/testbed-loginnet.service <<UNIT
[Unit]
Description=Testbed: the login node cannot open connections to the Kubernetes side
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/testbed-loginnet apply

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable testbed-loginnet >/dev/null 2>&1
fi

# shellcheck disable=SC1090
source "$IPS"
nft delete table inet testbed-login 2>/dev/null || true
nft -f - <<RULES
table inet testbed-login {
  chain egress {
    type filter hook output priority 0; policy accept;
    ct state established,related accept
    ip daddr $ULISSES_IP tcp dport { 9000, 8099 } accept
    ip daddr $ULISSES_IP drop
  }
}
RULES
echo "login node isolated from ulisses ($ULISSES_IP)"
