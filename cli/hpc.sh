#!/bin/bash
# The HPC side of the LISA pipeline runner. Runs on the login node as HPC_USER, which runs our own
# interLink Slurm plugin (the "sidecar") as a user service. No root, no site change. The login node has
# no Python, hence bash; everything here is called from the Kubernetes side ('lisa', over SSH), which
# also fills in every file this installs and copies them, with this script, to HPC_PROJECT_ROOT/runner.
#
#   check             read-only checks of what the runner needs on this login node
#   probe             a short Slurm job: what a compute node of SLURM_PARTITION can reach (on an offline
#                     node: nothing outside the HPC system) and what the tunnel needs there (python3,
#                     sshd, srun --overlap into the job)
#   install           the sidecar: the plugin IL_VERSION, its configuration, the subPath fix and the user
#                     service SIDECAR_UNIT; restarts it when something changed
#   uninstall         stop and remove the user service (the files stay)
#   images            build IMAGES and ARGO_EXEC_IMAGE into images/ (IMAGE_MIRROR=off), one file each
#   status | state    what runs now | only 'on' or 'off'
#   jobs              Slurm's record of our recent jobs: name|id|partition|nodes|state
#   evidence <since> <t0> <t1>   a tar.gz on stdout: configuration, versions, Slurm's record, the log
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/hpc.env" || { echo "no $HERE/hpc.env: run 'lisa sync'" >&2; exit 1; }
ROOT="$HPC_PROJECT_ROOT"
SIDECAR="$ROOT/sidecar"          # the plugin, its configuration and log, the job folders
SOCK="$ROOT/sock"                # the plugin's SocketDirRoot, shared with the compute nodes
IMG="$ROOT/images"
UNIT_FILE="$HOME/.config/systemd/user/$SIDECAR_UNIT.service"
PLUGIN_URL="https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/$IL_VERSION/$(basename "$PLUGIN" | sed "s/-$IL_VERSION//")"
# systemctl --user from a non-interactive SSH session may not have it set.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

say()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
info() { printf 'INFO  %s\n' "$*"; }
running() { systemctl --user is-active --quiet "$SIDECAR_UNIT"; }
port_used() { ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}' | grep -q "[:.]$1\$"; }
# The plugin refuses a SocketDirRoot that is not an absolute path of letters, digits, '.', '_' and '-'
# with no element starting with '.', or that is longer than 79 bytes.
sock_ok() { [[ "$SOCK" =~ ^(/[A-Za-z0-9_-][A-Za-z0-9._-]*)+$ ]] && [ "${#SOCK}" -le 79 ]; }
# Copy src to dest only if it differs; status 0 when it changed.
install_changed() { cmp -s "$1" "$2" && return 1; install -m "${3:-0644}" -D "$1" "$2"; }
# The plugin's log lines of a time window (UTC), with any service-account token blanked.
log_window() {
  awk -v a="$1" -v b="$2" 'match($0, /time="[^"]*"/) { t = substr($0, RSTART + 6, 19); if (t >= a && t <= b) print }' "$3" \
    | sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<token>/g'
}

