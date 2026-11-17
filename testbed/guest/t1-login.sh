#!/bin/bash
# Experiment T1, HPC side (as root on the login node).
#   prepare-images EXECIMG     pull alpine:3.20 and the argoexec image to the shared FS, at the
#                              paths the plugin builds from the image-root annotation
#   cmdprefix off|on           T1 offloads a standard workflow, so her data wrapper (CommandPrefix)
#                              is switched off for the run and restored afterwards
#   collect RUN MODE UID       copy the pod's job folder (job.slurm, job.sh, per-container output
#                              and .status files) and the sidecar log lines for that pod
#   pack RUN                   archive the results for the host
source /opt/testbed/guest/lib.sh
IL="$HPC_ROOT/.interlink"
CFG="$IL/SlurmConfig.yaml"
SAVED="$IL/.commandprefix.t1-saved"
JOBS="$IL/jobs"
IMG=/projects/.testbed/images
OUT=/var/tmp/t1-jobs

restart_sidecar() { lisa_ssh "systemctl --user restart interlink-sidecar"; sleep 8; }

case "${1:-}" in
  prepare-images)
    EXEC="$2"
    for ref in alpine:3.20 "$EXEC"; do
      dest="$IMG/$ref"
      mkdir -p "$(dirname "$dest")"
      [ -s "$dest" ] || singularity pull "$dest" "docker://$ref"
    done
    chown -R lisa:lisa "$IMG"
    chmod -R a+rX "$IMG"
    find "$IMG" -type f -exec ls -l {} +
    ;;
  cmdprefix)
    case "$2" in
      off)
        cur="$(sed -n 's/^CommandPrefix: *//p' "$CFG")"
        if [ "$cur" != '""' ] && [ -n "$cur" ]; then
          echo "$cur" >"$SAVED"
          sed -i 's#^CommandPrefix: .*#CommandPrefix: ""#' "$CFG"
          restart_sidecar
        fi
        ;;
      on)
        if [ -f "$SAVED" ]; then
          val="$(cat "$SAVED")"
          sed -i "s#^CommandPrefix: .*#CommandPrefix: $val#" "$CFG"
          rm -f "$SAVED"
          restart_sidecar
        fi
        ;;
      *) echo "cmdprefix off|on" >&2; exit 2;;
    esac
    grep '^CommandPrefix' "$CFG"
    ;;
  collect)
    RUN="$2" MODE="$3" UID_="$4"
    D="$OUT-$RUN/$MODE"
    mkdir -p "$D/job"
    if [ -d "$JOBS/default-$UID_" ]; then
      # Small files only: the emptyDir folders may hold the downloaded artifacts.
      rsync -a --max-size=5m "$JOBS/default-$UID_/" "$D/job/"
      find "$JOBS/default-$UID_" -printf '%y %s %p\n' >"$D/job-tree.txt" 2>/dev/null || true
    else
      echo "job folder $JOBS/default-$UID_ not found" >"$D/job-tree.txt"
    fi
    grep -F "$UID_" "$IL/sidecar.log" 2>/dev/null | tail -n 300 >"$D/sidecar.txt" || true
    chmod -R a+rX "$D"
    ;;
  collect-test) # RUN DEST UID... : one call per test instead of one per pod. Prints, per pod,
    # main's exit status and last line of output, and what the login side said last.
    RUN="$2" DEST="$3"; shift 3
    for u in "$@"; do
      bash "$0" collect "$RUN" "$DEST/$u" "$u" >/dev/null 2>&1 || true
      j="$OUT-$RUN/$DEST/$u/job"
      last() { grep -v -E '^\s*$|^(real|user|sys)\s' "$1" 2>/dev/null | tail -n 1 | cut -c1-160; }
      out="$(last "$j/run-main.out")"
      [ -n "$out" ] || out="(no output from main) job.out: $(last "$j/job.out")"
      printf 'pod %s: main exit %s: %s | login: %s\n' "${u:0:8}" "$( { tr -dc '0-9' <"$j/run-main.status"; } 2>/dev/null || echo '?')" \
        "$out" "$(last "$j/login.out")"
    done
    ;;
  pack)
    RUN="$2"
    tar czf "/var/tmp/t1-jobs-$RUN.tar.gz" -C "$OUT-$RUN" .
    chmod 644 "/var/tmp/t1-jobs-$RUN.tar.gz"
    ;;
  *) echo "usage: $0 prepare-images EXECIMG | cmdprefix off|on | collect RUN MODE UID | pack RUN" >&2; exit 2;;
esac
