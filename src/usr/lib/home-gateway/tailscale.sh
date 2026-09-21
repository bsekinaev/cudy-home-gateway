#!/bin/sh
# Read-only статус Tailscale CUDY Home Gateway.

hg_tailscale_collect() {
    HG_TAILSCALE_STATE='UNKNOWN'
    HG_TAILSCALE_VERSION=''
    HG_TAILSCALE_SERVICE_STATE='UNKNOWN'
    HG_TAILSCALE_AUTOSTART='unknown'
    HG_TAILSCALE_BACKEND_STATE='UNKNOWN'
    HG_TAILSCALE_INTERFACE="${HG_TAILSCALE_INTERFACE:-tailscale0}"
    HG_TAILSCALE_INTERFACE_STATE='UNKNOWN'
    HG_TAILSCALE_IPV4=''
    HG_TAILSCALE_IPV6=''
    HG_TAILSCALE_HOSTNAME=''
    HG_TAILSCALE_DNS_NAME=''
    HG_TAILSCALE_ONLINE='unknown'
    HG_TAILSCALE_TAILNET=''
    HG_TAILSCALE_EXIT_NODE_ACTIVE='unknown'
    HG_TAILSCALE_ROUTE_TABLE="${HG_TAILSCALE_ROUTE_TABLE:-52}"
    HG_TAILSCALE_ROUTING_STATE='UNKNOWN'
    HG_TAILSCALE_IPV4_ROUTES=''
    HG_TAILSCALE_IPV6_ROUTES=''

    tailscale_bin="${HG_TAILSCALE_BIN:-tailscale}"
    init_script="${HG_TAILSCALE_INIT_SCRIPT:-/etc/init.d/tailscale}"
    status_file="/tmp/home-gateway-tailscale.$$.json"
    status_json_ok=0

    if command -v "$tailscale_bin" >/dev/null 2>&1; then
        HG_TAILSCALE_VERSION="$(
            "$tailscale_bin" version 2>/dev/null |
                sed -n '1p'
        )"
    fi

    if [ -x "$init_script" ]; then
        if "$init_script" running >/dev/null 2>&1; then
            HG_TAILSCALE_SERVICE_STATE='OK'
        else
            HG_TAILSCALE_SERVICE_STATE='DOWN'
        fi

        if "$init_script" enabled >/dev/null 2>&1; then
            HG_TAILSCALE_AUTOSTART='true'
        else
            HG_TAILSCALE_AUTOSTART='false'
        fi
    else
        HG_TAILSCALE_SERVICE_STATE='DOWN'
    fi

    if command -v ip >/dev/null 2>&1; then
        if ip link show dev "$HG_TAILSCALE_INTERFACE" >/dev/null 2>&1; then
            HG_TAILSCALE_INTERFACE_STATE='OK'

            HG_TAILSCALE_IPV4="$(
                ip -4 addr show dev "$HG_TAILSCALE_INTERFACE" 2>/dev/null |
                    awk '
                        $1 == "inet" {
                            split($2, address, "/")
                            print address[1]
                            exit
                        }
                    '
            )"

            HG_TAILSCALE_IPV6="$(
                ip -6 addr show dev "$HG_TAILSCALE_INTERFACE" 2>/dev/null |
                    awk '
                        $1 == "inet6" && $3 == "scope" && $4 == "global" {
                            split($2, address, "/")
                            print address[1]
                            exit
                        }
                    '
            )"
        else
            HG_TAILSCALE_INTERFACE_STATE='DOWN'
        fi

        HG_TAILSCALE_IPV4_ROUTES="$(
            ip route show table "$HG_TAILSCALE_ROUTE_TABLE" 2>/dev/null |
                awk -v interface="$HG_TAILSCALE_INTERFACE" '
                    index($0, "dev " interface) { count++ }
                    END { print count + 0 }
                '
        )"

        HG_TAILSCALE_IPV6_ROUTES="$(
            ip -6 route show table "$HG_TAILSCALE_ROUTE_TABLE" 2>/dev/null |
                awk -v interface="$HG_TAILSCALE_INTERFACE" '
                    index($0, "dev " interface) { count++ }
                    END { print count + 0 }
                '
        )"

        if ip rule show 2>/dev/null |
            awk -v table="$HG_TAILSCALE_ROUTE_TABLE" '
                index($0, "lookup " table) { found = 1 }
                END { exit(found ? 0 : 1) }
            '; then
            HG_TAILSCALE_ROUTING_STATE='OK'
        else
            HG_TAILSCALE_ROUTING_STATE='DOWN'
        fi
    fi

    if command -v "$tailscale_bin" >/dev/null 2>&1 && \
       command -v jsonfilter >/dev/null 2>&1; then
        if "$tailscale_bin" status --json >"$status_file" 2>/dev/null; then
            status_json_ok=1
            HG_TAILSCALE_BACKEND_STATE="$(
                jsonfilter -i "$status_file" -e '@.BackendState' 2>/dev/null || true
            )"
            HG_TAILSCALE_HOSTNAME="$(
                jsonfilter -i "$status_file" -e '@.Self.HostName' 2>/dev/null || true
            )"
            HG_TAILSCALE_DNS_NAME="$(
                jsonfilter -i "$status_file" -e '@.Self.DNSName' 2>/dev/null || true
            )"
            HG_TAILSCALE_ONLINE="$(
                jsonfilter -i "$status_file" -e '@.Self.Online' 2>/dev/null || true
            )"
            HG_TAILSCALE_TAILNET="$(
                jsonfilter -i "$status_file" -e '@.CurrentTailnet.Name' 2>/dev/null || true
            )"

            exit_node_id="$(
                jsonfilter -i "$status_file" -e '@.ExitNodeStatus.ID' 2>/dev/null || true
            )"
            if [ -n "$exit_node_id" ]; then
                HG_TAILSCALE_EXIT_NODE_ACTIVE='true'
            else
                HG_TAILSCALE_EXIT_NODE_ACTIVE='false'
            fi
        fi
    fi
    rm -f "$status_file"

    if [ "$status_json_ok" -eq 0 ]; then
        HG_TAILSCALE_BACKEND_STATE='UNKNOWN'
        HG_TAILSCALE_ONLINE='unknown'
        HG_TAILSCALE_EXIT_NODE_ACTIVE='unknown'
    fi

    if [ -n "${HG_TAILSCALE_BACKEND_OVERRIDE:-}" ]; then
        HG_TAILSCALE_BACKEND_STATE="$HG_TAILSCALE_BACKEND_OVERRIDE"
    fi

    case "$HG_TAILSCALE_ONLINE" in
        true|false) ;;
        *) HG_TAILSCALE_ONLINE='unknown' ;;
    esac

    case "$HG_TAILSCALE_SERVICE_STATE" in
        DOWN)
            HG_TAILSCALE_STATE='DOWN'
            ;;
        OK)
            if [ "$HG_TAILSCALE_INTERFACE_STATE" = 'DOWN' ]; then
                HG_TAILSCALE_STATE='DOWN'
            elif [ "$HG_TAILSCALE_BACKEND_STATE" != 'Running' ] || \
                 [ -z "$HG_TAILSCALE_IPV4" ] || \
                 [ "$HG_TAILSCALE_ONLINE" != 'true' ] || \
                 [ "$HG_TAILSCALE_AUTOSTART" != 'true' ] || \
                 [ "$HG_TAILSCALE_ROUTING_STATE" != 'OK' ]; then
                HG_TAILSCALE_STATE='DEGRADED'
            elif [ "$HG_TAILSCALE_INTERFACE_STATE" = 'OK' ]; then
                HG_TAILSCALE_STATE='OK'
            fi
            ;;
    esac
}
