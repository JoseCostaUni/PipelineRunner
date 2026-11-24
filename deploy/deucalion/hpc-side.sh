#!/bin/bash
# Deucalion, HPC side. Runs on the login node (HPC_LOGIN_HOST) as HPC_USER, which runs our own interLink
# Slurm plugin (the "sidecar": user service SIDECAR_UNIT, files in HPC_PROJECT_ROOT) set up for interLink
# 0.6.3's reverse tunnel. No root, no site change. Usually called from Ulisses: 'k8s-side.sh hpc
# <command>'; 'k8s-side.sh up' runs install and images. See README.md in this folder.
#
#   check            read-only checks of what the reverse tunnel needs on this login node
#   probe-compute    a short Slurm job: what a compute node of SLURM_PARTITION can reach (expected on an
#                    air-gapped node: nothing outside Deucalion), and what the tunnel needs there:
#                    python3, sshd, and srun --overlap into the job
#   install          the sidecar: Slurm plugin IL_VERSION, the subPath fix as its sbatch, its
#                    configuration written from the settings, the user service SIDECAR_UNIT; restarts it
#                    when something changed. Run it again after changing the settings
#   uninstall        stop and remove the user service (files stay)
#   images           pull IMAGES and ARGO_EXEC_IMAGE into HPC_PROJECT_ROOT/images, one squashfs file each
#   status           what is configured and running now
#   state            print only: on (the sidecar runs) or off
#   evidence <since> <t0> <t1>  a tar.gz on stdout for 'k8s-side.sh evidence' (configuration, versions,
#                    Slurm's record of the jobs, the sidecar's log of the run)
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ZE="$(cd "$HERE/../.." && pwd)"
SPF_SRC="$ZE/setup/hpc/subpath-fix"
# Settings: deucalion.env next to this script, or the file named in TRIAL_ENV (the testbed rehearsal
# uses testbed.env).
ENV_FILE="${TRIAL_ENV:-${SPLIT_ENV:-$HERE/deucalion.env}}"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy deucalion.env.example)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
IL_VERSION="${IL_VERSION:-${REVERSE_IL_VERSION:-0.6.3}}"
# Our own service and port: a login node is shared, and another sidecar (Isabel's) may run there.
SIDECAR_UNIT="${SIDECAR_UNIT:-lisa-sidecar}"
SIDECAR_PORT="${SIDECAR_PORT:-4100}"
# systemctl --user from a non-interactive ssh session ('k8s-side.sh up') may not have it set.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

IL="$HPC_PROJECT_ROOT/.interlink"          # plugin, its configuration and log, the job folders
CFG="$IL/SlurmConfig.yaml"
RT="$HPC_PROJECT_ROOT/reverse-tunnel"      # the subPath fix, the capacity script, the socket folders
SOCK="$RT/sock"                            # the plugin's SocketDirRoot, shared with the compute nodes
RES="$RT/resources.sh"
IMG="$HPC_PROJECT_ROOT/images"
case "$(uname -m)" in aarch64|arm64) ARCH=arm64;; *) ARCH=x86_64;; esac
PLUGIN="$IL/interlink-sidecar-slurm-${IL_VERSION}_Linux_$ARCH"
PLUGIN_URL="https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/$IL_VERSION/interlink-sidecar-slurm_Linux_$ARCH"
UNIT_FILE="$HOME/.config/systemd/user/$SIDECAR_UNIT.service"

say()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
info() { printf 'INFO  %s\n' "$*"; }
key() { sed -n "s/^$1: *//p" "$2" | tr -d '"'; }
sidecar_bin() { systemctl --user show -p ExecStart "$SIDECAR_UNIT" 2>/dev/null | grep -o 'path=[^ ;]*' | head -n 1 | cut -d= -f2; }
running() { systemctl --user is-active --quiet "$SIDECAR_UNIT"; }
port_used() { ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}' | grep -q "[:.]$1\$"; }
settings() {
  grep -E '^(SbatchPath|CommandPrefix|ImagePrefix|SocketDirRoot|ResourceScriptPath):' "$CFG" 2>/dev/null
  sed -n '/^SingularityDefaultOptions:/,/^[A-Za-z]/p' "$CFG" 2>/dev/null | sed '$d'
}
# The plugin refuses a SocketDirRoot that is not an absolute path of letters, digits, '.', '_' and
# '-' with no element starting with '.', or that is longer than this.
sock_ok() { [[ "$SOCK" =~ ^(/[A-Za-z0-9_-][A-Za-z0-9._-]*)+$ ]] && [ "${#SOCK}" -le 79 ]; }
gs_url() { if [ "${GS_INSECURE:-true}" = true ]; then echo "http://$GS_ENDPOINT"; else echo "https://$GS_ENDPOINT"; fi; }

