#!/bin/bash
# Login node, Stage B: run Isabel's setup/hpc scripts as lisa (interLink Slurm sidecar + data wrapper).
# (as root; the scripts themselves run as lisa in an SSH session, as she ran them on Deucalion)
source /opt/testbed/guest/lib.sh
load_ips

log "copy of Isabel's repository for lisa, arm64 downloads"
rm -rf /var/tmp/lpr
cp -r "$TB/lpr" /var/tmp/lpr
patch_arch /var/tmp/lpr
# Her 2-data.sh downloads mc from dl.min.io. MinIO stopped distributing free builds in 2025; if that
# URL no longer works, take the same client from ulisses (served on port 8099).
MC_URL=https://dl.min.io/client/mc/release/linux-arm64/mc
if ! curl -fsIL -m 20 "$MC_URL" >/dev/null 2>&1; then
  sed -i "s#$MC_URL#http://$ULISSES_IP:8099/mc#" /var/tmp/lpr/setup/hpc/2-data.sh
  log "CHANGE to her 2-data.sh: mc downloaded from ulisses ($MC_URL is not available)"
fi
diff -u "$TB/lpr/setup/hpc/2-data.sh" /var/tmp/lpr/setup/hpc/2-data.sh || true
chmod -R a+rX /var/tmp/lpr

log "testbed values for her setup/hpc/.env"
cat >/var/tmp/hpc.env <<EOF

# --- testbed values (appended; later assignments win)
HPC_PROJECT_ROOT=$HPC_ROOT
HPC_USER=lisa
HPC_WORK=/home/lisa/work
HPC_USER_HOME=/home/lisa
INTERLINK_SIDECAR_VERSION=0.6.1
TSOCKS_LOGIN_NODE=login
MINIO_ACCESS_KEY=admin
MINIO_SECRET_KEY=admin123
MINIO_HOST=$ULISSES_IP
MINIO_PORT=9000
MINIO_SCHEME=http
MINIO_ALIAS=myminio
EOF
chmod 644 /var/tmp/hpc.env

log "running her setup/hpc/main.sh as lisa"
lisa_ssh "bash /opt/testbed/guest/lisa-hpc.sh $HPC_ROOT"
log "login node (Stage B) done"
