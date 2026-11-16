# shellcheck shell=bash
# Shared by the guest scripts of the reverse-tunnel experiment (sourced). Builds on the testbed's
# own helpers (/opt/testbed/guest/lib.sh: TB, HPC_ROOT, log, load_ips, lisa_ssh, ...).
# shellcheck disable=SC1091
source /opt/testbed/guest/lib.sh
# shellcheck disable=SC2034  # used by the scripts that source this file
RT=/opt/rt                                      # this experiment's files in the VM
IL_VERSION="${IL_VERSION:-0.6.3}"               # interLink and Slurm plugin version under test
# shellcheck disable=SC2034
SSH_TUNNEL_IMAGE="ghcr.io/interlink-hq/interlink/ssh-tunnel:$IL_VERSION"
