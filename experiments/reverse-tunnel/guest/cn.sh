#!/bin/bash
# Reverse-tunnel experiment, compute node (as root on cn): what the reverse tunnel needs there.
#   check    python3 (runs the job's relay) and an sshd binary (user-space sshd), as lisa
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
case "${1:-}" in
  check)
    ok=0
    p="$(sudo -u lisa bash -lc 'command -v python3' 2>/dev/null)"; [ -n "$p" ] && echo "PASS python3: $p ($(python3 --version 2>&1))" || { echo "FAIL no python3 for lisa"; ok=1; }
    [ -x /usr/sbin/sshd ] && echo "PASS sshd: /usr/sbin/sshd ($(ssh -V 2>&1))" || { echo "FAIL no /usr/sbin/sshd"; ok=1; }
    echo "INFO network mode: $(bash "$TB/guest/netmode.sh" get)"
    exit "$ok"
    ;;
  *) sed -n '2,4p' "$0"; exit 2;;
esac
