#!/bin/sh /etc/rc.common
# Synthetic rc.common/procd boundary. No real Tailscale binary or VPN traffic.
USE_PROCD=1
START=99
start_service() {
    printf 'start\n' >> /tmp/hg-vm-lab/service-starts
    procd_open_instance
    procd_set_param command /bin/sleep 600
    procd_set_param term_timeout 1
    procd_close_instance
}
