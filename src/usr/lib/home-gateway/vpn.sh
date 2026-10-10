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

# Stage 0.8 read-only planning boundary. This is not a candidate network preflight.
# The private PassWall helper contract and writer coordination must be audited
# before any MAIN mutation can be implemented. No UCI set/commit or restart here.
hg_main_transaction_plan() (
    candidate="$1"
    case "$candidate" in ''|*[!a-zA-Z0-9_]* )
        printf '{"schema_version":1,"status":"INVALID_CANDIDATE","apply_supported":false}\n'
        exit 2 ;;
    esac
    [ "${#candidate}" -le 64 ] || {
        printf '{"schema_version":1,"status":"INVALID_CANDIDATE","apply_supported":false}\n'
        exit 2
    }
    set -o pipefail
    hg_main_plan_blocked() {
        printf '{"schema_version":1,"status":"%s","apply_supported":false,"preflight_passed":false,"snapshot_ready":false}\n' "$1"
        exit 70
    }
    # Each observation is bounded and private; neither config nor node IDs are
    # returned. Independent reads are explicitly not a transaction snapshot.
    hg_main_plan_get() {
        # Sentinel preserves LF bytes across command substitution so truncation
        # cannot turn an oversized multiline value into a valid short scalar.
        value="$(timeout -k 1 5 uci -q get "$1" 2>/dev/null | head -c 66
            read_rc="$?"
            [ "$read_rc" -eq 0 ] || exit 1
            printf '.')" || return 1
        value="${value%?}"
        [ "${#value}" -le 65 ] || return 1
        newline="$(printf '\n.')"; newline="${newline%.}"
        case "$value" in *"$newline") value="${value%"$newline"}" ;; *) return 1 ;; esac
        case "$value" in *"$newline"*) return 1 ;; esac
        printf '%s' "$value"
    }
    command -v uci >/dev/null 2>&1 || hg_main_plan_blocked UCI_UNAVAILABLE
    pending="$(timeout -k 1 5 uci -q changes passwall2 2>/dev/null | head -c 65)" || hg_main_plan_blocked UCI_READ_FAILED
    [ -z "$pending" ] || hg_main_plan_blocked UNCOMMITTED_CONFIG
    enabled="$(hg_main_plan_get 'passwall2.@global[0].enabled')" || hg_main_plan_blocked UCI_READ_FAILED
    profile="$(hg_main_plan_get passwall2.rulenode.default_node)" || hg_main_plan_blocked UCI_READ_FAILED
    [ "$enabled" = 1 ] && [ "$profile" = socks_P8ART ] || hg_main_plan_blocked UNSUPPORTED_MAIN_PROFILE
    profile_type="$(hg_main_plan_get passwall2.socks_P8ART)" || hg_main_plan_blocked UCI_READ_FAILED
    active="$(hg_main_plan_get passwall2.socks_P8ART.enabled)" || hg_main_plan_blocked UCI_READ_FAILED
    port="$(hg_main_plan_get passwall2.socks_P8ART.port)" || hg_main_plan_blocked UCI_READ_FAILED
    [ "$profile_type" = socks ] && [ "$active" = 1 ] && [ "$port" = 1082 ] || hg_main_plan_blocked UNSUPPORTED_MAIN_PROFILE
    autoswitch="$(hg_main_plan_get passwall2.socks_P8ART.enable_autoswitch)" || hg_main_plan_blocked UCI_READ_FAILED
    [ "$autoswitch" = 0 ] || hg_main_plan_blocked AUTOSWITCH_REQUIRES_OWNER
    current="$(hg_main_plan_get passwall2.socks_P8ART.node)" || hg_main_plan_blocked UCI_READ_FAILED
    case "$current" in ''|*[!a-zA-Z0-9_]* ) hg_main_plan_blocked INVALID_CURRENT_NODE ;; esac
    candidate_type="$(hg_main_plan_get "passwall2.$candidate")" || hg_main_plan_blocked CANDIDATE_UNAVAILABLE
    [ "$candidate_type" = nodes ] || hg_main_plan_blocked INVALID_CANDIDATE_TYPE
    # Re-observe pending edits; still no claim of generation-consistent reads.
    pending="$(timeout -k 1 5 uci -q changes passwall2 2>/dev/null | head -c 65)" || hg_main_plan_blocked UCI_READ_FAILED
    [ -z "$pending" ] || hg_main_plan_blocked UNCOMMITTED_CONFIG
    same=false
    [ "$candidate" != "$current" ] || same=true
    printf '{"schema_version":1,"status":"PREFLIGHT_ADAPTER_REQUIRED","candidate_exists":true,"same_as_configured_main":%s,"observation_only":true,"apply_supported":false,"preflight_passed":false,"snapshot_ready":false,"blockers":["AUDITED_PASSWALL_HELPERS","WRITER_COORDINATION","LAN_TAILSCALE_RECOVERY","TRANSACTION_SNAPSHOT_JOURNAL"]}\n' "$same"
    exit 70
)