cmd_check() {
  FAILED=0
  say "== login node $(hostname), user $(id -un), sidecar: $(running && echo running || echo not running)"
  [ "$(id -un)" = "$HPC_USER" ] && pass "running as HPC_USER" || fail "running as $(id -un), expected HPC_USER=$HPC_USER"
  [ -w "$ROOT" ] && pass "HPC_PROJECT_ROOT $ROOT writable" || fail "cannot write to HPC_PROJECT_ROOT $ROOT"
  # -P: one line per file system even with a long name (Lustre). Images and job folders need room.
  avail="$(df -P "$ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [ -n "$avail" ] && [ "$avail" -lt 1048576 ]; then
    fail "only $((avail / 1024)) MB free on the file system of $ROOT: pick a HPC_PROJECT_ROOT elsewhere"
  else info "project file system: $(df -Ph "$ROOT" 2>/dev/null | awk 'NR == 2 {print $4 " free of " $2}')"; fi
  if running; then pass "$SIDECAR_UNIT is running"
  elif port_used "$SIDECAR_PORT"; then fail "port $SIDECAR_PORT already in use on this node: pick another SIDECAR_PORT"
  else pass "port $SIDECAR_PORT free for the sidecar"; fi
  if [ -x "$PLUGIN" ]; then pass "Slurm plugin $IL_VERSION in $PLUGIN"
  else
    code="$(curl -sIL -m 15 -o /dev/null -w '%{http_code}' "$PLUGIN_URL" 2>/dev/null)"
    [ "$code" = 200 ] && pass "Slurm plugin $IL_VERSION can be downloaded" \
      || fail "Slurm plugin $IL_VERSION cannot be downloaded from here (HTTP '$code'): $PLUGIN_URL"
  fi
  systemctl --user show-environment >/dev/null 2>&1 && pass "systemctl --user works" \
    || fail "systemctl --user does not work here (the sidecar runs as a user service)"
  info "linger: $(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown) (without it, the sidecar runs only while you have a session here, such as the tunnel from the Kubernetes side)"
  info "container runtime: $(singularity --version 2>&1)"
  help="$(singularity exec --help 2>&1 || true)"
  for o in --no-eval --contain; do
    case "$help" in *"$o"*) pass "singularity exec has $o";; *) fail "singularity exec has no $o (needs Apptainer 1.1 or newer)";; esac
  done
  if [ "$IMAGE_MIRROR" = on ]; then
    case "$help" in *--no-https*) pass "singularity exec has --no-https (the image mirror speaks HTTP)";;
      *) fail "singularity exec has no --no-https: the image mirror (IMAGE_MIRROR=on) cannot be used";; esac
  fi
  for t in curl sbatch squeue scancel sinfo srun; do command -v "$t" >/dev/null 2>&1 && pass "found $t" || fail "missing $t"; done
  command -v mksquashfs >/dev/null 2>&1 && pass "found mksquashfs (images are packed with it)" \
    || info "no mksquashfs: 'images' falls back to singularity pull"
  if sinfo -h -p "$SLURM_PARTITION" -o '%P' 2>/dev/null | grep -q .; then
    pass "partition $SLURM_PARTITION exists"
    info "partition $SLURM_PARTITION: $(scontrol show partition "$SLURM_PARTITION" 2>/dev/null | grep -o -E '(OverSubscribe|ExclusiveUser)=[^ ]*' | tr '\n' ' ')"
    # With the image mirror every pod's relay takes the same address, so Slurm must end a job's relay
    # with the job: proctrack/cgroup does, proctrack/linuxproc loses it (seen on the testbed).
    pt="$(scontrol show config 2>/dev/null | sed -n 's/^ProctrackType *= *//p')"
    if [ "$IMAGE_MIRROR" != on ]; then info "ProctrackType ${pt:-unknown}"
    elif [ "$pt" = proctrack/cgroup ]; then pass "ProctrackType $pt: a job's relay ends with the job (the image mirror's fixed address)"
    else fail "ProctrackType ${pt:-unknown}: a finished job's relay can outlive it and hold the image mirror's fixed address; use IMAGE_MIRROR=off here"; fi
  else fail "partition $SLURM_PARTITION not found; partitions: $(sinfo -h -o '%P' | tr '\n' ' ')"; fi
  squeue -h --me -o %i >/dev/null 2>&1 && pass "squeue --me works (the shadow finds the job with it)" \
    || fail "squeue --me fails (the shadow finds the job with it; Slurm older than 20.11?)"
  sock_ok && pass "SocketDirRoot $SOCK (${#SOCK} bytes)" \
    || fail "SocketDirRoot $SOCK: the plugin wants at most 79 bytes of letters, digits, '.', '_', '-', no element starting with '.'"
  info "python3, sshd and srun --overlap on a compute node: see the probe"
  return "$FAILED"
}

