#!/bin/sh
# Read-only статус Torrent SOCKS CUDY Home Gateway.

hg_torrent_is_ipv4() {
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

hg_torrent_process_running() {
    profile="$1"
    [ -n "$profile" ] || return 1

    config_path="/tmp/etc/passwall2/${profile}.json"
    ps w 2>/dev/null | awk -v config_path="$config_path" '
        index($0, "xray") && index($0, config_path) { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

hg_torrent_collect() {
    HG_TORRENT_STATE='UNKNOWN'
    HG_TORRENT_CONFIG_STATE='UNKNOWN'
    HG_TORRENT_PROFILE="${HG_TORRENT_PROFILE:-socks_hLPwH}"
    HG_TORRENT_PROFILE_ENABLED='unknown'
    HG_TORRENT_NODE=''
    HG_TORRENT_NAME=''
    HG_TORRENT_SOCKS_HOST="${HG_TORRENT_SOCKS_HOST:-127.0.0.1}"
    HG_TORRENT_SOCKS_PORT=''
    HG_TORRENT_XRAY_STATE='UNKNOWN'
    HG_TORRENT_AUTOSWITCH_ENABLED='unknown'
    HG_TORRENT_EGRESS_STATE='UNKNOWN'
    HG_TORRENT_EGRESS_IPV4=''
    HG_TORRENT_EGRESS_SOURCE='live_probe'
    HG_TORRENT_EGRESS_PROVIDER="${HG_TORRENT_EGRESS_PROVIDER:-api.ipify.org}"
    HG_TORRENT_EGRESS_CHECKED_AT=''

    egress_cache_file="${HG_TORRENT_EGRESS_CACHE_FILE:-/tmp/home-gateway-torrent-egress.cache}"
    egress_cache_ttl="${HG_TORRENT_EGRESS_CACHE_TTL:-300}"
    egress_probe_url="${HG_TORRENT_EGRESS_PROBE_URL:-https://api.ipify.org}"

    case "$egress_cache_ttl" in
        ''|*[!0-9]*) egress_cache_ttl=300 ;;
    esac

    if ! command -v uci >/dev/null 2>&1; then
        return 0
    fi

    profile_type="$(uci -q get "passwall2.${HG_TORRENT_PROFILE}" 2>/dev/null || true)"
    profile_enabled="$(uci -q get "passwall2.${HG_TORRENT_PROFILE}.enabled" 2>/dev/null || true)"
    HG_TORRENT_NODE="$(uci -q get "passwall2.${HG_TORRENT_PROFILE}.node" 2>/dev/null || true)"
    HG_TORRENT_SOCKS_PORT="$(uci -q get "passwall2.${HG_TORRENT_PROFILE}.port" 2>/dev/null || true)"
    autoswitch_enabled="$(uci -q get "passwall2.${HG_TORRENT_PROFILE}.enable_autoswitch" 2>/dev/null || true)"

    case "$profile_enabled" in
        1) HG_TORRENT_PROFILE_ENABLED='true' ;;
        0) HG_TORRENT_PROFILE_ENABLED='false' ;;
    esac
    case "$autoswitch_enabled" in
        1) HG_TORRENT_AUTOSWITCH_ENABLED='true' ;;
        0) HG_TORRENT_AUTOSWITCH_ENABLED='false' ;;
    esac

    if [ -n "$HG_TORRENT_NODE" ]; then
        HG_TORRENT_NAME="$(uci -q get "passwall2.${HG_TORRENT_NODE}.remarks" 2>/dev/null || true)"
    fi

    case "$HG_TORRENT_SOCKS_PORT" in
        ''|*[!0-9]*) port_valid='false' ;;
        *) port_valid='true' ;;
    esac

    if [ "$HG_TORRENT_PROFILE_ENABLED" = 'false' ]; then
        HG_TORRENT_CONFIG_STATE='DOWN'
    elif [ "$profile_type" = 'socks' ] && \
         [ "$HG_TORRENT_PROFILE_ENABLED" = 'true' ] && \
         [ -n "$HG_TORRENT_NODE" ] && \
         [ "$port_valid" = 'true' ]; then
        HG_TORRENT_CONFIG_STATE='OK'
    elif [ -n "$profile_type" ]; then
        HG_TORRENT_CONFIG_STATE='DEGRADED'
    fi

    case "$HG_TORRENT_CONFIG_STATE" in
        OK)
            if hg_torrent_process_running "$HG_TORRENT_PROFILE"; then
                HG_TORRENT_XRAY_STATE='OK'
            else
                HG_TORRENT_XRAY_STATE='DOWN'
            fi
            ;;
        DEGRADED)
            HG_TORRENT_STATE='DEGRADED'
            ;;
        DOWN)
            HG_TORRENT_XRAY_STATE='DOWN'
            HG_TORRENT_STATE='DOWN'
            ;;
    esac

    now="$(date '+%s' 2>/dev/null || true)"
    case "$now" in
        ''|*[!0-9]*) now='' ;;
    esac

    cache_checked_at=''
    cache_ipv4=''
    if [ -r "$egress_cache_file" ]; then
        set -- $(awk 'NR == 1 { print $1, $2; exit }' "$egress_cache_file" 2>/dev/null || true)
        cache_checked_at="${1:-}"
        cache_ipv4="${2:-}"

        case "$cache_checked_at" in
            ''|*[!0-9]*) cache_checked_at='' ;;
        esac
        if ! hg_torrent_is_ipv4 "$cache_ipv4"; then
            cache_ipv4=''
        fi
    fi

    if [ "$HG_TORRENT_XRAY_STATE" != 'OK' ]; then
        if [ -n "$cache_ipv4" ]; then
            HG_TORRENT_EGRESS_IPV4="$cache_ipv4"
            HG_TORRENT_EGRESS_SOURCE='stale_cache'
            HG_TORRENT_EGRESS_CHECKED_AT="$cache_checked_at"
        fi
        if [ "$HG_TORRENT_XRAY_STATE" = 'DOWN' ]; then
            HG_TORRENT_EGRESS_STATE='DOWN'
            HG_TORRENT_STATE='DOWN'
        fi
        return 0
    fi

    if [ -n "$now" ] && [ -n "$cache_checked_at" ] && [ -n "$cache_ipv4" ]; then
        cache_age=$((now - cache_checked_at))
        if [ "$cache_age" -ge 0 ] && [ "$cache_age" -lt "$egress_cache_ttl" ]; then
            HG_TORRENT_EGRESS_STATE='OK'
            HG_TORRENT_EGRESS_IPV4="$cache_ipv4"
            HG_TORRENT_EGRESS_SOURCE='cache'
            HG_TORRENT_EGRESS_CHECKED_AT="$cache_checked_at"
            HG_TORRENT_STATE='OK'
            return 0
        fi
    fi

    HG_TORRENT_EGRESS_CHECKED_AT="$now"

    if command -v curl >/dev/null 2>&1 && [ -n "$HG_TORRENT_SOCKS_PORT" ]; then
        torrent_ipv4="$(
            curl -4 -fsS \
                --socks5-hostname "${HG_TORRENT_SOCKS_HOST}:${HG_TORRENT_SOCKS_PORT}" \
                --connect-timeout 2 \
                --max-time 6 \
                "$egress_probe_url" 2>/dev/null |
                awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
        )"

        if hg_torrent_is_ipv4 "$torrent_ipv4"; then
            HG_TORRENT_EGRESS_IPV4="$torrent_ipv4"
            HG_TORRENT_EGRESS_SOURCE='live_probe'
            HG_TORRENT_EGRESS_STATE='OK'
            HG_TORRENT_STATE='OK'

            if [ -n "$now" ]; then
                printf '%s %s\n' "$now" "$torrent_ipv4" >"$egress_cache_file" 2>/dev/null || true
            fi
            return 0
        fi
    fi

    if [ -n "$cache_ipv4" ]; then
        HG_TORRENT_EGRESS_IPV4="$cache_ipv4"
        HG_TORRENT_EGRESS_SOURCE='stale_cache'
        HG_TORRENT_EGRESS_CHECKED_AT="$cache_checked_at"
    fi

    # Локальный Xray работает, но внешний Torrent egress сейчас не подтверждён.
    HG_TORRENT_EGRESS_STATE='UNKNOWN'
    HG_TORRENT_STATE='DEGRADED'
}
