#!/bin/bash
# Re-apply host names, network mode, clocks and services after a restart or an IP change. (as root)
source /opt/testbed/guest/lib.sh
install_hosts
ROLE="$(cat /etc/testbed/role 2>/dev/null || echo unknown)"
case "$ROLE" in
  cn)
    install -m 755 "$TB/guest/netmode.sh" /usr/local/sbin/testbed-netmode
    /usr/local/sbin/testbed-netmode apply >/dev/null
    systemctl restart chronyd
    systemctl restart slurmctld slurmd
    scontrol update NodeName=cn State=RESUME 2>/dev/null || true
    ;;
  login)
    # Only when ulisses exists (Stage B): the login node cannot open connections to it.
    if grep -q '^ULISSES_IP=' /etc/testbed/ips.env 2>/dev/null; then
      bash "$TB/guest/loginnet.sh" apply >/dev/null
    fi
    systemctl restart chronyd
    chronyc -a makestep >/dev/null 2>&1 || true
    systemctl restart remote-fs.target || true
    ;;
  ulisses)
    docker start minio >/dev/null 2>&1 || true
    if [ -f /var/lib/testbed-files/mc ] && ! systemctl is-active -q testbed-files; then
      systemd-run --unit=testbed-files --property=Restart=always \
        python3 -m http.server 8099 --directory /var/lib/testbed-files >/dev/null 2>&1 || true
    fi
    load_ips
    il_set_sidecar_host "$ULISSES_IP"
    systemctl restart interlink-tunnel 2>/dev/null || true
    ;;
esac
log "refreshed ($ROLE)"