cmd_probe() {
  out="$ROOT/probe-compute.out"
  rm -f "$out"
  jid="$(sbatch --parsable -p "$SLURM_PARTITION" -A "$SLURM_ACCOUNT" -t 3 -J lisa-probe -o "$out" --wrap "
    echo \"node: \$(hostname)\"
    for u in $PROBE_URLS; do
      c=\$(curl -sk -m 8 -o /dev/null -w '%{http_code}' \"\$u\" 2>/dev/null); echo \"\$u -> HTTP \${c:-none}\"
    done
    getent hosts quay.io >/dev/null && echo 'DNS: resolves quay.io' || echo 'DNS: cannot resolve quay.io'
    [ -d '$ROOT' ] && echo 'shared FS: $ROOT visible' || echo 'shared FS: NOT visible'
    p=\$(command -v python3) && echo \"python3: \$p, \$(python3 --version 2>&1)\" || echo 'python3: NOT found'
    [ -x /usr/sbin/sshd ] && echo 'sshd: /usr/sbin/sshd' || echo 'sshd: NOT found at /usr/sbin/sshd'
    cg=\$(sed -n 's/^0:://p' /proc/self/cgroup)
    echo \"CPUs: \$(nproc) for the job, \$(getconf _NPROCESSORS_ONLN) on the node; processes: ulimit -u \$(ulimit -u), cgroup pids.max \$(cat /sys/fs/cgroup\$cg/pids.max 2>/dev/null || echo unknown)\"
    echo 'probe: done'
    sleep 90
  ")" || { say "ERROR: sbatch failed: $jid"; return 1; }
  jid="${jid%%;*}"
  say "job $jid submitted to $SLURM_PARTITION; waiting for it (output in $out)"
  while st="$(squeue -h -j "$jid" -o %T 2>/dev/null)" && [ -n "$st" ] && [ "$st" != RUNNING ]; do sleep 5; done
  ov="not tried: the job ended before it was seen running"
  if [ "$st" = RUNNING ]; then
    for _ in $(seq 1 30); do grep -q '^probe: done' "$out" 2>/dev/null && break; sleep 2; done
    # What the reverse tunnel's shadow does to reach the job (Reverse.NodeExec: srun).
    if o="$(timeout 60 srun --jobid="$jid" --overlap -u -n1 --cpus-per-task=1 /bin/sh -c 'echo "reached $(hostname)"' 2>&1)"; then
      ov="works ($o)"
    else ov="FAILED: $(printf '%s' "$o" | tail -n 2 | tr '\n' ' ')"; fi
    scancel "$jid" 2>/dev/null
  fi
  while squeue -h -j "$jid" 2>/dev/null | grep -q .; do sleep 3; done
  grep -v -e '^probe: done' -e "JOB $jid ON .* CANCELLED" "$out"   # we cancel it ourselves
  say "srun --overlap into the job: $ov"
  say "Expected on an offline node: every URL 'none' or 000, the shared FS visible, python3 (3.6 or newer),"
  say "/usr/sbin/sshd, and srun --overlap working. With the image mirror, Singularity converts each new"
  say "image in the job, and its mksquashfs may start one thread per CPU: the process limit must allow that."
}

cmd_install() {
  sock_ok || { say "ERROR: SocketDirRoot $SOCK is not valid for the plugin; see 'check'"; return 1; }
  running || ! port_used "$SIDECAR_PORT" || { say "ERROR: port $SIDECAR_PORT already in use on this node: pick another SIDECAR_PORT"; return 1; }
  mkdir -p "$SIDECAR/jobs" "$SOCK" && chmod 0700 "$SOCK"
  if [ ! -x "$PLUGIN" ]; then
    say "download Slurm plugin $IL_VERSION: $PLUGIN_URL"
    curl -fsSL --retry 3 -o "$PLUGIN.part" "$PLUGIN_URL" && chmod 0755 "$PLUGIN.part" && mv -f "$PLUGIN.part" "$PLUGIN" \
      || { rm -f "$PLUGIN.part"; say "ERROR: download failed"; return 1; }
  fi
  changed=0
  install_changed "$HERE/sbatch" "$SIDECAR/subpath-fix/sbatch" 0755 && changed=1
  printf 'REAL_SBATCH=%s\n' "$(command -v sbatch)" >"$SIDECAR/subpath-fix/subpath-fix.conf"
  install_changed "$HERE/resources.sh" "$SIDECAR/resources.sh" 0755 && changed=1
  install_changed "$HERE/SlurmConfig.yaml" "$SIDECAR/SlurmConfig.yaml" && changed=1
  install_changed "$HERE/$SIDECAR_UNIT.service" "$UNIT_FILE" && changed=1
  loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -q yes \
    || loginctl enable-linger "$(id -un)" >/dev/null 2>&1 \
    || info "could not enable linger (not allowed here): the sidecar runs while you have a session here"
  systemctl --user daemon-reload
  systemctl --user enable "$SIDECAR_UNIT" >/dev/null 2>&1
  if [ "$changed" = 1 ] || ! running; then systemctl --user restart "$SIDECAR_UNIT"; sleep 8; fi
  running || { say "ERROR: $SIDECAR_UNIT does not start; the end of its log:"; tail -n 20 "$SIDECAR/sidecar.log"; return 1; }
  say "sidecar running: $SIDECAR_UNIT, plugin $IL_VERSION, port $SIDECAR_PORT$([ "$changed" = 1 ] && echo ", configuration updated")"
}

cmd_uninstall() {
  systemctl --user disable --now "$SIDECAR_UNIT" >/dev/null 2>&1
  rm -f "$UNIT_FILE"; systemctl --user daemon-reload
  say "sidecar $SIDECAR_UNIT stopped and its service removed; the files stay in $ROOT"
}

cmd_images() {
  if [ "$IMAGE_MIRROR" = on ]; then say "IMAGE_MIRROR=on: the jobs pull every image from the image mirror; nothing to build here"; return 0; fi
  mkdir -p "$IMG"
  # Each image is unpacked in the login node's local /tmp and packed into one squashfs file, which
  # singularity runs like a SIF. 'singularity pull' fails on Deucalion: its mksquashfs starts one thread
  # per CPU (256), and a user may run 150 ('Failed to create thread'). Calling mksquashfs ourselves sets
  # the thread count, and one file is fast to write on NFS, unlike an unpacked image.
  sq="$(command -v mksquashfs || true)"
  for ref in $IMAGES $ARGO_EXEC_IMAGE; do
    dest="$IMG/$ref"
    mkdir -p "$(dirname "$dest")"
    if [ -s "$dest" ]; then say "have  $ref"; continue; fi
    say "pull  $ref"
    tmp="$(mktemp -d /tmp/lisa-img.XXXXXX)"; mkdir -p "$tmp/cache" "$tmp/tmp"
    export SINGULARITY_CACHEDIR="$tmp/cache" SINGULARITY_TMPDIR="$tmp/tmp" APPTAINER_CACHEDIR="$tmp/cache" APPTAINER_TMPDIR="$tmp/tmp"
    if [ -n "$sq" ]; then
      singularity build --fix-perms --sandbox "$tmp/root" "docker://$ref" >"$tmp/log" 2>&1 \
        && "$sq" "$tmp/root" "$dest.part" -noappend -all-root -processors 4 >>"$tmp/log" 2>&1 \
        && mv -f "$dest.part" "$dest"
    else
      singularity pull "$dest" "docker://$ref" >"$tmp/log" 2>&1
    fi
    rc=$?
    [ "$rc" -eq 0 ] || { tail -n 5 "$tmp/log"; rm -rf "$tmp" "$dest.part"; say "ERROR: pull of $ref failed"; return 1; }
    rm -rf "$tmp"
  done
  chmod -R a+rX "$IMG"
  find "$IMG" -type f -printf '%10s  %p\n'
}

cmd_status() {
  say "sidecar $SIDECAR_UNIT: $(systemctl --user is-active "$SIDECAR_UNIT" 2>&1), plugin $IL_VERSION, port $SIDECAR_PORT"
  grep -E '^(SbatchPath|ImagePrefix|SocketDirRoot):' "$SIDECAR/SlurmConfig.yaml" 2>/dev/null | sed 's/^/  /'
  say "images in $IMG: $(find "$IMG" -type f 2>/dev/null | wc -l)"
  say "Slurm jobs of $(id -un):"; squeue -h -u "$(id -un)" -o '  %i %P %j %T %M' 2>/dev/null
  say "job folders in $SIDECAR/jobs: $(find "$SIDECAR/jobs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) (they hold data, keys and tokens while a pod runs)"
  say "tunnel socket folders in $SOCK: $(find "$SOCK" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
}

