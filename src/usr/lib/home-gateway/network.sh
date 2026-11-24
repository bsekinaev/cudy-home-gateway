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
    HG_NETWORK_WAN_ROUTE_STATE='UNKNOWN'
    HG_NETWORK_PATH_CONTEXT=''
    HG_NETWORK_WAN_CGNAT='unknown'
    HG_NETWORK_DIRECT_STATE='UNKNOWN'
    HG_NETWORK_DIRECT_IPV4=''
    HG_NETWORK_DIRECT_SOURCE='live_probe'
    primary_provider="${HG_EGRESS_PROVIDER:-api.ipify.org}"
    secondary_provider="${HG_EGRESS_SECONDARY_PROVIDER:-ipv4.icanhazip.com}"
    HG_NETWORK_DIRECT_PROVIDER=''
    HG_NETWORK_DIRECT_CHECKED_AT=''
    HG_NETWORK_DIRECT_PROBE_ATTEMPTS='0'

    probe_timeout=4
    [ "${HG_MONITOR_ACTIVE:-0}" != 1 ] || probe_timeout=3
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

        # iproute2 may omit the device name when it is used as a filter.
        # Accept a single attributable, usable main-table default route.
        wan_routes="$(ip -4 route show default 2>/dev/null)" || wan_routes=''
        wan_route="$(printf '%s\n' "$wan_routes" | awk -v device="$HG_NETWORK_WAN_DEVICE" '
            $1=="default" || $1=="0.0.0.0/0" {
                dev=""; bad=0
                for(i=1;i<=NF;i++) {
                    if($i=="dev")dev=$(i+1)
                    if($i=="linkdown" || $i=="dead" || $i=="nexthop")bad=1
                }
                if(dev==device && !bad){count++;line=$0}
            }
            END {if(count==1)print line}
        ')"
        if [ -n "$wan_route" ]; then
            HG_NETWORK_WAN_GATEWAY="$(printf '%s\n' "$wan_route" | awk '{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
            if hg_network_is_ipv4 "$HG_NETWORK_WAN_GATEWAY" || \
                { [ "$HG_NETWORK_WAN_PROTO" = pppoe ] && [ -z "$HG_NETWORK_WAN_GATEWAY" ] && ! printf '%s\n' "$wan_route" | grep -qw via; }; then
                HG_NETWORK_WAN_ROUTE_STATE='PRESENT'
            fi
        fi
    fi

    case "$wan_up" in
        true)
            if [ -n "$HG_NETWORK_WAN_DEVICE" ] && \
               hg_network_is_ipv4 "$HG_NETWORK_WAN_IPV4" && \
               [ "$HG_NETWORK_WAN_ROUTE_STATE" = PRESENT ] && \
               case "$HG_NETWORK_WAN_PROTO" in dhcp|static|pppoe) true;; *) false;; esac; then
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
    # A cached or live probe cannot certify an incomplete local WAN path.
    [ "$HG_NETWORK_WAN_STATE" = OK ] || return 0

    wan_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    wan_context=''
    if [ -n "$wan_boot" ] && command -v sha256sum >/dev/null 2>&1; then
        HG_NETWORK_PATH_CONTEXT="$(printf '%s\n' "$wan_boot" "$HG_NETWORK_WAN_INTERFACE" "$HG_NETWORK_WAN_DEVICE" "$HG_NETWORK_WAN_PROTO" "$HG_NETWORK_WAN_IPV4" "$HG_NETWORK_WAN_PREFIX" "$wan_route" | sha256sum | awk '{print $1}')"
        if [ "${#HG_NETWORK_PATH_CONTEXT}" = 64 ]; then
            wan_context="$(printf '%s\n' "$HG_NETWORK_PATH_CONTEXT" "$egress_probe_url" "$secondary_probe_url" "$primary_provider" "$secondary_provider" | sha256sum | awk '{print $1}')"
        fi
    fi

    now="$(date '+%s' 2>/dev/null || true)"
    case "$now" in
        ''|*[!0-9]*) now='' ;;
    esac

    cache_checked_at=''
    cache_ipv4=''
    cache_provider=''
    if [ -r "$egress_cache_file" ]; then
        set -- $(awk 'NR == 1 && NF == 4 { print $1, $2, $3, $4; exit }' "$egress_cache_file" 2>/dev/null || true)
        cache_checked_at="${1:-}"
        cache_ipv4="${2:-}"
        cache_provider="${3:-}"

        case "$cache_checked_at" in
            ''|*[!0-9]*) cache_checked_at='' ;;
        esac
        if [ -z "$wan_context" ] || [ "${4:-}" != "$wan_context" ] || ! hg_network_is_ipv4 "$cache_ipv4"; then
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
                --max-time "$probe_timeout" \
                "$egress_probe_url" 2>/dev/null |
                awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
        )"

        if hg_network_is_ipv4 "$probe_ipv4"; then
            HG_NETWORK_DIRECT_IPV4="$probe_ipv4"
            HG_NETWORK_DIRECT_SOURCE='live_probe'
            HG_NETWORK_DIRECT_PROVIDER="$primary_provider"
            HG_NETWORK_DIRECT_STATE='OK'

            if [ -n "$now" ] && [ -n "$wan_context" ]; then
                printf '%s %s %s %s\n' "$now" "$probe_ipv4" "$primary_provider" "$wan_context" >"$egress_cache_file" 2>/dev/null || true
            fi
            return 0
        fi

        if [ -n "$secondary_probe_url" ] && [ "$secondary_probe_url" != "$egress_probe_url" ]; then
            HG_NETWORK_DIRECT_PROBE_ATTEMPTS='2'
            probe_ipv4="$(
                curl -4 -fsS \
                    --interface "$HG_NETWORK_WAN_DEVICE" \
                    --connect-timeout 2 \
                    --max-time "$probe_timeout" \
                    "$secondary_probe_url" 2>/dev/null |
                    awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
            )"

            if hg_network_is_ipv4 "$probe_ipv4"; then
                HG_NETWORK_DIRECT_IPV4="$probe_ipv4"
                HG_NETWORK_DIRECT_SOURCE='live_probe'
                HG_NETWORK_DIRECT_PROVIDER="$secondary_provider"
                HG_NETWORK_DIRECT_STATE='OK'

                if [ -n "$now" ] && [ -n "$wan_context" ]; then
                    printf '%s %s %s %s\n' "$now" "$probe_ipv4" "$secondary_provider" "$wan_context" >"$egress_cache_file" 2>/dev/null || true
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
