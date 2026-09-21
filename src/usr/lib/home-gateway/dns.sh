#!/bin/sh
# Read-only DNS и AdBlock-Fast статус CUDY Home Gateway.

hg_dns_collect() {
    HG_DNS_STATE='UNKNOWN'
    HG_DNS_DNSMASQ_STATE='UNKNOWN'
    HG_DNS_PORT=''
    HG_DNS_RESOLUTION_STATE='UNKNOWN'
    HG_DNS_PROBE_DOMAIN="${HG_DNS_PROBE_DOMAIN:-openwrt.org}"
    HG_DNS_RESOLV_FILE=''
    HG_DNS_UPSTREAM_SERVERS=''

    HG_DNS_ADBLOCK_STATE='UNKNOWN'
    HG_DNS_ADBLOCK_CONFIGURED='unknown'
    HG_DNS_ADBLOCK_AUTOSTART='unknown'
    HG_DNS_ADBLOCK_BACKEND=''
    HG_DNS_ADBLOCK_RUNTIME_FILE=''
    HG_DNS_ADBLOCK_RUNTIME_LINES=''
    HG_DNS_ADBLOCK_RUNTIME_BYTES=''
    HG_DNS_ADBLOCK_ATTACHED='unknown'
    HG_DNS_ADBLOCK_ATTACHED_CONFIGS=''

    if command -v uci >/dev/null 2>&1; then
        HG_DNS_PORT="$(uci -q get 'dhcp.@dnsmasq[0].port' 2>/dev/null || true)"
        HG_DNS_RESOLV_FILE="$(uci -q get 'dhcp.@dnsmasq[0].resolvfile' 2>/dev/null || true)"
    fi

    # Пустой port в UCI означает стандартный DNS-порт dnsmasq.
    [ -n "$HG_DNS_PORT" ] || HG_DNS_PORT='53'
    [ -n "$HG_DNS_RESOLV_FILE" ] || HG_DNS_RESOLV_FILE='/tmp/resolv.conf.d/resolv.conf.auto'

    if ps w 2>/dev/null | grep -q '[u]sr/sbin/dnsmasq'; then
        HG_DNS_DNSMASQ_STATE='OK'
    else
        HG_DNS_DNSMASQ_STATE='DOWN'
    fi

    if [ "$HG_DNS_DNSMASQ_STATE" = 'OK' ]; then
        if command -v nslookup >/dev/null 2>&1; then
            if nslookup "$HG_DNS_PROBE_DOMAIN" 127.0.0.1 >/dev/null 2>&1; then
                HG_DNS_RESOLUTION_STATE='OK'
            else
                HG_DNS_RESOLUTION_STATE='DOWN'
            fi
        fi
    else
        HG_DNS_RESOLUTION_STATE='DOWN'
    fi

    if [ -r "$HG_DNS_RESOLV_FILE" ]; then
        HG_DNS_UPSTREAM_SERVERS="$(
            awk '/^[[:space:]]*nameserver[[:space:]]+/ { print $2 }' "$HG_DNS_RESOLV_FILE" 2>/dev/null |
                awk 'NF { if (out != "") out = out " "; out = out $1 } END { print out }'
        )"
    fi

    # AdBlock-Fast — генератор правил для dnsmasq, а не обязательный постоянный daemon.
    # Поэтому /etc/init.d/adblock-fast running не используется как health-сигнал.
    if command -v uci >/dev/null 2>&1; then
        adblock_enabled="$(uci -q get adblock-fast.config.enabled 2>/dev/null || true)"
        HG_DNS_ADBLOCK_BACKEND="$(uci -q get adblock-fast.config.dns 2>/dev/null || true)"

        case "$adblock_enabled" in
            1) HG_DNS_ADBLOCK_CONFIGURED='true' ;;
            0) HG_DNS_ADBLOCK_CONFIGURED='false' ;;
        esac
    fi

    if [ -x /etc/init.d/adblock-fast ]; then
        if /etc/init.d/adblock-fast enabled >/dev/null 2>&1; then
            HG_DNS_ADBLOCK_AUTOSTART='true'
        else
            HG_DNS_ADBLOCK_AUTOSTART='false'
        fi
    fi

    if [ -n "${HG_ADBLOCK_RUNTIME_FILE:-}" ]; then
        HG_DNS_ADBLOCK_RUNTIME_FILE="$HG_ADBLOCK_RUNTIME_FILE"
    elif [ -n "$HG_DNS_ADBLOCK_BACKEND" ]; then
        HG_DNS_ADBLOCK_RUNTIME_FILE="/var/run/adblock-fast/${HG_DNS_ADBLOCK_BACKEND}"
    else
        HG_DNS_ADBLOCK_RUNTIME_FILE='/var/run/adblock-fast/dnsmasq.servers'
    fi

    if [ -s "$HG_DNS_ADBLOCK_RUNTIME_FILE" ]; then
        HG_DNS_ADBLOCK_RUNTIME_LINES="$(wc -l <"$HG_DNS_ADBLOCK_RUNTIME_FILE" 2>/dev/null | awk '{print $1}')"
        HG_DNS_ADBLOCK_RUNTIME_BYTES="$(wc -c <"$HG_DNS_ADBLOCK_RUNTIME_FILE" 2>/dev/null | awk '{print $1}')"
    fi

    if grep -qF "servers-file=$HG_DNS_ADBLOCK_RUNTIME_FILE" /var/etc/dnsmasq.conf.* 2>/dev/null; then
        HG_DNS_ADBLOCK_ATTACHED='true'
    else
        HG_DNS_ADBLOCK_ATTACHED='false'
    fi

    HG_DNS_ADBLOCK_ATTACHED_CONFIGS="$(
        grep -lF "servers-file=$HG_DNS_ADBLOCK_RUNTIME_FILE" \
            /var/etc/dnsmasq.conf.* \
            /var/etc/passwall2/acl/*_dnsmasq.conf \
            2>/dev/null |
            wc -l |
            awk '{print $1}'
    )"

    case "$HG_DNS_ADBLOCK_CONFIGURED" in
        true)
            if [ -n "$HG_DNS_ADBLOCK_RUNTIME_LINES" ] && \
               [ "$HG_DNS_ADBLOCK_ATTACHED" = 'true' ]; then
                HG_DNS_ADBLOCK_STATE='OK'
            else
                HG_DNS_ADBLOCK_STATE='DEGRADED'
            fi
            ;;
        false)
            HG_DNS_ADBLOCK_STATE='DOWN'
            ;;
        *)
            HG_DNS_ADBLOCK_STATE='UNKNOWN'
            ;;
    esac

    case "$HG_DNS_DNSMASQ_STATE:$HG_DNS_RESOLUTION_STATE" in
        OK:OK)
            HG_DNS_STATE='OK'
            ;;
        DOWN:*|*:DOWN)
            HG_DNS_STATE='DOWN'
            ;;
        OK:UNKNOWN)
            HG_DNS_STATE='DEGRADED'
            ;;
        *)
            HG_DNS_STATE='UNKNOWN'
            ;;
    esac
}
