#!/bin/bash
# Login node: NFS client of the compute node, Slurm client, SSH restrictions, time server. (as root)
source /opt/testbed/guest/lib.sh
load_ips

# NFS options: no attribute or lookup caching, to approximate Lustre's coherent view across nodes.
NFS_OPTS="rw,hard,vers=4.2,lookupcache=none,actimeo=0,_netdev,x-systemd.automount,x-systemd.mount-timeout=30"

log "mounting the shared file system from cn"
mkdir -p /projects /home/lisa
put_block /etc/fstab <<EOF
cn:/srv/nfs/projects   /projects   nfs4 $NFS_OPTS 0 0
cn:/srv/nfs/home-lisa  /home/lisa  nfs4 $NFS_OPTS 0 0
EOF
systemctl daemon-reload
systemctl restart remote-fs.target
for i in $(seq 1 30); do
  if ls /projects/.testbed/slurm.conf >/dev/null 2>&1 && ls /home/lisa/.ssh >/dev/null 2>&1; then break; fi
  sleep 2
done
ls /projects/.testbed/slurm.conf >/dev/null || { log "ERROR: /projects is not mounted from cn"; exit 1; }

log "Slurm client $SLURM_VERSION"
V="$SLURM_VERSION"
dnf -y install /projects/.testbed/rpms/slurm-"$V"-*.rpm /projects/.testbed/rpms/slurm-perlapi-"$V"-*.rpm
mkdir -p /etc/slurm
cp /projects/.testbed/slurm.conf /etc/slurm/slurm.conf

log "SSH: lisa may use ssh -L but not ssh -R (as on Deucalion)"
if ! grep -q '^# testbed: lisa forwarding' /etc/ssh/sshd_config; then
  cat >>/etc/ssh/sshd_config <<'EOF'

# testbed: lisa forwarding
Match User lisa
    AllowTcpForwarding local
    X11Forwarding no
EOF
fi
sshd -t
systemctl restart sshd

log "chrony: login serves time to the cluster network"
put_block /etc/chrony.conf <<EOF
allow $SUBNET
local stratum 10
EOF
systemctl enable --now chronyd
systemctl restart chronyd

log "lingering for lisa (needed by systemd --user services, e.g. the interLink sidecar in Stage B)"
loginctl enable-linger lisa

log "login node done"
sinfo
