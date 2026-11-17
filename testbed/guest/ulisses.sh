#!/bin/bash
# 'ulisses': the Kubernetes side of the FEUP prototype, plus the Global Storage (MinIO). (as root)
# Runs Isabel Moutinho's own setup scripts; the only change is the CPU architecture of downloads.
source /opt/testbed/guest/lib.sh
load_ips
L=/opt/lpr

mkdir -p /etc/testbed
echo ulisses >/etc/testbed/role
install_hosts

log "prerequisites her scripts expect on the host (htpasswd, envsubst, wget, ssh, jq)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apache2-utils gettext-base wget openssh-client jq curl rsync gpg diffutils ca-certificates

log "SSH key for the tunnel to lisa@login (her SIDECAR_SSH_KEY_PATH)"
install -d -m 700 /root/.ssh
install -m 600 "$TB/state/lisa_ed25519" /root/.ssh/id_ed25519

if [ ! -f /etc/testbed/.k8s-done ]; then
  log "copy of Isabel's repository, arm64 downloads"
  rm -rf "$L"
  cp -r "$TB/lpr" "$L"
  patch_arch "$L"
  diff -ru "$TB/lpr" "$L" >/var/tmp/lpr-changes.diff || true
  cat /var/tmp/lpr-changes.diff

  log "her setup/kubernetes/.env: .env.example plus the testbed values"
  cd "$L/setup/kubernetes"
  cp .env.example .env
  cat >>.env <<EOF

# --- testbed values (appended; later assignments win)
MACHINE_HOST=$ULISSES_IP
SIDECAR_SSH_USER=lisa
SIDECAR_SSH_HOST=$LOGIN_IP
SIDECAR_SSH_KEY_PATH=/root/.ssh/id_ed25519
SIDECAR_LOCAL_HOST=$ULISSES_IP
SLURM_ACCOUNT=testbed
SLURM_PARTITION=arm
EOF
  log "running her setup/kubernetes/main.sh (kubeadm, Calico, Argo, Dex, interLink, templates)"
  bash main.sh
  touch /etc/testbed/.k8s-done
else
  log "Kubernetes side already set up"
fi
il_set_sidecar_host "$ULISSES_IP"

log "Global Storage: her setup/global_storage/main.sh (Docker + MinIO)"
# MinIO stopped publishing free images in October 2025: her image (quay.io/minio/minio) may be
# refused. Use the first image that can still be pulled; any change is printed below.
MINIO_IMAGES="quay.io/minio/minio docker.io/minio/minio:latest docker.io/pgsty/minio:latest"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx minio; then
  docker start minio >/dev/null
else
  command -v docker >/dev/null 2>&1 || { apt-get install -y docker.io; systemctl enable --now docker; }
  IMG=""
  for c in $MINIO_IMAGES; do
    if docker pull "$c" >/dev/null 2>&1; then IMG="$c"; break; fi
    log "image not available: $c"
  done
  [ -n "$IMG" ] || { log "ERROR: no MinIO image could be pulled ($MINIO_IMAGES)"; exit 1; }
  GS="$L/setup/global_storage"
  if [ "$IMG" != "quay.io/minio/minio" ]; then
    rm -rf /var/tmp/global_storage
    cp -r "$GS" /var/tmp/global_storage
    GS=/var/tmp/global_storage
    sed -i "s#quay.io/minio/minio#$IMG#" "$GS/main.sh"
    log "CHANGE to her global_storage/main.sh: image quay.io/minio/minio -> $IMG"
    diff -u "$L/setup/global_storage/main.sh" "$GS/main.sh" || true
  fi
  (cd "$GS" && bash main.sh)
fi
for i in $(seq 1 60); do
  curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null && break
  sleep 2
done
curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null || { log "ERROR: MinIO did not start"; exit 1; }

log "MinIO client (mc): dl.min.io, or extracted from a client image if that is gone"
MC_URL=https://dl.min.io/client/mc/release/linux-arm64/mc
mkdir -p /var/lib/testbed-files
if [ ! -x /usr/local/bin/mc ]; then
  if curl -fsSL -o /usr/local/bin/mc "$MC_URL"; then
    echo "$MC_URL" >/var/lib/testbed-files/mc.source
  else
    for c in docker.io/minio/mc:latest docker.io/pgsty/mc:latest; do
      if docker pull "$c" >/dev/null 2>&1; then
        id="$(docker create "$c")"
        docker cp "$id:/usr/bin/mc" /usr/local/bin/mc && echo "$c" >/var/lib/testbed-files/mc.source
        docker rm "$id" >/dev/null
        [ -s /usr/local/bin/mc ] && break
      fi
    done
  fi
  [ -s /usr/local/bin/mc ] || { log "ERROR: could not get the MinIO client"; exit 1; }
  chmod +x /usr/local/bin/mc
fi
log "mc from: $(cat /var/lib/testbed-files/mc.source 2>/dev/null || echo unknown)"
# Serve this mc to the login node, in case dl.min.io (used by her 2-data.sh) is gone.
cp /usr/local/bin/mc /var/lib/testbed-files/mc
if ! systemctl is-active -q testbed-files; then
  systemd-run --unit=testbed-files --property=Restart=always \
    python3 -m http.server 8099 --directory /var/lib/testbed-files >/dev/null
fi

log "Argo CLI (for submitting the tests; not part of her stack)"
if [ ! -x /usr/local/bin/argo ]; then
  # shellcheck disable=SC1091
  ARGO_VERSION="$(. "$L/setup/kubernetes/.env"; echo "$ARGO_VERSION")"
  curl -fsSL "https://github.com/argoproj/argo-workflows/releases/download/$ARGO_VERSION/argo-linux-arm64.gz" | gunzip >/usr/local/bin/argo
  chmod +x /usr/local/bin/argo
fi

log "test datasets into the Global Storage (her README: 'add the files in tests/datasets to MinIO')"
mc alias set gs http://127.0.0.1:9000 admin admin123 >/dev/null
mc mb -p gs/users >/dev/null
mc mirror --overwrite "$L/tests/datasets/users" gs/users

log "nodes"
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
log "ulisses done"
