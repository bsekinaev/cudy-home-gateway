#!/bin/sh
# Read-only статус MAIN VPN CUDY Home Gateway.

hg_vpn_is_ipv4() {
    value="$1"

    printf '%s\n' "$value" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
                    exit 1
            }
        }
    '
}

hg_vpn_main_process_running() {
    profile="$1"
    [ -n "$profile" ] || return 1

    config_path="/tmp/etc/passwall2/${profile}.json"
    ps w 2>/dev/null | awk -v config_path="$config_path" '
        index($0, "xray") && index($0, config_path) { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

hg_vpn_collect() {
    HG_VPN_PASSWALL_ENABLED='unknown'
    HG_VPN_MAIN_STATE='UNKNOWN'
    HG_VPN_MAIN_CONFIG_STATE='UNKNOWN'
    HG_VPN_MAIN_PROFILE=''
    HG_VPN_MAIN_PROFILE_ENABLED='unknown'
    HG_VPN_MAIN_NODE=''
    HG_VPN_MAIN_NAME=''
    HG_VPN_MAIN_SOCKS_HOST="${HG_MAIN_SOCKS_HOST:-127.0.0.1}"
    HG_VPN_MAIN_SOCKS_PORT=''
    HG_VPN_MAIN_XRAY_STATE='UNKNOWN'
    HG_VPN_AUTOSWITCH_ENABLED='unknown'
    HG_VPN_BACKUP_NODES=''
    HG_VPN_ACTIVE_NODE=''
    HG_VPN_ACTIVE_NODE_STATE='UNKNOWN'
    HG_VPN_EGRESS_STATE='UNKNOWN'
    HG_VPN_EGRESS_IPV4=''
    HG_VPN_EGRESS_SOURCE='live_probe'
    primary_provider="${HG_MAIN_EGRESS_PROVIDER:-api.ipify.org}"
    secondary_provider="${HG_MAIN_EGRESS_SECONDARY_PROVIDER:-ipv4.icanhazip.com}"
    HG_VPN_EGRESS_PROVIDER=''
    HG_VPN_EGRESS_CHECKED_AT=''
    HG_VPN_EGRESS_PROBE_ATTEMPTS='0'

    egress_cache_file="${HG_MAIN_EGRESS_CACHE_FILE:-/tmp/home-gateway-main-egress.cache}"
    egress_cache_ttl="${HG_MAIN_EGRESS_CACHE_TTL:-300}"
    egress_probe_url="${HG_MAIN_EGRESS_PROBE_URL:-https://api.ipify.org}"
    secondary_probe_url="${HG_MAIN_EGRESS_SECONDARY_PROBE_URL:-https://ipv4.icanhazip.com/}"

    case "$egress_cache_ttl" in
        ''|*[!0-9]*) egress_cache_ttl=300 ;;
    esac

    if ! command -v uci >/dev/null 2>&1; then
        return 0
    fi

    passwall_enabled="$(uci -q get 'passwall2.@global[0].enabled' 2>/dev/null || true)"
    case "$passwall_enabled" in
        1) HG_VPN_PASSWALL_ENABLED='true' ;;
        0) HG_VPN_PASSWALL_ENABLED='false' ;;
    esac

    HG_VPN_MAIN_PROFILE="$(uci -q get passwall2.rulenode.default_node 2>/dev/null || true)"

    if [ -n "$HG_VPN_MAIN_PROFILE" ]; then
        profile_type="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}" 2>/dev/null || true)"
        profile_enabled="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.enabled" 2>/dev/null || true)"
        HG_VPN_MAIN_NODE="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.node" 2>/dev/null || true)"
        HG_VPN_MAIN_SOCKS_PORT="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.port" 2>/dev/null || true)"
        autoswitch_enabled="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.enable_autoswitch" 2>/dev/null || true)"
        HG_VPN_BACKUP_NODES="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.autoswitch_backup_node" 2>/dev/null || true)"

        case "$profile_enabled" in
            1) HG_VPN_MAIN_PROFILE_ENABLED='true' ;;
            0) HG_VPN_MAIN_PROFILE_ENABLED='false' ;;
        esac
        case "$autoswitch_enabled" in
            1) HG_VPN_AUTOSWITCH_ENABLED='true' ;;
            0) HG_VPN_AUTOSWITCH_ENABLED='false' ;;
        esac

        if [ -n "$HG_VPN_MAIN_NODE" ]; then
            HG_VPN_MAIN_NAME="$(uci -q get "passwall2.${HG_VPN_MAIN_NODE}.remarks" 2>/dev/null || true)"
        fi

        case "$HG_VPN_MAIN_SOCKS_PORT" in
            ''|*[!0-9]*) port_valid='false' ;;
            *) port_valid='true' ;;
        esac

        if [ "$HG_VPN_PASSWALL_ENABLED" = 'false' ] || [ "$HG_VPN_MAIN_PROFILE_ENABLED" = 'false' ]; then
            HG_VPN_MAIN_CONFIG_STATE='DOWN'
        elif [ "$HG_VPN_PASSWALL_ENABLED" = 'true' ] && \
             [ "$profile_type" = 'socks' ] && \
             [ "$HG_VPN_MAIN_PROFILE_ENABLED" = 'true' ] && \
             [ -n "$HG_VPN_MAIN_NODE" ] && \
             [ "$port_valid" = 'true' ]; then
            HG_VPN_MAIN_CONFIG_STATE='OK'
        elif [ "$HG_VPN_PASSWALL_ENABLED" = 'true' ]; then
            HG_VPN_MAIN_CONFIG_STATE='DEGRADED'
        fi
    elif [ "$HG_VPN_PASSWALL_ENABLED" = 'false' ]; then
        HG_VPN_MAIN_CONFIG_STATE='DOWN'
    fi

    case "$HG_VPN_MAIN_CONFIG_STATE" in
        OK)
            if hg_vpn_main_process_running "$HG_VPN_MAIN_PROFILE"; then
                HG_VPN_MAIN_XRAY_STATE='OK'
            else
                HG_VPN_MAIN_XRAY_STATE='DOWN'
            fi
            ;;
        DOWN)
            HG_VPN_MAIN_XRAY_STATE='DOWN'
            ;;
    esac

    now="$(date '+%s' 2>/dev/null || true)"
    case "$now" in
        ''|*[!0-9]*) now='' ;;
    esac

    cache_checked_at=''
    cache_ipv4=''
    cache_provider=''
    if [ -r "$egress_cache_file" ]; then
        set -- $(awk 'NR == 1 { print $1, $2, $3; exit }' "$egress_cache_file" 2>/dev/null || true)
        cache_checked_at="${1:-}"
        cache_ipv4="${2:-}"
        cache_provider="${3:-}"

        case "$cache_checked_at" in
            ''|*[!0-9]*) cache_checked_at='' ;;
        esac
        if ! hg_vpn_is_ipv4 "$cache_ipv4"; then
            cache_ipv4=''
            cache_provider=''
        fi
    fi

    if [ "$HG_VPN_MAIN_XRAY_STATE" != 'OK' ]; then
        if [ -n "$cache_ipv4" ]; then
            HG_VPN_EGRESS_IPV4="$cache_ipv4"
            HG_VPN_EGRESS_SOURCE='stale_cache'
            HG_VPN_EGRESS_CHECKED_AT="$cache_checked_at"
            HG_VPN_EGRESS_PROVIDER="$cache_provider"
        fi
        if [ "$HG_VPN_MAIN_XRAY_STATE" = 'DOWN' ]; then
            HG_VPN_EGRESS_STATE='DOWN'
            HG_VPN_MAIN_STATE='DOWN'
        fi
        return 0
    fi

    if [ -n "$now" ] && [ -n "$cache_checked_at" ] && [ -n "$cache_ipv4" ]; then
        cache_age=$((now - cache_checked_at))
        if [ "$cache_age" -ge 0 ] && [ "$cache_age" -lt "$egress_cache_ttl" ]; then
            HG_VPN_EGRESS_STATE='OK'
            HG_VPN_EGRESS_IPV4="$cache_ipv4"
            HG_VPN_EGRESS_SOURCE='cache'
            HG_VPN_EGRESS_CHECKED_AT="$cache_checked_at"
            HG_VPN_EGRESS_PROVIDER="$cache_provider"
            HG_VPN_MAIN_STATE='OK'
            return 0
        fi
    fi

    HG_VPN_EGRESS_CHECKED_AT="$now"

    if command -v curl >/dev/null 2>&1 && [ -n "$HG_VPN_MAIN_SOCKS_PORT" ]; then
        HG_VPN_EGRESS_PROBE_ATTEMPTS='1'
        vpn_ipv4="$(
            curl -4 -fsS \
                --socks5-hostname "${HG_VPN_MAIN_SOCKS_HOST}:${HG_VPN_MAIN_SOCKS_PORT}" \
                --connect-timeout 2 \
                --max-time 6 \
                "$egress_probe_url" 2>/dev/null |
                awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
        )"

        if hg_vpn_is_ipv4 "$vpn_ipv4"; then
            HG_VPN_EGRESS_IPV4="$vpn_ipv4"
            HG_VPN_EGRESS_SOURCE='live_probe'
            HG_VPN_EGRESS_PROVIDER="$primary_provider"
            HG_VPN_EGRESS_STATE='OK'
            HG_VPN_MAIN_STATE='OK'

            if [ -n "$now" ]; then
                printf '%s %s %s\n' "$now" "$vpn_ipv4" "$primary_provider" >"$egress_cache_file" 2>/dev/null || true
            fi
            return 0
        fi

        if [ -n "$secondary_probe_url" ] && [ "$secondary_probe_url" != "$egress_probe_url" ]; then
            HG_VPN_EGRESS_PROBE_ATTEMPTS='2'
            vpn_ipv4="$(
                curl -4 -fsS \
                    --socks5-hostname "${HG_VPN_MAIN_SOCKS_HOST}:${HG_VPN_MAIN_SOCKS_PORT}" \
                    --connect-timeout 2 \
                    --max-time 6 \
                    "$secondary_probe_url" 2>/dev/null |
                    awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
            )"

            if hg_vpn_is_ipv4 "$vpn_ipv4"; then
                HG_VPN_EGRESS_IPV4="$vpn_ipv4"
                HG_VPN_EGRESS_SOURCE='live_probe'
                HG_VPN_EGRESS_PROVIDER="$secondary_provider"
                HG_VPN_EGRESS_STATE='OK'
                HG_VPN_MAIN_STATE='OK'

                if [ -n "$now" ]; then
                    printf '%s %s %s\n' "$now" "$vpn_ipv4" "$secondary_provider" >"$egress_cache_file" 2>/dev/null || true
                fi
                return 0
            fi
        fi
    fi

    if [ -n "$cache_ipv4" ]; then
        HG_VPN_EGRESS_IPV4="$cache_ipv4"
        HG_VPN_EGRESS_SOURCE='stale_cache'
        HG_VPN_EGRESS_CHECKED_AT="$cache_checked_at"
        HG_VPN_EGRESS_PROVIDER="$cache_provider"
    fi

    # Локальный Xray работает, но внешний путь не удалось подтвердить.
    HG_VPN_EGRESS_STATE='UNKNOWN'
    HG_VPN_MAIN_STATE='DEGRADED'
}
