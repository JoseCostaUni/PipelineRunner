#!/bin/bash
# Split executor on Deucalion, HPC side. Run on the login node where Isabel's interlink-sidecar
# runs (HPC_LOGIN_HOST), as the account that runs it (HPC_USER). No root, no site change.
# See README.md in this folder.
#
#   check                 read-only checks of what the split executor needs on this login node
#   probe-compute         a 1-minute Slurm job that shows what a compute node of SLURM_PARTITION can
#                         reach (expected on an air-gapped node: nothing outside Deucalion)
#   images                pull IMAGES and ARGO_EXEC_IMAGE into HPC_PROJECT_ROOT/images (Apptainer)
#   enable                install the split executor and point the sidecar at it (backup first)
#   disable               put SlurmConfig.yaml back exactly as it was, stop the relay
#   relay on|off|log      login side of the Kubernetes API relay (only if 'check' says the API
#                         is not reachable from here)
#   status                what is configured and running now
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ZE="$(cd "$HERE/../.." && pwd)"
SRC="$ZE/setup/hpc/split-executor"
[ -f "$HERE/deucalion.env" ] || { echo "missing $HERE/deucalion.env (copy deucalion.env.example)" >&2; exit 1; }
# shellcheck disable=SC1091
source "$HERE/deucalion.env"

IL="$HPC_PROJECT_ROOT/.interlink"
CFG="$IL/SlurmConfig.yaml"
BAK="$IL/SlurmConfig.yaml.pre-split"
SE="$HPC_PROJECT_ROOT/split-executor"
IMG="$HPC_PROJECT_ROOT/images"
RD="$SE/relay"
UNIT_RELAY=split-api-relay

say()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
info() { printf 'INFO  %s\n' "$*"; }
key() { sed -n "s/^$1: *//p" "$2" | tr -d '"'; }

restart_sidecar() {
  systemctl --user restart interlink-sidecar
  sleep 8
  systemctl --user is-active --quiet interlink-sidecar && say "sidecar restarted" \
    || { say "ERROR: sidecar not active after restart; last log lines:"; tail -n 20 "$IL/sidecar.log"; exit 1; }
}

gs_url() { if [ "${GS_INSECURE:-true}" = true ]; then echo "http://$GS_ENDPOINT"; else echo "https://$GS_ENDPOINT"; fi; }

