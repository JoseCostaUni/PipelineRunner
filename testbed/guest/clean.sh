#!/bin/bash
# Remove what the tests and checks left behind, without rebuilding anything. (as root, any VM)
#   clean.sh all    everything below (used by './testbed clean')
#   clean.sh jobs   only the running work: Kubernetes Jobs and pods of the tests, Slurm jobs, and
#                   (on login) the interLink job folders.
#   clean.sh slurm  only cancel lisa's Slurm jobs (login).
#
#   ulisses: workflows, CronWorkflows, Jobs, pods on the virtual node
#   login:   Slurm jobs; interLink job folders; pre-pulled images and check files on the shared FS;
#            Singularity caches; the sidecar restarted
#   cn:      network mode back to 'normal'; Singularity caches; node state RESUME
source /opt/testbed/guest/lib.sh
WHAT="${1:-all}"
ROLE="$(cat /etc/testbed/role 2>/dev/null || echo unknown)"

k8s_jobs() {
  export KUBECONFIG=/etc/kubernetes/admin.conf
  local ns i n
  # Jobs first: a failed Job keeps creating pods (backoffLimit 6) after Argo has moved on.
  for ns in default argo; do
    kubectl delete jobs --all -n "$ns" --wait=false >/dev/null 2>&1 || true
  done
  kubectl delete pods -A --field-selector spec.nodeName=interlink-node --wait=false >/dev/null 2>&1 || true
  # Pods on the virtual node are removed through interLink (which cancels the Slurm job); force
  # them out if the HPC side does not answer within a minute.
  for i in $(seq 1 12); do
    n="$(kubectl get pods -A --field-selector spec.nodeName=interlink-node --no-headers 2>/dev/null | wc -l)"
    [ "$n" -eq 0 ] && break
    sleep 5
  done
  kubectl delete pods -A --field-selector spec.nodeName=interlink-node --force --grace-period=0 >/dev/null 2>&1 || true
}

sing_caches() {
  rm -rf /root/.apptainer/cache /root/.singularity/cache
  rm -rf /home/lisa/.apptainer/cache /home/lisa/.singularity/cache 2>/dev/null || true
}

case "$ROLE:$WHAT" in
  ulisses:all)
    export KUBECONFIG=/etc/kubernetes/admin.conf
    for ns in default argo; do
      argo cron delete --all -n "$ns" >/dev/null 2>&1 || true
      argo delete --all -n "$ns" >/dev/null 2>&1 || true
    done
    k8s_jobs
    log "ulisses clean: workflows, Jobs and pods removed"
    ;;
  ulisses:jobs)
    k8s_jobs
    log "ulisses: Jobs and pods removed"
    ;;
  login:slurm)
    scancel -u lisa 2>/dev/null || true
    ;;
  login:jobs|login:all)
    scancel -u lisa 2>/dev/null || true
    sleep 2
    rm -rf "${HPC_ROOT:?}/.interlink/jobs/"*
    if [ "$WHAT" = all ]; then
      rm -rf /projects/.testbed/images /projects/.testbed/lisa /projects/.testbed/ino
      sing_caches
      # The sidecar drops whatever it still remembers about old pods.
      lisa_ssh "systemctl --user restart interlink-sidecar" >/dev/null 2>&1 || true
      log "login clean: Slurm jobs, job folders, images and caches removed"
    else
      log "login: Slurm jobs cancelled, job folders removed"
    fi
    ;;
  cn:all)
    bash "$TB/guest/netmode.sh" normal >/dev/null
    sing_caches
    scontrol update NodeName=cn State=RESUME >/dev/null 2>&1 || true
    log "cn clean: network mode 'normal', caches removed"
    ;;
  *:jobs|*:slurm|cn:*) ;;
  *) echo "usage: $0 all|jobs|slurm (role: $ROLE)" >&2; exit 2;;
esac
