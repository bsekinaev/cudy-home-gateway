#!/bin/sh
# Read-only сетевые данные CUDY Home Gateway.

hg_network_is_ipv4() {
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

hg_network_is_cgnat() {
    value="$1"

    hg_network_is_ipv4 "$value" || return 1

    printf '%s\n' "$value" | awk -F. '
        $1 == 100 && $2 >= 64 && $2 <= 127 { exit 0 }
        { exit 1 }
    '
}

hg_network_collect() {
    HG_NETWORK_WAN_INTERFACE="${HG_WAN_INTERFACE:-wan}"
    HG_NETWORK_WAN_STATE='UNKNOWN'
    HG_NETWORK_WAN_DEVICE=''
    HG_NETWORK_WAN_PROTO=''
    HG_NETWORK_WAN_IPV4=''
    HG_NETWORK_WAN_PREFIX=''
    HG_NETWORK_WAN_GATEWAY=''
    HG_NETWORK_WAN_CGNAT='unknown'
    HG_NETWORK_DIRECT_STATE='UNKNOWN'
    HG_NETWORK_DIRECT_IPV4=''
    HG_NETWORK_DIRECT_SOURCE='live_probe'
    primary_provider="${HG_EGRESS_PROVIDER:-api.ipify.org}"
    secondary_provider="${HG_EGRESS_SECONDARY_PROVIDER:-ipv4.icanhazip.com}"
    HG_NETWORK_DIRECT_PROVIDER=''
    HG_NETWORK_DIRECT_CHECKED_AT=''
    HG_NETWORK_DIRECT_PROBE_ATTEMPTS='0'

    egress_cache_file="${HG_EGRESS_CACHE_FILE:-/tmp/home-gateway-direct-egress.cache}"
    egress_cache_ttl="${HG_EGRESS_CACHE_TTL:-300}"
    egress_probe_url="${HG_EGRESS_PROBE_URL:-https://api.ipify.org}"
    secondary_probe_url="${HG_EGRESS_SECONDARY_PROBE_URL:-https://ipv4.icanhazip.com/}"

    case "$egress_cache_ttl" in
        ''|*[!0-9]*) egress_cache_ttl=300 ;;
    esac

    wan_status=''
    wan_up=''

    if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        wan_status="$(ubus call "network.interface.${HG_NETWORK_WAN_INTERFACE}" status 2>/dev/null || true)"
        if [ -n "$wan_status" ]; then
            wan_up="$(printf '%s\n' "$wan_status" | jsonfilter -e '@.up' 2>/dev/null || true)"
            HG_NETWORK_WAN_DEVICE="$(printf '%s\n' "$wan_status" | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
            HG_NETWORK_WAN_PROTO="$(printf '%s\n' "$wan_status" | jsonfilter -e '@.proto' 2>/dev/null || true)"
        fi
    fi

    if [ -z "$HG_NETWORK_WAN_DEVICE" ] && command -v uci >/dev/null 2>&1; then
        HG_NETWORK_WAN_DEVICE="$(uci -q get "network.${HG_NETWORK_WAN_INTERFACE}.device" 2>/dev/null || true)"
    fi
    if [ -z "$HG_NETWORK_WAN_PROTO" ] && command -v uci >/dev/null 2>&1; then
        HG_NETWORK_WAN_PROTO="$(uci -q get "network.${HG_NETWORK_WAN_INTERFACE}.proto" 2>/dev/null || true)"
    fi

    if [ -n "$HG_NETWORK_WAN_DEVICE" ] && command -v ip >/dev/null 2>&1; then
        wan_cidr="$(ip -4 addr show dev "$HG_NETWORK_WAN_DEVICE" scope global 2>/dev/null | awk '/inet / { print $2; exit }')"
        case "$wan_cidr" in
            */*)
                HG_NETWORK_WAN_IPV4="${wan_cidr%/*}"
                HG_NETWORK_WAN_PREFIX="${wan_cidr#*/}"
                ;;
        esac

        HG_NETWORK_WAN_GATEWAY="$(
            ip -4 route show default dev "$HG_NETWORK_WAN_DEVICE" 2>/dev/null |
                awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }'
        )"
    fi

    case "$wan_up" in
        true)
            if [ -n "$HG_NETWORK_WAN_DEVICE" ] && \
               hg_network_is_ipv4 "$HG_NETWORK_WAN_IPV4" && \
               hg_network_is_ipv4 "$HG_NETWORK_WAN_GATEWAY"; then
                HG_NETWORK_WAN_STATE='OK'
            else
                HG_NETWORK_WAN_STATE='DEGRADED'
            fi
            ;;
        false)
            HG_NETWORK_WAN_STATE='DOWN'
            ;;
        *)
            HG_NETWORK_WAN_STATE='UNKNOWN'
            ;;
    esac

    if hg_network_is_ipv4 "$HG_NETWORK_WAN_IPV4"; then
        if hg_network_is_cgnat "$HG_NETWORK_WAN_IPV4"; then
            HG_NETWORK_WAN_CGNAT='true'
        else
            HG_NETWORK_WAN_CGNAT='false'
        fi
    fi

    if [ "$HG_NETWORK_WAN_STATE" = 'DOWN' ]; then
        HG_NETWORK_DIRECT_STATE='DOWN'
        return 0
    fi

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
        if ! hg_network_is_ipv4 "$cache_ipv4"; then
            cache_ipv4=''
            cache_provider=''
        fi
    fi

    if [ -n "$now" ] && [ -n "$cache_checked_at" ] && [ -n "$cache_ipv4" ]; then
        cache_age=$((now - cache_checked_at))
        if [ "$cache_age" -ge 0 ] && [ "$cache_age" -lt "$egress_cache_ttl" ]; then
            HG_NETWORK_DIRECT_STATE='OK'
            HG_NETWORK_DIRECT_IPV4="$cache_ipv4"
            HG_NETWORK_DIRECT_SOURCE='cache'
            HG_NETWORK_DIRECT_CHECKED_AT="$cache_checked_at"
            HG_NETWORK_DIRECT_PROVIDER="$cache_provider"
            return 0
        fi
    fi

    HG_NETWORK_DIRECT_CHECKED_AT="$now"

    if [ -n "$HG_NETWORK_WAN_DEVICE" ] && command -v curl >/dev/null 2>&1; then
        HG_NETWORK_DIRECT_PROBE_ATTEMPTS='1'
        probe_ipv4="$(
            curl -4 -fsS \
                --interface "$HG_NETWORK_WAN_DEVICE" \
                --connect-timeout 2 \
                --max-time 4 \
                "$egress_probe_url" 2>/dev/null |
                awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
        )"

        if hg_network_is_ipv4 "$probe_ipv4"; then
            HG_NETWORK_DIRECT_IPV4="$probe_ipv4"
            HG_NETWORK_DIRECT_SOURCE='live_probe'
            HG_NETWORK_DIRECT_PROVIDER="$primary_provider"
            HG_NETWORK_DIRECT_STATE='OK'

            if [ -n "$now" ]; then
                printf '%s %s %s\n' "$now" "$probe_ipv4" "$primary_provider" >"$egress_cache_file" 2>/dev/null || true
            fi
            return 0
        fi

        if [ -n "$secondary_probe_url" ] && [ "$secondary_probe_url" != "$egress_probe_url" ]; then
            HG_NETWORK_DIRECT_PROBE_ATTEMPTS='2'
            probe_ipv4="$(
                curl -4 -fsS \
                    --interface "$HG_NETWORK_WAN_DEVICE" \
                    --connect-timeout 2 \
                    --max-time 4 \
                    "$secondary_probe_url" 2>/dev/null |
                    awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
            )"

            if hg_network_is_ipv4 "$probe_ipv4"; then
                HG_NETWORK_DIRECT_IPV4="$probe_ipv4"
                HG_NETWORK_DIRECT_SOURCE='live_probe'
                HG_NETWORK_DIRECT_PROVIDER="$secondary_provider"
                HG_NETWORK_DIRECT_STATE='OK'

                if [ -n "$now" ]; then
                    printf '%s %s %s\n' "$now" "$probe_ipv4" "$secondary_provider" >"$egress_cache_file" 2>/dev/null || true
                fi
                return 0
            fi
        fi
    fi

    # При ошибке внешнего probe не выдаём старое значение за актуальное.
    # Сохраняем его только как stale-данные со статусом UNKNOWN.
    if [ -n "$cache_ipv4" ]; then
        HG_NETWORK_DIRECT_IPV4="$cache_ipv4"
        HG_NETWORK_DIRECT_SOURCE='stale_cache'
        HG_NETWORK_DIRECT_CHECKED_AT="$cache_checked_at"
        HG_NETWORK_DIRECT_PROVIDER="$cache_provider"
    fi
}
