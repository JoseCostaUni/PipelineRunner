#!/bin/bash
# Reverse-tunnel experiment, HPC side (as root on the login node; acts on lisa's sidecar).
#   install          Slurm plugin $IL_VERSION (release binary) next to Isabel's 0.6.1, and the
#                    subPath fix (setup/hpc/subpath-fix) in her project folder
#   use 0.6.1|new    which plugin the interlink-sidecar user unit runs (drop-in; 0.6.1 = untouched)
#   config on|off    SlurmConfig.yaml: SocketDirRoot, CommandPrefix off, --no-eval --contain,
#                    SbatchPath = subPath fix. 'off' restores the backup exactly.
#   status           what runs and what is configured
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
IL="$HPC_ROOT/.interlink"
CFG="$IL/SlurmConfig.yaml"
BAK="$IL/SlurmConfig.yaml.pre-rt"
NEWBIN="$IL/rt-$IL_VERSION/interlink-sidecar-slurm_Linux_arm64"
SPF="$HPC_ROOT/subpath-fix"
SOCK="$HPC_ROOT/rt-sock"   # no path element may start with a dot (plugin check)
RES="$HPC_ROOT/rt-resources.sh"
UNITD=/home/lisa/.config/systemd/user/interlink-sidecar.service.d

restart_sidecar() { lisa_ssh "systemctl --user daemon-reload; systemctl --user restart interlink-sidecar"; sleep 6
  lisa_ssh "systemctl --user is-active interlink-sidecar" >/dev/null || { log "ERROR: sidecar not active"; tail -n 30 "$IL/sidecar.log"; exit 1; }; }

case "${1:-}:${2:-}" in
  install:)
    mkdir -p "$(dirname "$NEWBIN")"
    if [ ! -x "$NEWBIN" ]; then
      curl -fsSL --retry 3 -o "$NEWBIN" "https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/$IL_VERSION/interlink-sidecar-slurm_Linux_arm64"
      chmod 0755 "$NEWBIN"
    fi
    rm -rf "$SPF"; cp -r "$RT/subpath-fix" "$SPF"; chmod 0755 "$SPF/sbatch"
    printf 'REAL_SBATCH=%s\n' "$(command -v sbatch)" >"$SPF/subpath-fix.conf"
    chown -R lisa:lisa "$(dirname "$NEWBIN")" "$SPF"
    log "plugin $IL_VERSION: $NEWBIN ($(stat -c %s "$NEWBIN") bytes); subPath fix in $SPF"
    ;;
  use:new|use:0.6.1)
    if [ "$2" = new ]; then
      [ -x "$NEWBIN" ] || { log "ERROR: run install first"; exit 1; }
      # As lisa: root cannot write in her home (as on a real cluster with root-squashed homes).
      lisa_ssh "mkdir -p '$UNITD' && printf '[Service]\nExecStart=\nExecStart=%s\n' '$NEWBIN' >'$UNITD/rt.conf'"
    else
      lisa_ssh "rm -f '$UNITD/rt.conf'; rmdir '$UNITD' 2>/dev/null; true"
    fi
    [ "${3:-}" = norestart ] && { log "drop-in written; the plugin restarts with the next step"; exit 0; }
    restart_sidecar
    log "sidecar runs: $(lisa_ssh 'systemctl --user show -p ExecStart interlink-sidecar' | grep -o 'path=[^ ;]*')"
    ;;
  config:on)
    [ -f "$BAK" ] || cp -p "$CFG" "$BAK"
    cp -p "$BAK" "$CFG"
    [ "${#SOCK}" -le 79 ] || { log "ERROR: SocketDirRoot $SOCK longer than 79 bytes"; exit 1; }
    install -d -m 0700 -o lisa -g lisa "$SOCK"
    grep -q '^SingularityDefaultOptions:' "$CFG" || printf 'SingularityDefaultOptions:\n' >>"$CFG"
    for opt in --contain --no-eval; do
      grep -q -- "\"$opt\"" "$CFG" || sed -i "/^SingularityDefaultOptions:/a\\  - \"$opt\"" "$CFG"
    done
    sed -i -e "s#^SbatchPath: .*#SbatchPath: \"$SPF/sbatch\"#" -e 's#^CommandPrefix: .*#CommandPrefix: ""#' "$CFG"
    sed -i '/^SocketDirRoot:/d' "$CFG"; printf 'SocketDirRoot: "%s"\n' "$SOCK" >>"$CFG"
    # Plugin 0.6.3 reports the node's FREE cpu/memory on every ping and the virtual kubelet takes
    # that as the node's capacity. On the testbed's small compute node that drops below one pod's
    # request (seen: 200Mi), so pods stay Pending. Report Isabel's fixed capacity instead.
    printf '#!/bin/sh\necho %s\n' "'{\"status\":\"ok\",\"resources\":{\"cpu\":\"100\",\"memory\":\"3T\",\"pods\":\"10k\"}}'" >"$RES"
    chmod 0755 "$RES"; chown lisa:lisa "$RES"
    sed -i '/^ResourceScriptPath:/d' "$CFG"; printf 'ResourceScriptPath: "%s"\n' "$RES" >>"$CFG"
    restart_sidecar
    grep -E '^(SbatchPath|CommandPrefix|ImagePrefix|SocketDirRoot|ResourceScriptPath):' "$CFG"
    ;;
  config:off)
    if [ -f "$BAK" ]; then cp -p "$BAK" "$CFG"; rm -f "$BAK"; restart_sidecar; fi
    grep -E '^(SbatchPath|CommandPrefix|ImagePrefix|SocketDirRoot|ResourceScriptPath):' "$CFG" || true
    ;;
  status:)
    echo "sidecar: $(lisa_ssh 'systemctl --user is-active interlink-sidecar') $(lisa_ssh 'systemctl --user show -p ExecStart interlink-sidecar' | grep -o 'path=[^ ;]*')"
    grep -E '^(SbatchPath|CommandPrefix|ImagePrefix|SocketDirRoot|ResourceScriptPath):' "$CFG"
    sed -n '/^SingularityDefaultOptions:/,/^[A-Za-z]/p' "$CFG" | sed '$d'
    echo "sockets: $(ls "$SOCK" 2>/dev/null | wc -l) pod dirs in $SOCK"
    ;;
  *) sed -n '2,10p' "$0"; exit 2;;
esac