case "${1:-}" in
  check)
    FAILED=0
    say "== login node $(hostname), user $(id -un)"
    [ "$(id -un)" = "$HPC_USER" ] && pass "running as HPC_USER" || fail "running as $(id -un), expected HPC_USER=$HPC_USER"
    [ -f "$CFG" ] && pass "sidecar config $CFG" || fail "no $CFG (is Isabel's setup/hpc installed here?)"
    systemctl --user is-active --quiet interlink-sidecar && pass "interlink-sidecar is running" \
      || fail "interlink-sidecar is not running on this login node (systemctl --user status interlink-sidecar)"
    [ -d "$SRC" ] && pass "split executor sources in $SRC" || fail "no $SRC"
    sv="$(singularity --version 2>&1)"; info "container runtime: $sv"
    help="$(singularity exec --help 2>&1 || true)"
    case "$help" in *--no-eval*) pass "singularity exec has --no-eval";; *) fail "singularity exec has no --no-eval (needs Apptainer >= 1.1 or a SingularityCE that has it)";; esac
    case "$help" in *--contain*) pass "singularity exec has --contain";; *) fail "singularity exec has no --contain";; esac
    if systemd-run --user --quiet --unit=split-check-$$ /bin/true 2>/dev/null; then pass "systemd-run --user works"
    else info "systemd-run --user does not work: the split executor falls back to setsid (survives less well)"; fi
    for t in bash sed awk grep openssl curl sbatch squeue scancel scontrol sinfo; do
      command -v "$t" >/dev/null 2>&1 && pass "found $t" || fail "missing $t"
    done
    if sinfo -h -p "$SLURM_PARTITION" -o '%P' 2>/dev/null | grep -q .; then pass "partition $SLURM_PARTITION exists"
    else fail "partition $SLURM_PARTITION not found; partitions: $(sinfo -h -o '%P' | tr '\n' ' ')"; fi
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
      200|401|403) info "Kubernetes API $K8S_API_HOST:$K8S_API_PORT reachable from here (HTTP $code): use 'api direct' on Ulisses, no relay needed";;
      *) info "Kubernetes API $K8S_API_HOST:$K8S_API_PORT not reachable from here (HTTP '$code'): use the relay (README step 4)";;
    esac
    for p in "$RELAY_API_PORT" "$RELAY_CTL_PORT"; do
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q "[:.]$p\$"; then
        systemctl --user is-active --quiet "$UNIT_RELAY" && info "port $p in use by our relay" || fail "port $p already in use on this node: pick other RELAY_*_PORT values"
      else pass "port $p free"; fi
    done
    df -h "$HPC_PROJECT_ROOT" 2>/dev/null | tail -n 1 | awk '{print "INFO  project file system: " $4 " free of " $2}'
    exit "$FAILED"
    ;;

  probe-compute)
    mkdir -p "$SE"
    out="$SE/probe-compute.out"
    gs="$(gs_url)"
    jid="$(sbatch --parsable -p "$SLURM_PARTITION" -A "$SLURM_ACCOUNT" -t 2 -J split-probe -o "$out" --wrap "
      echo \"node: \$(hostname)\"
      for u in $gs/minio/health/live https://$K8S_API_HOST:$K8S_API_PORT/version https://quay.io https://pypi.org; do
        c=\$(curl -sk -m 8 -o /dev/null -w '%{http_code}' \"\$u\" 2>/dev/null); echo \"\$u -> HTTP \${c:-none}\"
      done
      getent hosts quay.io >/dev/null && echo 'DNS: resolves quay.io' || echo 'DNS: cannot resolve quay.io'
      [ -d '$HPC_PROJECT_ROOT' ] && echo 'shared FS: $HPC_PROJECT_ROOT visible' || echo 'shared FS: NOT visible'
    ")" || { say "ERROR: sbatch failed: $jid"; exit 1; }
    say "job $jid submitted to $SLURM_PARTITION; waiting for it (Ctrl-C leaves it running; output in $out)"
    while squeue -h -j "$jid" 2>/dev/null | grep -q .; do sleep 10; done
    cat "$out"
    say "Expected on an air-gapped node: every URL 'none' or 000, DNS cannot resolve, shared FS visible."
    ;;

  images)
    mkdir -p "$IMG"
    for ref in $IMAGES $ARGO_EXEC_IMAGE; do
      dest="$IMG/$ref"
      mkdir -p "$(dirname "$dest")"
      if [ -s "$dest" ]; then say "have  $ref"; continue; fi
      say "pull  $ref"
      singularity pull "$dest" "docker://$ref" || { say "ERROR: pull of $ref failed"; exit 1; }
    done
    chmod -R a+rX "$IMG"
    find "$IMG" -type f -printf '%10s  %p\n'
    say "Images are in $IMG; 'enable' points the sidecar's ImagePrefix there."
    ;;

  enable)
    [ -f "$CFG" ] || { say "ERROR: no $CFG"; exit 1; }
    [ -d "$SRC" ] || { say "ERROR: no $SRC"; exit 1; }
    help="$(singularity exec --help 2>&1 || true)"
    case "$help" in *--no-eval*) ;; *) say "ERROR: singularity exec has no --no-eval; see 'check'"; exit 1;; esac
    [ -s "$IMG/$ARGO_EXEC_IMAGE" ] || { say "ERROR: $IMG/$ARGO_EXEC_IMAGE missing: run './hpc-side.sh images' first"; exit 1; }
    if [ -f "$BAK" ]; then say "backup $BAK already exists (enabled before): keeping the original backup"
    else cp -p "$CFG" "$BAK"; say "backup: $BAK"; fi
    rm -rf "$SE.new"; cp -r "$SRC" "$SE.new"
    [ -d "$RD" ] && cp -rp "$RD" "$SE.new/relay"
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
    # --no-eval: Apptainer would evaluate every env value a second time and corrupt ARGO_TEMPLATE.
    # --contain: each container gets its own /tmp, as in Kubernetes.
    grep -q '^SingularityDefaultOptions:' "$CFG" || printf 'SingularityDefaultOptions:\n' >>"$CFG"
    for opt in --contain --no-eval; do
      grep -q -- "\"$opt\"" "$CFG" || sed -i "/^SingularityDefaultOptions:/a\\  - \"$opt\"" "$CFG"
    done
    sed -i -e "s#^SbatchPath: .*#SbatchPath: \"$SE/sbatch\"#" \
           -e "s#^SqueuePath: .*#SqueuePath: \"$SE/squeue\"#" \
           -e "s#^ScancelPath: .*#ScancelPath: \"$SE/scancel\"#" \
           -e 's#^CommandPrefix: .*#CommandPrefix: ""#' \
           -e "s#^ImagePrefix: .*#ImagePrefix: \"$IMG/\"#" "$CFG"
    restart_sidecar
    say "--- changed settings"
    grep -E '^(SbatchPath|SqueuePath|ScancelPath|CommandPrefix|ImagePrefix):' "$CFG"
    sed -n '/^SingularityDefaultOptions:/,/^[A-Za-z]/p' "$CFG" | sed '$d'
    say "--- real Slurm commands"; cat "$SE/split.conf"
    say "Undo with: ./hpc-side.sh disable"
    ;;

  disable)
    systemctl --user stop "$UNIT_RELAY" >/dev/null 2>&1 || true
    if [ -f "$BAK" ]; then
      cp -p "$BAK" "$CFG"; rm -f "$BAK"
      restart_sidecar
      say "SlurmConfig.yaml restored (the split executor files stay in $SE; job folders are not touched)"
    else
      say "no backup $BAK: nothing to restore (not enabled?)"
    fi
    grep -E '^(SbatchPath|SqueuePath|ScancelPath|CommandPrefix|ImagePrefix):' "$CFG"
    ;;

  relay)
    case "${2:-}" in
      on)
        [ -x "$SE/api-relay/split-relay" ] || { say "ERROR: run './hpc-side.sh enable' first"; exit 1; }
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
    say "== sidecar: $(systemctl --user is-active interlink-sidecar 2>&1)   relay: $(systemctl --user is-active "$UNIT_RELAY" 2>&1)"
    [ -f "$BAK" ] && say "== split executor: ENABLED (backup $BAK)" || say "== split executor: not enabled"
    grep -E '^(SbatchPath|SqueuePath|ScancelPath|CommandPrefix|ImagePrefix):' "$CFG" 2>/dev/null
    say "== images in $IMG:"; find "$IMG" -type f -printf '   %p\n' 2>/dev/null
    say "== Slurm jobs of $(id -un):"; squeue -h -u "$(id -un)" -o '   %i %P %j %T %M' 2>/dev/null
    jr="$(key DataRootFolder "$CFG")"
    n="$(ls -d "$jr"*/ 2>/dev/null | wc -l)"; say "== job folders in $jr: $n (they hold data, keys and tokens: see README, cleanup)"
    ;;

  *) sed -n '2,15p' "$0"; exit 2;;
esac
