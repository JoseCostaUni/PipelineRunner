#!/bin/bash
# Split executor, HPC side (as root on the login node): the split executor from
# lisa-pipeline-runner_ze/setup/hpc/split-executor (copied to /opt/testbed/ze by the testbed).
#   enable      install it in the project folder and point the sidecar's SbatchPath, SqueuePath and
#               ScancelPath to it; CommandPrefix off (no data wrapper); --no-eval added to
#               SingularityDefaultOptions (Apptainer would otherwise evaluate every env value a
#               second time and corrupt ARGO_TEMPLATE). Restarts the sidecar.
#   disable     restore SlurmConfig.yaml as it was before 'enable'. Restarts the sidecar.
#   relay on|off  the login side of the Kubernetes API relay ('api-relay/split-relay login', a static
#               binary: nothing to install on the login node) as lisa's
#               systemd user unit 'split-api-relay': HTTPS on 127.0.0.1:16443 for Argo's init/wait,
#               control port 127.0.0.1:16444 for the agent on ulisses (through its ssh -L tunnel)
#   relay-log   print the relay's log
#   api-check   can the login node reach the Kubernetes API on ulisses directly?
source /opt/testbed/guest/lib.sh
load_ips
IL="$HPC_ROOT/.interlink"
CFG="$IL/SlurmConfig.yaml"
BAK="$IL/SlurmConfig.yaml.pre-split"
SE="$HPC_ROOT/split-executor"

restart_sidecar() { lisa_ssh "systemctl --user restart interlink-sidecar"; sleep 8; }
cfgval() { sed -n "s/^$1: *//p" "$CFG" | tr -d '"'; }

case "${1:-}" in
  enable)
    [ -d "$TB/ze/split-executor" ] || { log "ERROR: $TB/ze/split-executor missing (is lisa-pipeline-runner_ze next to the testbed?)"; exit 1; }
    [ -f "$BAK" ] || cp -p "$CFG" "$BAK"
    rm -rf "$SE"
    cp -r "$TB/ze/split-executor" "$SE"
    sb="$(sed -n 's/^SbatchPath: *//p' "$BAK" | tr -d '"')"
    cat >"$SE/split.conf" <<CONF
REAL_SBATCH=$sb
REAL_SQUEUE=$(sed -n 's/^SqueuePath: *//p' "$BAK" | tr -d '"')
REAL_SCANCEL=$(sed -n 's/^ScancelPath: *//p' "$BAK" | tr -d '"')
REAL_SCONTROL=$(dirname "$sb")/scontrol
CONF
    mkdir -p "$SE/jobs"
    chmod 755 "$SE/sbatch" "$SE/squeue" "$SE/scancel"
    chown -R lisa:lisa "$SE"
    # Read the whole help first: 'singularity ... | grep -q' fails under pipefail (SIGPIPE, 141).
    help="$(singularity exec --help 2>&1 || true)"
    case "$help" in
      *--no-eval*) ;;
      *) log "ERROR: this Singularity/Apptainer has no --no-eval (needed for ARGO_TEMPLATE): $(singularity --version 2>&1)"; exit 1;;
    esac
    # Container semantics closer to Kubernetes: --no-eval (env values not evaluated a second time)
    # and --contain (each container gets its own /tmp, instead of the compute node's shared /tmp).
    for opt in --contain --no-eval; do
      grep -q -- "\"$opt\"" "$CFG" || sed -i "/^SingularityDefaultOptions:/a\\  - \"$opt\"" "$CFG"
    done
    sed -i -e "s#^SbatchPath: .*#SbatchPath: \"$SE/sbatch\"#" \
           -e "s#^SqueuePath: .*#SqueuePath: \"$SE/squeue\"#" \
           -e "s#^ScancelPath: .*#ScancelPath: \"$SE/scancel\"#" \
           -e 's#^CommandPrefix: .*#CommandPrefix: ""#' "$CFG"
    restart_sidecar
    grep -E '^(SbatchPath|SqueuePath|ScancelPath|CommandPrefix|ImagePrefix):' "$CFG"
    sed -n '/^SingularityDefaultOptions:/,/^[A-Za-z]/p' "$CFG"
    cat "$SE/split.conf"
    ;;
  disable)
    lisa_ssh "systemctl --user stop split-api-relay" >/dev/null 2>&1 || true
    if [ -f "$BAK" ]; then
      cp -p "$BAK" "$CFG"
      rm -f "$BAK"
      restart_sidecar
    fi
    grep -E '^(SbatchPath|SqueuePath|ScancelPath|CommandPrefix|ImagePrefix):' "$CFG"
    ;;
  relay)
    RD="$SE/relay"
    case "${2:-}" in
      on)
        [ -d "$SE/api-relay" ] || { log "ERROR: run 'enable' first"; exit 1; }
        mkdir -p "$RD"; chown lisa:lisa "$RD"
        chmod 0755 "$SE/api-relay/split-relay" "$SE"/api-relay/bin/split-relay-linux-*
        lisa_ssh "bash $SE/api-relay/make-certs.sh $RD"
        : >"$RD/relay.log"; chown lisa:lisa "$RD/relay.log"
        lisa_ssh "systemctl --user stop split-api-relay >/dev/null 2>&1; systemctl --user reset-failed split-api-relay >/dev/null 2>&1; \
          systemd-run --user --quiet --unit=split-api-relay -p Restart=always \
            -p StandardOutput=append:$RD/relay.log -p StandardError=append:$RD/relay.log \
            $SE/api-relay/split-relay login --api-port 16443 --ctl-port 16444 --cert $RD/server.crt --key $RD/server.key"
        sleep 2
        lisa_ssh "systemctl --user is-active split-api-relay" || { tail -n 20 "$RD/relay.log"; exit 1; }
        tail -n 1 "$RD/relay.log"
        ;;
      off) lisa_ssh "systemctl --user stop split-api-relay" >/dev/null 2>&1 || true;;
      *) echo "relay on|off" >&2; exit 2;;
    esac
    ;;
  relay-log)
    cat "$SE/relay/relay.log" 2>/dev/null || true
    ;;
  api-check)
    curl -sk -m 5 -o /dev/null -w '%{http_code}\n' "https://$ULISSES_IP:6443/version" || true
    ;;
  *) echo "usage: $0 enable | disable | relay on|off | relay-log | api-check" >&2; exit 2;;
esac
