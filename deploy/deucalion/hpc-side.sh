#!/bin/bash
# Deucalion trial, HPC side. Runs on the login node (HPC_LOGIN_HOST) as HPC_USER, which runs our own
# interLink Slurm sidecar (the user service SIDECAR_UNIT, files in HPC_PROJECT_ROOT). No root, no site
# change. Usually called from Ulisses: 'k8s-side.sh hpc <command>', and 'k8s-side.sh mode' runs the
# steps below in order.
# Two modes, one at a time (README.md in this folder):
#   split    interLink 0.6.1 + the split executor: init/wait here, only main in Slurm
#   reverse  interLink 0.6.3 + the reverse tunnel: the whole pod in Slurm, one wrapper (subPath fix)
#
#   check [split|reverse] read-only checks of what each mode needs on this login node (default: both)
#   probe-compute         a short Slurm job: what a compute node of SLURM_PARTITION can reach (expected
#                         on an air-gapped node: nothing outside Deucalion), and what the reverse mode
#                         needs there: python3, sshd, and srun --overlap into the job
#   install               the sidecar: plugin SPLIT_IL_VERSION, a plain SlurmConfig.yaml (no mode on),
#                         the user service SIDECAR_UNIT; does nothing if it is installed already
#   uninstall             stop and remove the user service (files stay); refuses while a mode is on
#   images                pull IMAGES and ARGO_EXEC_IMAGE into HPC_PROJECT_ROOT/images (Apptainer)
#   enable split|reverse  point the sidecar at that mode (backup first; refuses while the other is on)
#   disable               put SlurmConfig.yaml and the sidecar back as installed, stop the relay
#   relay on|off|log      split: login side of the Kubernetes API relay (only if 'check' says the API
#                         is not reachable from here)
#   status                which mode is on, what is configured and running now
#   mode                  print only the mode that is on: split, reverse or none
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ZE="$(cd "$HERE/../.." && pwd)"
SRC="$ZE/setup/hpc/split-executor"
SPF_SRC="$ZE/setup/hpc/subpath-fix"
# Settings: deucalion.env next to this script, or the file named in SPLIT_ENV (the testbed rehearsal
# uses testbed.env).
ENV_FILE="${SPLIT_ENV:-$HERE/deucalion.env}"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy deucalion.env.example)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
REVERSE_IL_VERSION="${REVERSE_IL_VERSION:-0.6.3}"
SPLIT_IL_VERSION="${SPLIT_IL_VERSION:-0.6.1}"
# Our own service and port: a login node is shared, and another sidecar (Isabel's) may run there.
SIDECAR_UNIT="${SIDECAR_UNIT:-lisa-sidecar}"
SIDECAR_PORT="${SIDECAR_PORT:-4100}"
# systemctl --user from a non-interactive ssh session ('k8s-side.sh mode') may not have it set.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

IL="$HPC_PROJECT_ROOT/.interlink"
CFG="$IL/SlurmConfig.yaml"
BAK="$IL/SlurmConfig.yaml.pre-split"       # exists while split is on
BAK_RT="$IL/SlurmConfig.yaml.pre-reverse"  # exists while reverse is on
SE="$HPC_PROJECT_ROOT/split-executor"
RT="$HPC_PROJECT_ROOT/reverse-tunnel"
IMG="$HPC_PROJECT_ROOT/images"
RD="$SE/relay"
UNIT_RELAY=split-api-relay
SOCK="$RT/sock"                            # the plugin's SocketDirRoot, shared with the compute nodes
RES="$RT/resources.sh"
case "$(uname -m)" in aarch64|arm64) ARCH=arm64;; *) ARCH=x86_64;; esac
PLUGIN="$RT/interlink-sidecar-slurm-${REVERSE_IL_VERSION}_Linux_$ARCH"
PLUGIN_URL="https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/$REVERSE_IL_VERSION/interlink-sidecar-slurm_Linux_$ARCH"
BASE_PLUGIN="$IL/interlink-sidecar-slurm-${SPLIT_IL_VERSION}_Linux_$ARCH"
BASE_PLUGIN_URL="https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/$SPLIT_IL_VERSION/interlink-sidecar-slurm_Linux_$ARCH"
UNIT_FILE="$HOME/.config/systemd/user/$SIDECAR_UNIT.service"