# The plugin's configuration: Isabel's (her setup/hpc/1-bridge.sh) without what only her prototype used
# (her data wrapper, the bind of her system data), set up for the reverse tunnel:
#   SbatchPath          the subPath fix, the one wrapper left (../../setup/hpc/subpath-fix/README.md)
#   --no-eval           Apptainer would evaluate every env value a second time and corrupt ARGO_TEMPLATE
#   --contain           each container gets its own /tmp, as in Kubernetes
#   ImagePrefix         the images pulled beforehand ('images'): compute nodes cannot pull
#   SocketDirRoot       where each job's tunnel sockets live (shared with the compute nodes)
#   ResourceScriptPath  a fixed capacity: plugin 0.6.3 reports the free memory it sees, which fell below
#                       one pod's request on the testbed and left pods Pending
write_config() {
  cat <<YAML
SidecarURL: "http://127.0.0.1"
SidecarPort: "$SIDECAR_PORT"
SbatchPath: "$RT/subpath-fix/sbatch"
ScancelPath: "$(command -v scancel)"
SqueuePath: "$(command -v squeue)"
SinfoPath: "$(command -v sinfo)"
CommandPrefix: ""
ImagePrefix: "$IMG/"
SingularityPath: "singularity"
SingularityPrefix: ""
SingularityDefaultOptions:
  - "--no-eval"
  - "--contain"
ExportPodData: true
DataRootFolder: "$IL/jobs/"
Namespace: "vk"
Tsocks: false
BashPath: /bin/bash
VerboseLogging: true
ErrorsOnlyLogging: false
EnableProbes: true
SocketDirRoot: "$SOCK"
ResourceScriptPath: "$RES"
YAML
}
write_unit() {
  cat <<UNIT
[Unit]
Description=interLink Slurm sidecar $IL_VERSION (LISA, deploy/deucalion)
After=network.target

[Service]
Environment=SLURMCONFIGPATH=$CFG
Environment=SHARED_FS=true
ExecStart=$PLUGIN
WorkingDirectory=$IL
Restart=always
RestartSec=5
StandardOutput=append:$IL/sidecar.log
StandardError=append:$IL/sidecar.log

[Install]
WantedBy=default.target
UNIT
}

