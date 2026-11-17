#!/bin/bash
# Run as lisa on the login node (from login-b.sh). Usage: lisa-hpc.sh HPC_ROOT
set -euo pipefail
HPC_ROOT="$1"

rm -rf "$HOME/lisa-pipeline-runner"
cp -r /var/tmp/lpr "$HOME/lisa-pipeline-runner"
cd "$HOME/lisa-pipeline-runner/setup/hpc"
cp .env.example .env
cat /var/tmp/hpc.env >>.env

# Initial state of the HPC data folder. Her sidecar config bind-mounts data/users/system into every
# job, and the wrapper bind-mounts data/users/<user>, so these folders must exist (on Deucalion they
# existed from earlier use).
mkdir -p "$HPC_ROOT/data/users/admin" "$HPC_ROOT/data/users/alice" "$HPC_ROOT/data/users/system"

if systemctl --user is-active -q interlink-sidecar; then
  echo "interlink-sidecar already running"
else
  bash main.sh
fi
sleep 3
systemctl --user --no-pager status interlink-sidecar | head -n 5
