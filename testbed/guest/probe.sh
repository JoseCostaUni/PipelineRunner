#!/bin/bash
# Small probes used by './testbed check'. Exit code 0 = the probe succeeded.
set -uo pipefail
SIF=/projects/.testbed/lisa/alpine.sif
IMG=docker://alpine:3.20
KEY="$HOME/.ssh/id_ed25519"
SSHO="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

# Submit a job from the login node, wait for it, print its output, return its exit code.
job() {
  local out rc
  out="$(mktemp -p "$HOME" .tb-job.XXXXXX)"
  timeout 600 sbatch --wait --quiet -o "$out" -e "$out" --wrap "$1"
  rc=$?
  tail -n 5 "$out"
  rm -f "$out"
  return "$rc"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  internet) curl -sS -m 8 -o /dev/null -w '%{http_code}\n' https://github.com;;
  dns) getent hosts github.com;;
  reach) ping -c 1 -W 2 "$1" >/dev/null && echo "reached $1";;
  sudo) sudo -n true 2>&1;;
  prepdirs) mkdir -p /projects/.testbed/lisa /projects/.testbed/ino && chown lisa:lisa /projects/.testbed/lisa && chmod 1777 /projects/.testbed/ino;;
  write) echo "$2" >"$1";;
  readeq) got="$(cat "$1")"; echo "read: $got"; [ "$got" = "$2" ];;
  exists) ls -l "$1";;
  touch) touch "$1";;
  rmdir-contents) rm -f "$1"/*;;
  inotify)
    inotifywait -q -t "$2" -e create -e moved_to -e close_write "$1" >/dev/null 2>&1
    case $? in 0) echo EVENT;; 2) echo NOEVENT;; *) echo ERROR; exit 1;; esac;;
  epoch) date +%s;;
  ssh-local) ssh $SSHO -i "$KEY" -o ExitOnForwardFailure=yes -L 127.0.0.1:19998:localhost:22 lisa@localhost true && echo "ssh -L accepted";;
  ssh-remote) ssh $SSHO -i "$KEY" -o ExitOnForwardFailure=yes -R 127.0.0.1:19999:localhost:22 lisa@localhost true && echo "ssh -R accepted";;
  sinfo) out="$(sinfo -h -o '%P %a %T %N')"; echo "$out"; echo "$out" | grep -Eq '^arm\*? up (idle|mixed|allocated)';;
  job-hostname) job 'hostname -s';;
  pull-sif) singularity pull --force "$SIF" "$IMG" >/dev/null 2>&1 && ls -l "$SIF";;
  job-sif) job "singularity exec $SIF cat /etc/alpine-release";;
  job-docker) job "singularity exec $IMG cat /etc/alpine-release";;
  http) curl -sk -m 5 -o /dev/null -w '%{http_code}\n' "$1";;
  tcp) timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null && echo "tcp $1:$2 open" || { echo "tcp $1:$2 closed"; exit 1; };;
  ssh-lisa) ssh $SSHO -i "${2:-$KEY}" "lisa@$1" 'echo "ssh into $(hostname -s) ok"';;
  k8s-node)
    st="$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get node interlink-node \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [ "$st" = True ] && echo Ready;;
  *) echo "unknown probe: $cmd" >&2; exit 2;;
esac
