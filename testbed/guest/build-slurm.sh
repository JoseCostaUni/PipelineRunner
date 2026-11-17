#!/bin/bash
# Build Slurm RPMs (Deucalion runs Slurm 23.11.4) into /opt/rpms. Reuses /opt/testbed/rpms (host cache) if present.
source /opt/testbed/guest/lib.sh
OUT=/opt/rpms
V="$SLURM_VERSION"

# Rocky 9 uses cgroup v2: slurmd refuses to start without the cgroup/v2 plugin,
# which is only built when dbus-devel is installed.
has_cgroup_v2() { ls "$1"/slurm-"$V"-*.rpm >/dev/null 2>&1 && rpm -qlp "$1"/slurm-"$V"-*.rpm 2>/dev/null | grep -q 'cgroup_v2\.so$'; }

if has_cgroup_v2 "$OUT"; then
  log "Slurm $V packages already in $OUT"
  exit 0
fi
rm -rf "$OUT"; mkdir -p "$OUT"
if has_cgroup_v2 "$TB/rpms"; then
  log "using cached Slurm $V packages"
  cp "$TB"/rpms/*.rpm "$OUT"/
  chmod -R a+rX "$OUT"
  exit 0
fi

log "building Slurm $V from source (about 10-15 minutes)"
dnf -y install rpm-build gcc make perl perl-devel python3 dnf-plugins-core dbus-devel
B=/root/slurm-build
rm -rf "$B" /root/rpmbuild/RPMS; mkdir -p "$B"; cd "$B"
if ! curl -fsSL -o "slurm-$V.tar.bz2" "https://download.schedmd.com/slurm/slurm-$V.tar.bz2"; then
  log "SchedMD download failed, using the GitHub tag"
  TAG="slurm-$(echo "$V" | tr . -)-1"
  curl -fsSL -o gh.tar.gz "https://github.com/SchedMD/slurm/archive/refs/tags/$TAG.tar.gz"
  tar xzf gh.tar.gz
  mv "slurm-$TAG" "slurm-$V"
  tar cjf "slurm-$V.tar.bz2" "slurm-$V"
  rm -rf "slurm-$V" gh.tar.gz
fi
tar xjf "slurm-$V.tar.bz2" "slurm-$V/slurm.spec"
dnf -y builddep "slurm-$V/slurm.spec"
rpmbuild -ta "slurm-$V.tar.bz2" 2>&1 | tail -n 20
cp /root/rpmbuild/RPMS/*/slurm-*.rpm "$OUT"/
chmod -R a+rX "$OUT"
has_cgroup_v2 "$OUT" || { log "ERROR: the Slurm build has no cgroup/v2 plugin"; exit 1; }
ls -1 "$OUT"
log "Slurm build done"