say()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
info() { printf 'INFO  %s\n' "$*"; }
key() { sed -n "s/^$1: *//p" "$2" | tr -d '"'; }

mode_on() { if [ -f "$BAK" ]; then echo split; elif [ -f "$BAK_RT" ]; then echo reverse; else echo none; fi; }
# The reverse mode runs the 0.6.3 plugin through a drop-in next to the unit, which stays as installed.
DROPIN="$UNIT_FILE.d/trial-reverse.conf"
sidecar_bin() { systemctl --user show -p ExecStart "$SIDECAR_UNIT" 2>/dev/null | grep -o 'path=[^ ;]*' | head -n 1 | cut -d= -f2; }
installed() { [ -f "$UNIT_FILE" ] && [ -f "$CFG" ] && [ -x "$BASE_PLUGIN" ]; }
port_used() { ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}' | grep -q "[:.]$1\$"; }
settings() {
  grep -E '^(SbatchPath|SqueuePath|ScancelPath|CommandPrefix|ImagePrefix|SocketDirRoot|ResourceScriptPath):' "$CFG"
  sed -n '/^SingularityDefaultOptions:/,/^[A-Za-z]/p' "$CFG" | sed '$d'
}
# The plugin refuses a SocketDirRoot that is not an absolute path of letters, digits, '.', '_' and
# '-' with no element starting with '.', or that is longer than this.
sock_ok() { [[ "$SOCK" =~ ^(/[A-Za-z0-9_-][A-Za-z0-9._-]*)+$ ]] && [ "${#SOCK}" -le 79 ]; }

restart_sidecar() {
  systemctl --user daemon-reload
  systemctl --user restart "$SIDECAR_UNIT"
  sleep 8
  systemctl --user is-active --quiet "$SIDECAR_UNIT" && say "sidecar restarted: $(sidecar_bin)" \
    || { say "ERROR: sidecar not active after restart; last log lines:"; tail -n 20 "$IL/sidecar.log"; exit 1; }
}

# What both modes change in SlurmConfig.yaml. --no-eval: Apptainer would evaluate every env value a
# second time and corrupt ARGO_TEMPLATE. --contain: each container gets its own /tmp, as in
# Kubernetes. CommandPrefix "": Isabel's data wrapper off. ImagePrefix: the images pulled beforehand,
# because compute nodes cannot pull.
common_config() {
  grep -q '^SingularityDefaultOptions:' "$CFG" || printf 'SingularityDefaultOptions:\n' >>"$CFG"
  for opt in --contain --no-eval; do
    grep -q -- "\"$opt\"" "$CFG" || sed -i "/^SingularityDefaultOptions:/a\\  - \"$opt\"" "$CFG"
  done
  sed -i -e 's#^CommandPrefix: .*#CommandPrefix: ""#' -e "s#^ImagePrefix: .*#ImagePrefix: \"$IMG/\"#" "$CFG"
}

gs_url() { if [ "${GS_INSECURE:-true}" = true ]; then echo "http://$GS_ENDPOINT"; else echo "https://$GS_ENDPOINT"; fi; }

