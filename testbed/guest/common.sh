#!/bin/bash
# Base setup shared by both nodes. Usage: common.sh cn|login   (as root)
source /opt/testbed/guest/lib.sh
ROLE="${1:?role cn|login}"
load_ips

log "role: $ROLE"
if ! swapon --show | grep -q /swapfile; then
  # The VMs have little RAM; dnf alone can exceed 1 GB while loading the EPEL metadata.
  log "creating a 2 GB swap file"
  [ -f /swapfile ] || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >>/etc/fstab
fi
mkdir -p /etc/testbed
echo "$ROLE" >/etc/testbed/role
install_hosts

log "SELinux permissive, no firewalld (the testbed manages its own nftables rules)"
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || true
systemctl disable --now firewalld 2>/dev/null || true

if [ ! -f /etc/testbed/.repos ]; then
  log "enabling EPEL and CRB"
  dnf -y install dnf-plugins-core epel-release
  dnf config-manager --set-enabled crb
  touch /etc/testbed/.repos
fi

log "installing base packages"
dnf -y --setopt=install_weak_deps=False install nfs-utils nftables chrony munge munge-libs apptainer apptainer-suid \
  inotify-tools wget curl tar bzip2 rsync jq iputils bind-utils git openssh-clients \
  hostname procps-ng perl

log "users: slurm ($SLURM_UID) and lisa ($LISA_UID, no sudo)"
getent group slurm >/dev/null || groupadd -g "$SLURM_UID" slurm
getent passwd slurm >/dev/null || useradd -r -u "$SLURM_UID" -g slurm -d /var/lib/slurm -s /sbin/nologin slurm
getent group lisa >/dev/null || groupadd -g "$LISA_UID" lisa
# -M: the home directory comes from the shared file system (set up by cn.sh / login.sh).
getent passwd lisa >/dev/null || useradd -M -u "$LISA_UID" -g lisa -d /home/lisa -s /bin/bash lisa
rm -f /etc/sudoers.d/lisa

log "NFSv4 id mapping domain"
sed -i 's/^#\? *Domain = .*/Domain = testbed/' /etc/idmapd.conf
grep -q '^Domain = testbed' /etc/idmapd.conf || sed -i '/^\[General\]/a Domain = testbed' /etc/idmapd.conf

log "Munge key"
install -o munge -g munge -m 0400 "$TB/state/munge.key" /etc/munge/munge.key
systemctl enable --now munge
systemctl restart munge

log "chrony: always step the clock (VM clocks jump after the Mac sleeps)"
sed -i 's/^makestep .*/makestep 1 -1/' /etc/chrony.conf
grep -q '^makestep' /etc/chrony.conf || echo 'makestep 1 -1' >>/etc/chrony.conf

log "common setup done"