case "${1:-}" in
  check)
    FAILED=0
    say "== login node $(hostname), user $(id -un), sidecar: $(running && echo running || echo not running)"
    [ "$(id -un)" = "$HPC_USER" ] && pass "running as HPC_USER" || fail "running as $(id -un), expected HPC_USER=$HPC_USER"
    mkdir -p "$HPC_PROJECT_ROOT" 2>/dev/null && [ -w "$HPC_PROJECT_ROOT" ] && pass "HPC_PROJECT_ROOT $HPC_PROJECT_ROOT writable" \
      || fail "cannot write to HPC_PROJECT_ROOT $HPC_PROJECT_ROOT"
    # -P: one line per file system even with a long name (Lustre). Images and job folders need room.
    avail="$(df -P "$HPC_PROJECT_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')"
    if [ -n "$avail" ] && [ "$avail" -lt 1048576 ]; then
      fail "only $((avail / 1024)) MB free on the file system of $HPC_PROJECT_ROOT ($(df -P "$HPC_PROJECT_ROOT" | awk 'NR == 2 {print $6}')): pick a HPC_PROJECT_ROOT elsewhere"
    else info "project file system: $(df -Ph "$HPC_PROJECT_ROOT" 2>/dev/null | awk 'NR == 2 {print $4 " free of " $2}')"; fi
    if running; then pass "$SIDECAR_UNIT is running ($(sidecar_bin))"
    else
      info "sidecar not running yet: 'install' sets it up ('k8s-side.sh up' runs it)"
      port_used "$SIDECAR_PORT" && fail "port $SIDECAR_PORT already in use on this node: pick another SIDECAR_PORT" \
        || pass "port $SIDECAR_PORT free for the sidecar"
    fi
    if [ -x "$PLUGIN" ]; then pass "Slurm plugin $IL_VERSION in $PLUGIN"
    else
      code="$(curl -sIL -m 15 -o /dev/null -w '%{http_code}' "$PLUGIN_URL" 2>/dev/null)"
      [ "$code" = 200 ] && pass "Slurm plugin $IL_VERSION can be downloaded" \
        || fail "Slurm plugin $IL_VERSION cannot be downloaded from here (HTTP '$code'): $PLUGIN_URL"
    fi
    systemctl --user show-environment >/dev/null 2>&1 && pass "systemctl --user works" \
      || fail "systemctl --user does not work here (the sidecar runs as a user service)"
    info "linger: $(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown) (no: the sidecar stops when your last session ends, and starts again with the next one, such as the tunnel from Ulisses)"
    sv="$(singularity --version 2>&1)"; info "container runtime: $sv"
    help="$(singularity exec --help 2>&1 || true)"
    case "$help" in *--no-eval*) pass "singularity exec has --no-eval";; *) fail "singularity exec has no --no-eval (needs Apptainer >= 1.1 or a SingularityCE that has it)";; esac
    case "$help" in *--contain*) pass "singularity exec has --contain";; *) fail "singularity exec has no --contain";; esac
    for t in bash sed awk grep curl sbatch squeue scancel sinfo srun; do
      command -v "$t" >/dev/null 2>&1 && pass "found $t" || fail "missing $t"
    done
    command -v mksquashfs >/dev/null 2>&1 && pass "found mksquashfs (images are packed with it)" \
      || info "no mksquashfs: 'images' falls back to singularity pull"
    if sinfo -h -p "$SLURM_PARTITION" -o '%P' 2>/dev/null | grep -q .; then pass "partition $SLURM_PARTITION exists"
    else fail "partition $SLURM_PARTITION not found; partitions: $(sinfo -h -o '%P' | tr '\n' ' ')"; fi
    squeue -h --me -o %i >/dev/null 2>&1 && pass "squeue --me works (the shadow finds the job with it)" \
      || fail "squeue --me fails (the shadow finds the job with it; Slurm older than 20.11?)"
    [ -d "$SPF_SRC" ] && pass "subPath fix sources in $SPF_SRC" || fail "no $SPF_SRC"
    sock_ok && pass "SocketDirRoot $SOCK (${#SOCK} bytes)" \
      || fail "SocketDirRoot $SOCK: the plugin wants at most 79 bytes of letters, digits, '.', '_', '-', no element starting with '.'"
    info "the Global Storage and the Kubernetes API are reached from Ulisses through the tunnel, not from here"
    info "python3, sshd and srun --overlap on a compute node: run ./hpc-side.sh probe-compute"
    exit "$FAILED"
    ;;

  probe-compute)
    out="$HPC_PROJECT_ROOT/probe-compute.out"
    rm -f "$out"
    gs="$(gs_url)"
    jid="$(sbatch --parsable -p "$SLURM_PARTITION" -A "$SLURM_ACCOUNT" -t 3 -J trial-probe -o "$out" --wrap "
      echo \"node: \$(hostname)\"
      for u in $gs/minio/health/live https://$K8S_API_HOST:$K8S_API_PORT/version https://quay.io https://pypi.org; do
        c=\$(curl -sk -m 8 -o /dev/null -w '%{http_code}' \"\$u\" 2>/dev/null); echo \"\$u -> HTTP \${c:-none}\"
      done
      getent hosts quay.io >/dev/null && echo 'DNS: resolves quay.io' || echo 'DNS: cannot resolve quay.io'
      [ -d '$HPC_PROJECT_ROOT' ] && echo 'shared FS: $HPC_PROJECT_ROOT visible' || echo 'shared FS: NOT visible'
      p=\$(command -v python3) && echo \"python3: \$p, \$(python3 --version 2>&1)\" || echo 'python3: NOT found'
      [ -x /usr/sbin/sshd ] && echo 'sshd: /usr/sbin/sshd' || echo 'sshd: NOT found at /usr/sbin/sshd'
      echo 'probe: done'
      sleep 90
    ")" || { say "ERROR: sbatch failed: $jid"; exit 1; }
    jid="${jid%%;*}"
    say "job $jid submitted to $SLURM_PARTITION; waiting for it (Ctrl-C leaves it running; output in $out)"
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
    say "Expected on an air-gapped node: every URL 'none' or 000, the shared FS visible."
    say "The reverse tunnel also needs python3 (3.6 or newer), /usr/sbin/sshd and srun --overlap working."
    ;;

  install)
    case "$HPC_PROJECT_ROOT" in /*) ;; *) say "ERROR: HPC_PROJECT_ROOT must be an absolute path; it is '$HPC_PROJECT_ROOT'"; exit 1;; esac
    sock_ok || { say "ERROR: SocketDirRoot $SOCK is not valid for the plugin; see 'check'"; exit 1; }
    [ -d "$SPF_SRC" ] || { say "ERROR: no $SPF_SRC"; exit 1; }
    running || ! port_used "$SIDECAR_PORT" || { say "ERROR: port $SIDECAR_PORT already in use on this node: pick another SIDECAR_PORT (both sides read it)"; exit 1; }
    mkdir -p "$IL/jobs" "$RT" "$SOCK"; chmod 0700 "$SOCK"
    if [ ! -x "$PLUGIN" ]; then
      say "download Slurm plugin $IL_VERSION: $PLUGIN_URL"
      curl -fsSL --retry 3 -o "$PLUGIN.dl" "$PLUGIN_URL" && chmod 0755 "$PLUGIN.dl" && mv -f "$PLUGIN.dl" "$PLUGIN" \
        || { rm -f "$PLUGIN.dl"; say "ERROR: download failed"; exit 1; }
    fi
    # The one wrapper left: the plugin ignores subPath on emptyDirs (setup/hpc/subpath-fix/README.md).
    rm -rf "$RT/subpath-fix"; cp -r "$SPF_SRC" "$RT/subpath-fix"; chmod 0755 "$RT/subpath-fix/sbatch"
    printf 'REAL_SBATCH=%s\n' "$(command -v sbatch)" >"$RT/subpath-fix/subpath-fix.conf"
    printf '#!/bin/sh\necho %s\n' "'{\"status\":\"ok\",\"resources\":{\"cpu\":\"100\",\"memory\":\"3T\",\"pods\":\"10k\"}}'" >"$RES"
    chmod 0755 "$RES"
    # Written from the settings every time; restart only when something changed.
    changed=0
    write_config >"$CFG.new"; cmp -s "$CFG.new" "$CFG" && rm -f "$CFG.new" || { mv -f "$CFG.new" "$CFG"; changed=1; }
    mkdir -p "$(dirname "$UNIT_FILE")"
    write_unit >"$UNIT_FILE.new"; cmp -s "$UNIT_FILE.new" "$UNIT_FILE" && rm -f "$UNIT_FILE.new" || { mv -f "$UNIT_FILE.new" "$UNIT_FILE"; changed=1; }
    # Drop-ins of the earlier, two-mode version of these scripts would override ExecStart.
    [ -d "$UNIT_FILE.d" ] && { rm -rf "$UNIT_FILE.d"; changed=1; }
    loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -q yes \
      || loginctl enable-linger "$(id -un)" >/dev/null 2>&1 \
      || info "could not enable linger (not allowed here): the sidecar runs while you have a session, such as the tunnel from Ulisses"
    systemctl --user daemon-reload
    systemctl --user enable "$SIDECAR_UNIT" >/dev/null 2>&1
    if [ "$changed" = 1 ] || ! running; then
      systemctl --user restart "$SIDECAR_UNIT"; sleep 8
    fi
    running || { say "ERROR: $SIDECAR_UNIT does not start; last log lines:"; tail -n 20 "$IL/sidecar.log"; exit 1; }
    say "sidecar running: $SIDECAR_UNIT, plugin $IL_VERSION, port $SIDECAR_PORT$([ "$changed" = 1 ] && echo ", configuration updated")"
    settings
    ;;

  uninstall)
    systemctl --user disable --now "$SIDECAR_UNIT" >/dev/null 2>&1
    rm -f "$UNIT_FILE"; rm -rf "$UNIT_FILE.d"; systemctl --user daemon-reload
    say "sidecar $SIDECAR_UNIT stopped and its service removed; the files stay in $HPC_PROJECT_ROOT"
    ;;

  images)
    mkdir -p "$IMG"
    # Each image is unpacked in the login node's local /tmp and packed into one squashfs file, which
    # singularity runs like a SIF. 'singularity pull' fails on Deucalion: its mksquashfs starts one
    # thread per CPU (256) and a user may run 150 ('Failed to create thread'). Calling mksquashfs
    # ourselves sets the thread count, and one file is fast to write on NFS, unlike an unpacked image.
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
      [ "$rc" -eq 0 ] || { tail -n 5 "$tmp/log"; rm -rf "$tmp" "$dest.part"; say "ERROR: pull of $ref failed"; exit 1; }
      rm -rf "$tmp"
    done
    chmod -R a+rX "$IMG"
    find "$IMG" -type f -printf '%10s  %p\n'
    ;;

  status)
    say "== sidecar $SIDECAR_UNIT: $(systemctl --user is-active "$SIDECAR_UNIT" 2>&1) ($(sidecar_bin)), port $SIDECAR_PORT"
    settings
    say "== images in $IMG:"; find "$IMG" -type f -printf '   %p\n' 2>/dev/null
    say "== Slurm jobs of $(id -un):"; squeue -h -u "$(id -un)" -o '   %i %P %j %T %M' 2>/dev/null
    jr="$(key DataRootFolder "$CFG" 2>/dev/null)"
    n="$(ls -d "$jr"*/ 2>/dev/null | wc -l)"; say "== job folders in $jr: $n (they hold data, keys and tokens while a pod runs)"
    say "== tunnel socket folders in $SOCK: $(ls "$SOCK" 2>/dev/null | wc -l)"
    ;;

  state) if running && [ -f "$CFG" ]; then echo on; else echo off; fi ;;

  evidence)
    # A tar.gz on stdout with what shows how a run went on this side, for 'k8s-side.sh evidence':
    # configuration, versions (checksum against the release's), Slurm's record of the jobs, the
    # sidecar's log lines of the run (UTC window). Its log holds no secret values; tokens are blanked
    # anyway.
    since="${2:?start, local time}"; t0="${3:?start, UTC}"; t1="${4:?end, UTC}"
    tmp="$(mktemp -d /tmp/lisa-ev.XXXXXX)"; d="$tmp/login-node"; mkdir -p "$d"
    cp -p "$CFG" "$d/SlurmConfig.yaml" 2>/dev/null
    systemctl --user cat "$SIDECAR_UNIT" >"$d/sidecar-unit.txt" 2>&1
    {
      echo "host: $(hostname), user: $(id -un), sidecar now: $(running && echo running || echo not running), binary: $(sidecar_bin)"
      [ -f "$PLUGIN" ] && sha256sum "$PLUGIN"
      s="$(curl -fsSL -m 20 "https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/$IL_VERSION/checksums.txt" 2>/dev/null | grep "_Linux_$ARCH\$")"
      echo "release $IL_VERSION, published checksum: ${s:-not available}"
      singularity --version
      sinfo -V
    } >"$d/versions.txt" 2>&1
    sacct -X -P -S "$since" -o JobID,JobName,Partition,NodeList,State,Start,End,Elapsed >"$d/slurm-jobs.txt" 2>&1 \
      || squeue --me -h -t all -o '%i|%j|%P|%N|%T' >"$d/slurm-jobs.txt" 2>&1
    cp -p "$HPC_PROJECT_ROOT/probe-compute.out" "$d/" 2>/dev/null
    awk -v a="$t0" -v b="$t1" 'match($0, /time="[^"]*"/) { t = substr($0, RSTART + 6, 19); if (t >= a && t <= b) print }' "$IL/sidecar.log" 2>/dev/null \
      | sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<token>/g' >"$d/sidecar.log"
    tar -C "$tmp" -cz login-node
    rm -rf "$tmp"
    ;;

  *) awk 'NR > 1 && !/^#/ {exit} NR > 1' "$0"; exit 2;;
esac
