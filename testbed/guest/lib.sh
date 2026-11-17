# shellcheck shell=bash
# Shared helpers for the guest scripts (sourced, not executed).
set -euo pipefail

TB=/opt/testbed
SLURM_VERSION=23.11.4
LISA_UID=2001
SLURM_UID=450
# Same project path as on Deucalion, so Isabel's scripts keep their defaults.
PROJECT_DIR=/projects/EEHPC-DEV-2026D02-075

log() { echo "[$(hostname -s) $(date +%H:%M:%S)] $*"; }

load_ips() {
  # shellcheck disable=SC1091
  source "$TB/state/ips.env"
}

# Replace the block between the testbed markers in a file with stdin.
put_block() {
  local file="$1" tmp
  tmp="$(mktemp)"
  touch "$file"
  awk '/^# BEGIN testbed$/{skip=1; next} /^# END testbed$/{skip=0; next} !skip' "$file" >"$tmp"
  { echo "# BEGIN testbed"; cat; echo "# END testbed"; } >>"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

install_hosts() {
  put_block /etc/hosts <"$TB/state/hosts"
  mkdir -p /etc/testbed
  cp "$TB/state/ips.env" /etc/testbed/ips.env
}

# Isabel's HPC project folder (her default, kept so her scripts need no path changes).
HPC_ROOT="$PROJECT_DIR/lisa-pipeline-runner"

# The only change made to Isabel's scripts: download the arm64 builds instead of x86_64.
patch_arch() {
  local d="$1"
  sed -i 's/_Linux_x86_64/_Linux_arm64/g' "$d/setup/kubernetes/3-bridge.sh" "$d/setup/hpc/1-bridge.sh"
  sed -i 's#/linux-amd64/mc#/linux-arm64/mc#g' "$d/setup/hpc/2-data.sh"
}

# Run a command as lisa in a real login session (needed for 'systemctl --user'). Root on login only.
lisa_ssh() {
  ssh -i "$TB/state/lisa_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR lisa@localhost "$@"
}

# interLink API -> tunnel endpoint. Must be the machine's own IP, as in Isabel's setup: interLink
# 0.6.1 refuses localhost/127.0.0.1 as sidecar URL ("potential SSRF detected"). Re-applied on every
# provision/refresh, so it also follows an IP change of ulisses. (root on ulisses)
il_set_sidecar_host() {
  local ip="$1" cfg=/opt/interlink/InterLinkConfig.yaml unit=/etc/systemd/system/interlink-tunnel.service
  [ -f "$cfg" ] && [ -f "$unit" ] || return 0
  if grep -q "^SidecarURL: \"http://$ip\"" "$cfg" && grep -q -- "-L $ip:5000:" "$unit"; then return 0; fi
  sed -i "s#^SidecarURL: .*#SidecarURL: \"http://$ip\"#" "$cfg"
  sed -i -E "s#-L [^ ]+:5000:localhost:#-L $ip:5000:localhost:#" "$unit"
  systemctl daemon-reload
  systemctl restart interlink-tunnel interlink-api
  sleep 2
  systemctl restart interlink-vk
  log "interLink sidecar endpoint set to http://$ip:5000"
}