case "${1:-}" in
  check)
    want="${2:-both}"
    case "$want" in split|reverse|both) ;; *) say "usage: $0 check [split|reverse]"; exit 2;; esac
    FAILED=0
    say "== login node $(hostname), user $(id -un), mode on: $(mode_on)"
    [ "$(id -un)" = "$HPC_USER" ] && pass "running as HPC_USER" || fail "running as $(id -un), expected HPC_USER=$HPC_USER"
    mkdir -p "$HPC_PROJECT_ROOT" 2>/dev/null && [ -w "$HPC_PROJECT_ROOT" ] && pass "HPC_PROJECT_ROOT $HPC_PROJECT_ROOT writable" \
      || fail "cannot write to HPC_PROJECT_ROOT $HPC_PROJECT_ROOT"
    if installed; then
      pass "sidecar installed ($UNIT_FILE, $CFG)"
      systemctl --user is-active --quiet "$SIDECAR_UNIT" && pass "$SIDECAR_UNIT is running ($(sidecar_bin))" \
        || fail "$SIDECAR_UNIT is not running (systemctl --user status $SIDECAR_UNIT; tail $IL/sidecar.log)"
    else
      info "sidecar not installed yet: 'install' does it ('k8s-side.sh mode' runs it)"
      if port_used "$SIDECAR_PORT"; then fail "port $SIDECAR_PORT already in use on this node: pick another SIDECAR_PORT"
      else pass "port $SIDECAR_PORT free for the sidecar"; fi
      code="$(curl -sIL -m 15 -o /dev/null -w '%{http_code}' "$BASE_PLUGIN_URL" 2>/dev/null)"
      [ "$code" = 200 ] && pass "Slurm plugin $SPLIT_IL_VERSION can be downloaded" \
        || fail "Slurm plugin $SPLIT_IL_VERSION cannot be downloaded from here (HTTP '$code'): $BASE_PLUGIN_URL"
    fi
    systemctl --user show-environment >/dev/null 2>&1 && pass "systemctl --user works" \
      || fail "systemctl --user does not work here (the sidecar runs as a user service)"
    info "linger: $(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown) (no: the sidecar stops when your last session ends, and starts again with the next one, e.g. the tunnel from Ulisses)"
    sv="$(singularity --version 2>&1)"; info "container runtime: $sv"
    help="$(singularity exec --help 2>&1 || true)"
    case "$help" in *--no-eval*) pass "singularity exec has --no-eval";; *) fail "singularity exec has no --no-eval (needs Apptainer >= 1.1 or a SingularityCE that has it)";; esac
    case "$help" in *--contain*) pass "singularity exec has --contain";; *) fail "singularity exec has no --contain";; esac
    for t in bash sed awk grep curl sbatch squeue scancel sinfo; do
      command -v "$t" >/dev/null 2>&1 && pass "found $t" || fail "missing $t"
    done
    if sinfo -h -p "$SLURM_PARTITION" -o '%P' 2>/dev/null | grep -q .; then pass "partition $SLURM_PARTITION exists"
    else fail "partition $SLURM_PARTITION not found; partitions: $(sinfo -h -o '%P' | tr '\n' ' ')"; fi
    # -P: one line per file system even with a long name (Lustre). Images and job folders need room.
    avail="$(df -P "$HPC_PROJECT_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')"
    if [ -n "$avail" ] && [ "$avail" -lt 1048576 ]; then
      fail "only $((avail / 1024)) MB free on the file system of $HPC_PROJECT_ROOT ($(df -P "$HPC_PROJECT_ROOT" | awk 'NR == 2 {print $6}')): pick a HPC_PROJECT_ROOT elsewhere"
    else info "project file system: $(df -Ph "$HPC_PROJECT_ROOT" 2>/dev/null | awk 'NR == 2 {print $4 " free of " $2}')"; fi

    if [ "$want" != reverse ]; then
      say "== split (interLink 0.6.1 + split executor)"
      [ -d "$SRC" ] && pass "split executor sources in $SRC" || fail "no $SRC"
      if systemd-run --user --quiet --unit=split-check-$$ /bin/true 2>/dev/null; then pass "systemd-run --user works"
      else info "systemd-run --user does not work: the split executor falls back to setsid (survives less well)"; fi
      for t in openssl scontrol; do command -v "$t" >/dev/null 2>&1 && pass "found $t" || fail "missing $t"; done
      # A held job is submitted and cancelled at once: it never runs and uses no allocation.
      jid="$(sbatch --parsable --hold -p "$SLURM_PARTITION" -A "$SLURM_ACCOUNT" -t 1 -J split-check --wrap=true 2>&1)"
      if [[ "$jid" =~ ^[0-9]+ ]]; then
        jid="${jid%%;*}"
        st="$(squeue -h -j "$jid" -o '%T %r' 2>/dev/null)"
        scancel "$jid" 2>/dev/null
        pass "sbatch --hold accepted (job $jid: $st), cancelled"
      else fail "sbatch --hold refused: $jid"; fi
      code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(gs_url)/minio/health/live" 2>/dev/null)"
      [ "$code" = 200 ] && pass "Global Storage $GS_ENDPOINT reachable from here" \
        || fail "Global Storage $GS_ENDPOINT not reachable from here (HTTP '$code'): init/wait cannot move data"
      code="$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://$K8S_API_HOST:$K8S_API_PORT/version" 2>/dev/null)"
      case "$code" in
        200|401|403) info "Kubernetes API $K8S_API_HOST:$K8S_API_PORT reachable from here (HTTP $code): split can use SPLIT_API=direct, no relay needed";;
        *) info "Kubernetes API $K8S_API_HOST:$K8S_API_PORT not reachable from here (HTTP '$code'): split needs the relay (SPLIT_API=relay)";;
      esac
      for p in "$RELAY_API_PORT" "$RELAY_CTL_PORT"; do
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q "[:.]$p\$"; then
          systemctl --user is-active --quiet "$UNIT_RELAY" && info "port $p in use by our relay" || fail "port $p already in use on this node: pick other RELAY_*_PORT values"
        else pass "port $p free"; fi
      done
    fi

    if [ "$want" != split ]; then
      say "== reverse (interLink $REVERSE_IL_VERSION + reverse tunnel)"
      [ -d "$SPF_SRC" ] && pass "subPath fix sources in $SPF_SRC" || fail "no $SPF_SRC"
      command -v srun >/dev/null 2>&1 && pass "found srun" || fail "missing srun (the shadow reaches the job with srun --overlap)"
      squeue -h --me -o %i >/dev/null 2>&1 && pass "squeue --me works (the shadow finds the job with it)" \
        || fail "squeue --me fails (the shadow finds the job with it; Slurm older than 20.11?)"
      if [ -x "$PLUGIN" ]; then pass "Slurm plugin $REVERSE_IL_VERSION already in $PLUGIN"
      else
        code="$(curl -sIL -m 15 -o /dev/null -w '%{http_code}' "$PLUGIN_URL" 2>/dev/null)"
        [ "$code" = 200 ] && pass "Slurm plugin $REVERSE_IL_VERSION can be downloaded ('enable reverse' does it)" \
          || fail "Slurm plugin $REVERSE_IL_VERSION cannot be downloaded from here (HTTP '$code'): $PLUGIN_URL"
      fi
      sock_ok && pass "SocketDirRoot $SOCK (${#SOCK} bytes)" \
        || fail "SocketDirRoot $SOCK: the plugin wants at most 79 bytes of letters, digits, '.', '_', '-', no element starting with '.'"
      info "the Global Storage and the Kubernetes API are reached from Ulisses through the tunnel, not from here"
      info "python3, sshd and srun --overlap on a compute node: run ./hpc-side.sh probe-compute"
    fi
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
    say "Expected on an air-gapped node: every URL 'none' or 000, DNS cannot resolve, shared FS visible."
    say "The reverse mode also needs python3 (3.6 or newer), /usr/sbin/sshd and srun --overlap working."
    ;;

  install)
    case "$HPC_PROJECT_ROOT" in /*) ;; *) say "ERROR: HPC_PROJECT_ROOT must be an absolute path; it is '$HPC_PROJECT_ROOT'"; exit 1;; esac
    if installed; then
      systemctl --user is-active --quiet "$SIDECAR_UNIT" || { systemctl --user daemon-reload; systemctl --user start "$SIDECAR_UNIT"; sleep 5; }
      systemctl --user is-active --quiet "$SIDECAR_UNIT" && { say "sidecar installed and running ($SIDECAR_UNIT, port $SIDECAR_PORT)"; exit 0; }
      say "ERROR: $SIDECAR_UNIT is installed but does not start; last log lines:"; tail -n 20 "$IL/sidecar.log"; exit 1
    fi
    [ "$(mode_on)" = none ] || { say "ERROR: a mode is on but the sidecar is not fully installed; see 'status'"; exit 1; }
    port_used "$SIDECAR_PORT" && { say "ERROR: port $SIDECAR_PORT already in use on this node: pick another SIDECAR_PORT (both sides read it)"; exit 1; }
    mkdir -p "$IL/jobs"
    if [ ! -x "$BASE_PLUGIN" ]; then
      curl -fsSL --retry 3 -o "$BASE_PLUGIN.dl" "$BASE_PLUGIN_URL" && chmod 0755 "$BASE_PLUGIN.dl" && mv -f "$BASE_PLUGIN.dl" "$BASE_PLUGIN" \
        || { rm -f "$BASE_PLUGIN.dl"; say "ERROR: download of the Slurm plugin $SPLIT_IL_VERSION failed: $BASE_PLUGIN_URL"; exit 1; }
    fi
    # Isabel's SlurmConfig.yaml (setup/hpc/1-bridge.sh) without what only her prototype used: her data
    # wrapper (CommandPrefix) and the bind of her system data. 'enable' changes it for a mode, 'disable'
    # puts this back.
    if [ ! -f "$CFG" ]; then
      cat >"$CFG" <<YAML
SidecarURL: "http://127.0.0.1"
SidecarPort: "$SIDECAR_PORT"
SbatchPath: "$(command -v sbatch)"
ScancelPath: "$(command -v scancel)"
SqueuePath: "$(command -v squeue)"
SinfoPath: "$(command -v sinfo)"
CommandPrefix: ""
ImagePrefix: "docker://"
SingularityPath: "singularity"
SingularityPrefix: ""
SingularityDefaultOptions:
ExportPodData: true
DataRootFolder: "$IL/jobs/"
Namespace: "vk"
Tsocks: false
BashPath: /bin/bash
VerboseLogging: true
ErrorsOnlyLogging: false
EnableProbes: true
YAML
    fi
    mkdir -p "$(dirname "$UNIT_FILE")"
    cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=interLink Slurm sidecar (LISA trial, deploy/deucalion)
After=network.target

[Service]
Environment=SLURMCONFIGPATH=$CFG
Environment=SHARED_FS=true
ExecStart=$BASE_PLUGIN
WorkingDirectory=$IL
Restart=always
RestartSec=5
StandardOutput=append:$IL/sidecar.log
StandardError=append:$IL/sidecar.log

[Install]
WantedBy=default.target
UNIT
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 && say "linger enabled: the sidecar keeps running without a session" \
      || info "could not enable linger (not allowed here): the sidecar runs while you have a session, such as the tunnel from Ulisses"
    systemctl --user daemon-reload
    systemctl --user enable --now "$SIDECAR_UNIT" >/dev/null 2>&1
    sleep 5
    systemctl --user is-active --quiet "$SIDECAR_UNIT" || { say "ERROR: $SIDECAR_UNIT does not start; last log lines:"; tail -n 20 "$IL/sidecar.log"; exit 1; }
    say "sidecar installed and running: $SIDECAR_UNIT, plugin $SPLIT_IL_VERSION, port $SIDECAR_PORT, config $CFG"
    ;;

  uninstall)
    [ "$(mode_on)" = none ] || { say "ERROR: '$(mode_on)' is on: run 'disable' first"; exit 1; }
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
    say "Images are in $IMG; 'enable' points the sidecar's ImagePrefix there."
    ;;

  enable)
    m="${2:-}"
    case "$m" in split|reverse) ;; *) say "usage: $0 enable split|reverse"; exit 2;; esac
    on="$(mode_on)"
    [ "$on" = none ] || [ "$on" = "$m" ] \
      || { say "ERROR: '$on' is on: run './hpc-side.sh disable' first (or './k8s-side.sh mode $m' on Ulisses)"; exit 1; }
    installed || { say "ERROR: the sidecar is not installed: run './hpc-side.sh install' first"; exit 1; }
    help="$(singularity exec --help 2>&1 || true)"
    case "$help" in *--no-eval*) ;; *) say "ERROR: singularity exec has no --no-eval; see 'check'"; exit 1;; esac
    [ -s "$IMG/$ARGO_EXEC_IMAGE" ] || { say "ERROR: $IMG/$ARGO_EXEC_IMAGE missing: run './hpc-side.sh images' first"; exit 1; }

    if [ "$m" = split ]; then
      [ -d "$SRC" ] || { say "ERROR: no $SRC"; exit 1; }
      if [ -f "$BAK" ]; then say "backup $BAK already exists (enabled before): keeping the original backup"
      else cp -p "$CFG" "$BAK"; say "backup: $BAK"; fi
      rm -rf "$SE.new"; cp -r "$SRC" "$SE.new"
      # Keep the relay's certificates and the registry of jobs that may still be running.
      [ -d "$RD" ] && cp -rp "$RD" "$SE.new/relay"
      [ -d "$SE/jobs" ] && cp -rp "$SE/jobs" "$SE.new/jobs"
      rm -rf "$SE"; mv "$SE.new" "$SE"
      sb="$(key SbatchPath "$BAK")"; sb="${sb:-$(command -v sbatch)}"
      sq="$(key SqueuePath "$BAK")"; sq="${sq:-$(command -v squeue)}"
      sc="$(key ScancelPath "$BAK")"; sc="${sc:-$(command -v scancel)}"
      cat >"$SE/split.conf" <<CONF
REAL_SBATCH=$sb
REAL_SQUEUE=$sq
REAL_SCANCEL=$sc
REAL_SCONTROL=$(dirname "$sb")/scontrol
CONF
      mkdir -p "$SE/jobs"
      chmod 755 "$SE/sbatch" "$SE/squeue" "$SE/scancel"
      chmod 0755 "$SE/api-relay/split-relay" "$SE"/api-relay/bin/split-relay-linux-* 2>/dev/null || true
      common_config
      sed -i -e "s#^SbatchPath: .*#SbatchPath: \"$SE/sbatch\"#" \
             -e "s#^SqueuePath: .*#SqueuePath: \"$SE/squeue\"#" \
             -e "s#^ScancelPath: .*#ScancelPath: \"$SE/scancel\"#" "$CFG"
      restart_sidecar
      say "--- changed settings"; settings
      say "--- real Slurm commands"; cat "$SE/split.conf"
    else
      [ -d "$SPF_SRC" ] || { say "ERROR: no $SPF_SRC"; exit 1; }
      sock_ok || { say "ERROR: SocketDirRoot $SOCK is not valid for the plugin; see 'check reverse'"; exit 1; }
      mkdir -p "$RT"
      if [ ! -x "$PLUGIN" ]; then
        say "download Slurm plugin $REVERSE_IL_VERSION: $PLUGIN_URL"
        curl -fsSL --retry 3 -o "$PLUGIN.dl" "$PLUGIN_URL" && chmod 0755 "$PLUGIN.dl" && mv -f "$PLUGIN.dl" "$PLUGIN" \
          || { rm -f "$PLUGIN.dl"; say "ERROR: download failed"; exit 1; }
      fi
      # The one wrapper left: the plugin ignores subPath on emptyDirs (setup/hpc/subpath-fix/README.md).
      rm -rf "$RT/subpath-fix"; cp -r "$SPF_SRC" "$RT/subpath-fix"; chmod 0755 "$RT/subpath-fix/sbatch"
      mkdir -p "$SOCK"; chmod 0700 "$SOCK"
      # Plugin 0.6.3 reports the free cpu and memory it sees as the virtual node's capacity, which can
      # drop below one pod's request (seen on the testbed), so pods stay Pending. Report the fixed
      # capacity the virtual node has with 0.6.1 instead.
      printf '#!/bin/sh\necho %s\n' "'{\"status\":\"ok\",\"resources\":{\"cpu\":\"100\",\"memory\":\"3T\",\"pods\":\"10k\"}}'" >"$RES"
      chmod 0755 "$RES"
      # The backup only now, when nothing above can fail any more: its presence means "reverse is on".
      if [ -f "$BAK_RT" ]; then say "backup $BAK_RT already exists (enabled before): keeping the original backup"
      else cp -p "$CFG" "$BAK_RT"; say "backup: $BAK_RT"; fi
      sb="$(key SbatchPath "$BAK_RT")"; sb="${sb:-$(command -v sbatch)}"
      printf 'REAL_SBATCH=%s\n' "$sb" >"$RT/subpath-fix/subpath-fix.conf"
      cp -p "$BAK_RT" "$CFG"
      common_config
      sed -i -e "s#^SbatchPath: .*#SbatchPath: \"$RT/subpath-fix/sbatch\"#" -e '/^SocketDirRoot:/d' -e '/^ResourceScriptPath:/d' "$CFG"
      printf 'SocketDirRoot: "%s"\nResourceScriptPath: "%s"\n' "$SOCK" "$RES" >>"$CFG"
      mkdir -p "$(dirname "$DROPIN")"
      printf '[Service]\nExecStart=\nExecStart=%s\n' "$PLUGIN" >"$DROPIN"
      restart_sidecar
      say "--- changed settings"; settings
      say "--- real sbatch behind the subPath fix: $sb"
    fi
    say "Undo with: ./hpc-side.sh disable"
    ;;

  disable)
    systemctl --user stop "$UNIT_RELAY" >/dev/null 2>&1 || true
    case "$(mode_on)" in
      split)
        cp -p "$BAK" "$CFG"; rm -f "$BAK"
        restart_sidecar
        say "split off: SlurmConfig.yaml restored (the split executor files stay in $SE; job folders are not touched)"
        ;;
      reverse)
        rm -f "$DROPIN"; rmdir "$(dirname "$DROPIN")" 2>/dev/null
        cp -p "$BAK_RT" "$CFG"; rm -f "$BAK_RT"
        restart_sidecar
        say "reverse off: SlurmConfig.yaml and the $SPLIT_IL_VERSION plugin restored (the files stay in $RT; job folders are not touched)"
        ;;
      *) say "nothing is on: SlurmConfig.yaml not changed";;
    esac
    settings
    ;;

  relay)
    case "${2:-}" in
      on)
        [ -x "$SE/api-relay/split-relay" ] || { say "ERROR: run './hpc-side.sh enable split' first"; exit 1; }
        mkdir -p "$RD"; chmod 700 "$RD"
        [ -s "$RD/ca.crt" ] || bash "$SE/api-relay/make-certs.sh" "$RD"
        : >"$RD/relay.log"
        systemctl --user stop "$UNIT_RELAY" >/dev/null 2>&1; systemctl --user reset-failed "$UNIT_RELAY" >/dev/null 2>&1
        systemd-run --user --quiet --unit="$UNIT_RELAY" -p Restart=always \
          -p StandardOutput=append:"$RD/relay.log" -p StandardError=append:"$RD/relay.log" \
          "$SE/api-relay/split-relay" login --api-port "$RELAY_API_PORT" --ctl-port "$RELAY_CTL_PORT" \
          --cert "$RD/server.crt" --key "$RD/server.key"
        sleep 2
        systemctl --user is-active --quiet "$UNIT_RELAY" || { tail -n 20 "$RD/relay.log"; exit 1; }
        tail -n 1 "$RD/relay.log"
        say "relay CA (k8s-side.sh fetches it): $RD/ca.crt"
        ;;
      off) systemctl --user stop "$UNIT_RELAY" >/dev/null 2>&1 || true; say "relay stopped";;
      log) cat "$RD/relay.log" 2>/dev/null || say "no relay log";;
      *) say "usage: $0 relay on|off|log"; exit 2;;
    esac
    ;;

  status)
    say "== mode: $(mode_on)   sidecar $SIDECAR_UNIT: $(systemctl --user is-active "$SIDECAR_UNIT" 2>&1) ($(sidecar_bin)), port $SIDECAR_PORT   relay: $(systemctl --user is-active "$UNIT_RELAY" 2>&1)"
    settings 2>/dev/null
    say "== images in $IMG:"; find "$IMG" -type f -printf '   %p\n' 2>/dev/null
    say "== Slurm jobs of $(id -un):"; squeue -h -u "$(id -un)" -o '   %i %P %j %T %M' 2>/dev/null
    jr="$(key DataRootFolder "$CFG")"
    n="$(ls -d "$jr"*/ 2>/dev/null | wc -l)"; say "== job folders in $jr: $n (they hold data, keys and tokens: see README, cleanup)"
    if [ "$(mode_on)" = reverse ]; then say "== reverse tunnel: $(ls "$SOCK" 2>/dev/null | wc -l) pod socket folders in $SOCK"; fi
    ;;

  mode) mode_on ;;

  *) awk 'NR > 1 && !/^#/ {exit} NR > 1' "$0"; exit 2;;
esac
