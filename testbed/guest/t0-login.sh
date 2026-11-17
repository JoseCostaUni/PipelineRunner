#!/bin/bash
# Experiment T0, HPC side (as root on the login node).
#   prepare-images            pull ubuntu:22.04 (the image of all her templates) to the shared FS
#   set-prefix docker|images  point the sidecar's ImagePrefix to docker:// (her setting) or to the
#                             pre-pulled images, and restart the sidecar
#   reset-data                empty the HPC data folder (keep the per-user folders)
#   watch-start RUN MODE      copy the job folders (job.out etc.) continuously, since the sidecar
#                             deletes them when Kubernetes removes the finished Jobs
#   copy-now RUN MODE         copy the job folders once (before T0 removes a test's leftover Jobs)
#   watch-stop RUN MODE       stop copying and classify every job of this mode
#   pack RUN                  archive the results for the host
source /opt/testbed/guest/lib.sh
IL="$HPC_ROOT/.interlink"
JOBS="$IL/jobs"
IMG=/projects/.testbed/images
OUT=/var/tmp/t0-jobs
PIDF=/var/tmp/t0-watch.pid

# Copy the job folders created since this mode started (marker file $1/.start). T0 also empties the
# jobs folder before each mode ('clean.sh jobs'), because a folder's mtime changes whenever the
# sidecar touches it, so -newer alone lets older folders back in.
copy_jobs() {
  local d="$1" j
  [ -f "$d/.start" ] || return 0
  for j in $(find "$JOBS" -mindepth 1 -maxdepth 1 -type d -newer "$d/.start" 2>/dev/null); do
    rsync -a --include='*.out' --include='*.err' --include='*.sh' --include='*.slurm' \
      --include='*.jid' --include='*.status' --include='*.properties' --exclude='*' \
      "$j/" "$d/$(basename "$j")/" 2>/dev/null || true
  done
}

classify() { # folder of one job -> "CATEGORY<TAB>evidence"
  local d="$1" text cat ev
  text="$(cat "$d"/*.out "$d"/*.err 2>/dev/null || true)"
  if echo "$text" | grep -Eq 'FATAL:.*(docker://|registry|pinging container)'; then cat=IMAGE_PULL
  elif echo "$text" | grep -q '\[wrapper\] input sync ongoing' && ! echo "$text" | grep -q '\[wrapper\] data ready'; then cat=DATA_SYNC_IN
  elif echo "$text" | grep -q '\[wrapper\] output sync ongoing' && ! echo "$text" | grep -q 'output sync complete'; then cat=DATA_SYNC_OUT
  # mc mirror printed an error but exited 0, so the wrapper reported the upload as complete
  elif echo "$text" | grep -q '\[wrapper\] output sync ongoing' && echo "$text" | grep -q 'mc: <ERROR>'; then cat=SYNC_OUT_SILENT
  elif echo "$text" | grep -q '\[wrapper\] done'; then cat=OK
  elif echo "$text" | grep -q '\[wrapper\] launching original job'; then cat=TASK_ERROR
  else cat=OTHER
  fi
  ev="$(echo "$text" | grep -E 'FATAL|ERROR|Error|error|denied|No such|invalid|must start' | head -n 1)"
  [ -n "$ev" ] || ev="$(echo "$text" | grep -v '^\s*$' | tail -n 1)"
  printf '%s\t%s\n' "$cat" "$(echo "$ev" | tr '\t`' '  ' | cut -c1-200)"
}

case "${1:-}" in
  prepare-images)
    mkdir -p "$IMG"
    if [ ! -s "$IMG/ubuntu:22.04" ]; then
      singularity pull "$IMG/ubuntu:22.04" docker://ubuntu:22.04
    fi
    chmod -R a+rX "$IMG"
    ls -l "$IMG"
    ;;
  set-prefix)
    case "$2" in
      docker) val="docker://";;
      images) val="$IMG/";;
      *) echo "set-prefix docker|images" >&2; exit 2;;
    esac
    sed -i "s#^ImagePrefix: .*#ImagePrefix: \"$val\"#" "$IL/SlurmConfig.yaml"
    grep '^ImagePrefix' "$IL/SlurmConfig.yaml"
    lisa_ssh "systemctl --user restart interlink-sidecar"
    sleep 8
    ;;
  reset-data)
    rm -rf "$HPC_ROOT/data/users"
    mkdir -p "$HPC_ROOT/data/users/admin" "$HPC_ROOT/data/users/alice" "$HPC_ROOT/data/users/system"
    chown -R lisa:lisa "$HPC_ROOT/data"
    log "HPC data folder reset"
    ;;
  watch-start)
    RUN="$2" MODE="$3"
    D="$OUT-$RUN/raw/$MODE"
    mkdir -p "$D"
    touch "$D/.start"
    [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null || true
    setsid nohup bash "$TB/guest/t0-login.sh" watch-loop "$D" >/dev/null 2>&1 </dev/null &
    echo $! >"$PIDF"
    log "watching $JOBS -> $D"
    ;;
  copy-now)
    copy_jobs "$OUT-$2/raw/$3"
    ;;
  watch-loop)
    while :; do copy_jobs "$2"; sleep 3; done
    ;;
  watch-stop)
    RUN="$2" MODE="$3"
    D="$OUT-$RUN/raw/$MODE"
    [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null || true
    rm -f "$PIDF"
    copy_jobs "$D"
    mkdir -p "$OUT-$RUN/jobs/$MODE"
    T="$OUT-$RUN/jobs/$MODE/jobs.tsv"
    : >"$T"
    for j in "$D"/*/; do
      [ -d "$j" ] || continue
      printf '%s\t%s\t%s\n' "$MODE" "$(basename "$j")" "$(classify "$j")" >>"$T"
    done
    log "$(wc -l <"$T") jobs classified for $MODE"
    ;;
  pack)
    RUN="$2"
    tar czf "/var/tmp/t0-jobs-$RUN.tar.gz" -C "$OUT-$RUN" jobs raw
    chmod 644 "/var/tmp/t0-jobs-$RUN.tar.gz"
    ;;
  *) echo "usage: $0 prepare-images | set-prefix docker|images | reset-data | watch-start|copy-now|watch-stop RUN MODE | pack RUN" >&2; exit 2;;
esac