cmd_jobs() {
  # squeue keeps finished jobs for a few minutes, sacct (where the site keeps accounting) for longer.
  squeue --me -h -t all -o '%j|%i|%P|%N|%T' 2>/dev/null
  sacct -X -n -P -S now-2days -o JobName,JobID,Partition,NodeList,State 2>/dev/null
  return 0
}

cmd_evidence() {
  since="${1:?start, local time}"; t0="${2:?start, UTC}"; t1="${3:?end, UTC}"
  tmp="$(mktemp -d /tmp/lisa-ev.XXXXXX)"; d="$tmp/login-node"; mkdir -p "$d"
  cp -p "$SIDECAR/SlurmConfig.yaml" "$d/" 2>/dev/null
  systemctl --user cat "$SIDECAR_UNIT" >"$d/sidecar-unit.txt" 2>&1
  {
    echo "host: $(hostname), user: $(id -un), sidecar now: $(running && echo running || echo not running)"
    [ -f "$PLUGIN" ] && sha256sum "$PLUGIN"
    s="$(curl -fsSL -m 20 "https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/$IL_VERSION/checksums.txt" 2>/dev/null | grep "$(basename "$PLUGIN_URL")\$")"
    echo "release $IL_VERSION, published checksum: ${s:-not available}"
    singularity --version
    sinfo -V
  } >"$d/versions.txt" 2>&1
  sacct -X -P -S "$since" -o JobID,JobName,Partition,NodeList,State,Start,End,Elapsed >"$d/slurm-jobs.txt" 2>&1 \
    || squeue --me -h -t all -o '%i|%j|%P|%N|%T' >"$d/slurm-jobs.txt" 2>&1
  cp -p "$ROOT/probe-compute.out" "$d/" 2>/dev/null
  log_window "$t0" "$t1" "$SIDECAR/sidecar.log" >"$d/sidecar.log" 2>/dev/null
  tar -C "$tmp" -cz login-node
  rm -rf "$tmp"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  check|probe|install|uninstall|images|status|jobs|evidence) "cmd_$cmd" "$@" ;;
  state) if running && [ -f "$SIDECAR/SlurmConfig.yaml" ]; then echo on; else echo off; fi ;;
  *) sed -n '2,/^set -o/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
