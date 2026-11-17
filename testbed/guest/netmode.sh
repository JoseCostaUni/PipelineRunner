#!/bin/bash
# Network mode of the compute node. Usage: netmode.sh dev|normal|apply|get|status   (as root, on cn)
#   dev     internet allowed (like Deucalion dev-x86 / dev-arm since Feb 2025)
#   normal  only the cluster network: the login node (NFS, Slurm, SSH, time). No internet,
#           no DNS, no Kubernetes side, no object storage (like Deucalion normal-* partitions)
# The mode is stored in /etc/testbed/netmode and re-applied at boot by testbed-netmode.service.
set -euo pipefail
STATEFILE=/etc/testbed/netmode
IPS=/etc/testbed/ips.env
ACTION="${1:-apply}"

case "$ACTION" in
  dev|normal) mkdir -p /etc/testbed; echo "$ACTION" >"$STATEFILE";;
  apply) ;;
  get) cat "$STATEFILE" 2>/dev/null || echo dev; exit 0;;
  status)
    echo "mode: $(cat "$STATEFILE" 2>/dev/null || echo dev)"
    nft list table inet testbed 2>/dev/null || echo "(no rules loaded)"
    exit 0;;
  *) echo "usage: $0 dev|normal|apply|get|status" >&2; exit 2;;
esac

MODE="$(cat "$STATEFILE" 2>/dev/null || echo dev)"
# shellcheck disable=SC1090
source "$IPS"
if [ "$MODE" = normal ]; then POLICY=drop; else POLICY=accept; fi

# The table exists in both modes so that connection tracking is always on. A connection opened
# in dev mode (for example Lima's own SSH session into this VM) is then already known as
# 'established' when the node switches to normal, instead of having its replies dropped.
# 'tcp sport 22' keeps replies of the SSH server flowing in any case.
nft delete table inet testbed 2>/dev/null || true
nft -f - <<RULES
table inet testbed {
  chain egress {
    type filter hook output priority 0; policy $POLICY;
    oifname "lo" accept
    ct state established,related accept
    tcp sport 22 accept
    ip daddr { $LOGIN_IP, $CN_IP } accept
  }
}
RULES
echo "$MODE"
