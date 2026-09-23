#!/bin/sh
# Read-only Health Core CUDY Home Gateway.
# Нормализует уже существующие status observations и не изменяет data plane.

hg_health_state_valid() {
    case "${1:-}" in
        OK|DEGRADED|DOWN|UNKNOWN|MAINTENANCE) return 0 ;;
        *) return 1 ;;
    esac
}

hg_health_normalize_state() {
    value="${1:-UNKNOWN}"

    if hg_health_state_valid "$value"; then
        printf '%s' "$value"
    else
        printf 'UNKNOWN'
    fi
}

hg_health_age_seconds() {
    checked_at="${1:-}"
    now="${HG_HEALTH_GENERATED_EPOCH:-}"

    case "$checked_at:$now" in
        *[!0-9:]*|:*|*:) return 0 ;;
    esac

    if [ "$now" -ge "$checked_at" ]; then
        printf '%s' "$((now - checked_at))"
    fi
}

hg_health_freshness() {
    source="${1:-}"
    checked_at="${2:-}"
    age="$(hg_health_age_seconds "$checked_at")"

    case "$source" in
        live_probe)
            [ -n "$age" ] && printf 'live' || printf 'unknown'
            ;;
        cache)
            [ -n "$age" ] && printf 'cached' || printf 'unknown'
            ;;
        stale_cache)
            printf 'stale'
            ;;
        *)
            printf 'unknown'
            ;;
    esac
}

hg_health_reason_wan() {
    case "$HG_HEALTH_WAN_STATE" in
        OK) printf 'wan_ready' ;;
        DOWN) printf 'wan_down' ;;
        DEGRADED) printf 'wan_incomplete' ;;
        MAINTENANCE) printf 'wan_maintenance' ;;
        *) printf 'wan_unknown' ;;
    esac
}

hg_health_reason_dns() {
    if [ "${HG_DNS_DNSMASQ_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'dnsmasq_down'
    elif [ "${HG_DNS_RESOLUTION_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'dns_resolution_failed'
    else
        case "$HG_HEALTH_DNS_STATE" in
            OK) printf 'dns_ready' ;;
            DEGRADED) printf 'dns_degraded' ;;
            DOWN) printf 'dns_down' ;;
            MAINTENANCE) printf 'dns_maintenance' ;;
            *) printf 'dns_unknown' ;;
        esac
    fi
}

hg_health_reason_main() {
    if [ "${HG_VPN_MAIN_CONFIG_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'main_config_down'
    elif [ "${HG_VPN_MAIN_XRAY_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'main_xray_down'
    elif [ "${HG_VPN_EGRESS_STATE:-UNKNOWN}" = 'UNKNOWN' ]; then
        printf 'main_egress_unconfirmed'
    else
        case "$HG_HEALTH_MAIN_STATE" in
            OK) printf 'main_ready' ;;
            DEGRADED) printf 'main_degraded' ;;
            DOWN) printf 'main_down' ;;
            MAINTENANCE) printf 'main_maintenance' ;;
            *) printf 'main_unknown' ;;
        esac
    fi
}

hg_health_reason_torrent() {
    if [ "${HG_TORRENT_CONFIG_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'torrent_config_down'
    elif [ "${HG_TORRENT_XRAY_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'torrent_xray_down'
    elif [ "${HG_TORRENT_EGRESS_STATE:-UNKNOWN}" = 'UNKNOWN' ]; then
        printf 'torrent_egress_unconfirmed'
    else
        case "$HG_HEALTH_TORRENT_STATE" in
            OK) printf 'torrent_ready' ;;
            DEGRADED) printf 'torrent_degraded' ;;
            DOWN) printf 'torrent_down' ;;
            MAINTENANCE) printf 'torrent_maintenance' ;;
            *) printf 'torrent_unknown' ;;
        esac
    fi
}

hg_health_reason_redmi() {
    if [ "${HG_REDMI_KILLSWITCH_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'redmi_kill_switch_down'
    elif [ "${HG_REDMI_POLICY_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'redmi_policy_down'
    elif [ "${HG_REDMI_XRAY_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'redmi_xray_down'
    else
        case "$HG_HEALTH_REDMI_STATE" in
            OK) printf 'redmi_ready' ;;
            DEGRADED) printf 'redmi_degraded' ;;
            DOWN) printf 'redmi_down' ;;
            MAINTENANCE) printf 'redmi_maintenance' ;;
            *) printf 'redmi_unknown' ;;
        esac
    fi
}

hg_health_reason_asata() {
    if [ "${HG_ASATA_IDENTITY_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'asata_identity_mismatch'
    elif [ "${HG_ASATA_RULE_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'asata_udp_direct_down'
    elif [ "${HG_ASATA_KEEPER_STATE:-UNKNOWN}" != 'OK' ]; then
        printf 'asata_keeper_unhealthy'
    else
        case "$HG_HEALTH_ASATA_STATE" in
            OK) printf 'asata_ready' ;;
            DEGRADED) printf 'asata_degraded' ;;
            DOWN) printf 'asata_down' ;;
            MAINTENANCE) printf 'asata_maintenance' ;;
            *) printf 'asata_unknown' ;;
        esac
    fi
}

hg_health_reason_tailscale() {
    case "$HG_HEALTH_TAILSCALE_STATE" in
        OK) printf 'tailscale_ready' ;;
        DEGRADED) printf 'tailscale_degraded' ;;
        DOWN) printf 'tailscale_down' ;;
        MAINTENANCE) printf 'tailscale_maintenance' ;;
        *) printf 'tailscale_unknown' ;;
    esac
}

hg_health_count_state() {
    state="$1"

    case "$state" in
        OK) HG_HEALTH_COUNT_OK=$((HG_HEALTH_COUNT_OK + 1)) ;;
        DEGRADED) HG_HEALTH_COUNT_DEGRADED=$((HG_HEALTH_COUNT_DEGRADED + 1)) ;;
        DOWN) HG_HEALTH_COUNT_DOWN=$((HG_HEALTH_COUNT_DOWN + 1)) ;;
        UNKNOWN) HG_HEALTH_COUNT_UNKNOWN=$((HG_HEALTH_COUNT_UNKNOWN + 1)) ;;
        MAINTENANCE) HG_HEALTH_COUNT_MAINTENANCE=$((HG_HEALTH_COUNT_MAINTENANCE + 1)) ;;
    esac
}

hg_health_collect() {
    if ! command -v hg_status_collect >/dev/null 2>&1; then
        hg_load_module status >/dev/null 2>&1 || return "$HG_EXIT_SOFTWARE"
    fi

    hg_status_collect

    # Берём "now" после hg_status_collect: внешние probes выполняются внутри
    # status collect и их checked_at может быть позже HG_STATUS_TIME_EPOCH.
    HG_HEALTH_GENERATED_EPOCH="$(date '+%s' 2>/dev/null || true)"
    case "$HG_HEALTH_GENERATED_EPOCH" in
        ''|*[!0-9]*) HG_HEALTH_GENERATED_EPOCH="${HG_STATUS_TIME_EPOCH:-}" ;;
    esac

    HG_HEALTH_WAN_STATE="$(hg_health_normalize_state "${HG_NETWORK_WAN_STATE:-UNKNOWN}")"
    HG_HEALTH_DNS_STATE="$(hg_health_normalize_state "${HG_DNS_STATE:-UNKNOWN}")"
    HG_HEALTH_MAIN_STATE="$(hg_health_normalize_state "${HG_VPN_MAIN_STATE:-UNKNOWN}")"
    HG_HEALTH_TORRENT_STATE="$(hg_health_normalize_state "${HG_TORRENT_STATE:-UNKNOWN}")"
    HG_HEALTH_REDMI_STATE="$(hg_health_normalize_state "${HG_REDMI_STATE:-UNKNOWN}")"
    HG_HEALTH_ASATA_STATE="$(hg_health_normalize_state "${HG_ASATA_STATE:-UNKNOWN}")"
    HG_HEALTH_TAILSCALE_STATE="$(hg_health_normalize_state "${HG_TAILSCALE_STATE:-UNKNOWN}")"

    HG_HEALTH_DIRECT_EGRESS_STATE="$(hg_health_normalize_state "${HG_NETWORK_DIRECT_STATE:-UNKNOWN}")"
    HG_HEALTH_MAIN_EGRESS_STATE="$(hg_health_normalize_state "${HG_VPN_EGRESS_STATE:-UNKNOWN}")"
    HG_HEALTH_TORRENT_EGRESS_STATE="$(hg_health_normalize_state "${HG_TORRENT_EGRESS_STATE:-UNKNOWN}")"

    HG_HEALTH_DIRECT_EGRESS_AGE="$(hg_health_age_seconds "${HG_NETWORK_DIRECT_CHECKED_AT:-}")"
    HG_HEALTH_MAIN_EGRESS_AGE="$(hg_health_age_seconds "${HG_VPN_EGRESS_CHECKED_AT:-}")"
    HG_HEALTH_TORRENT_EGRESS_AGE="$(hg_health_age_seconds "${HG_TORRENT_EGRESS_CHECKED_AT:-}")"

    HG_HEALTH_DIRECT_EGRESS_FRESHNESS="$(hg_health_freshness "${HG_NETWORK_DIRECT_SOURCE:-}" "${HG_NETWORK_DIRECT_CHECKED_AT:-}")"
    HG_HEALTH_MAIN_EGRESS_FRESHNESS="$(hg_health_freshness "${HG_VPN_EGRESS_SOURCE:-}" "${HG_VPN_EGRESS_CHECKED_AT:-}")"
    HG_HEALTH_TORRENT_EGRESS_FRESHNESS="$(hg_health_freshness "${HG_TORRENT_EGRESS_SOURCE:-}" "${HG_TORRENT_EGRESS_CHECKED_AT:-}")"

    HG_HEALTH_DIRECT_EGRESS_ATTEMPTS="${HG_NETWORK_DIRECT_PROBE_ATTEMPTS:-0}"
    HG_HEALTH_MAIN_EGRESS_ATTEMPTS="${HG_VPN_EGRESS_PROBE_ATTEMPTS:-0}"
    HG_HEALTH_TORRENT_EGRESS_ATTEMPTS="${HG_TORRENT_EGRESS_PROBE_ATTEMPTS:-0}"

    HG_HEALTH_WAN_REASON="$(hg_health_reason_wan)"
    HG_HEALTH_DNS_REASON="$(hg_health_reason_dns)"
    HG_HEALTH_MAIN_REASON="$(hg_health_reason_main)"
    HG_HEALTH_TORRENT_REASON="$(hg_health_reason_torrent)"
    HG_HEALTH_REDMI_REASON="$(hg_health_reason_redmi)"
    HG_HEALTH_ASATA_REASON="$(hg_health_reason_asata)"
    HG_HEALTH_TAILSCALE_REASON="$(hg_health_reason_tailscale)"

    HG_HEALTH_COUNT_OK=0
    HG_HEALTH_COUNT_DEGRADED=0
    HG_HEALTH_COUNT_DOWN=0
    HG_HEALTH_COUNT_UNKNOWN=0
    HG_HEALTH_COUNT_MAINTENANCE=0

    for state in \
        "$HG_HEALTH_WAN_STATE" \
        "$HG_HEALTH_DNS_STATE" \
        "$HG_HEALTH_MAIN_STATE" \
        "$HG_HEALTH_TORRENT_STATE" \
        "$HG_HEALTH_REDMI_STATE" \
        "$HG_HEALTH_ASATA_STATE" \
        "$HG_HEALTH_TAILSCALE_STATE"; do
        hg_health_count_state "$state"
    done

    HG_HEALTH_OVERALL_STATE='OK'

    for state in "$HG_HEALTH_WAN_STATE" "$HG_HEALTH_DNS_STATE" "$HG_HEALTH_MAIN_STATE"; do
        case "$state" in
            DOWN)
                HG_HEALTH_OVERALL_STATE='DOWN'
                break
                ;;
            DEGRADED)
                [ "$HG_HEALTH_OVERALL_STATE" = 'OK' ] && HG_HEALTH_OVERALL_STATE='DEGRADED'
                ;;
            UNKNOWN)
                [ "$HG_HEALTH_OVERALL_STATE" = 'OK' ] && HG_HEALTH_OVERALL_STATE='UNKNOWN'
                ;;
            MAINTENANCE)
                [ "$HG_HEALTH_OVERALL_STATE" = 'OK' ] && HG_HEALTH_OVERALL_STATE='MAINTENANCE'
                ;;
        esac
    done

    if [ "$HG_HEALTH_OVERALL_STATE" != 'DOWN' ]; then
        for state in \
            "$HG_HEALTH_TORRENT_STATE" \
            "$HG_HEALTH_REDMI_STATE" \
            "$HG_HEALTH_ASATA_STATE" \
            "$HG_HEALTH_TAILSCALE_STATE"; do
            case "$state" in
                DOWN|DEGRADED)
                    if [ "$HG_HEALTH_OVERALL_STATE" = 'OK' ] ||
                       [ "$HG_HEALTH_OVERALL_STATE" = 'MAINTENANCE' ]; then
                        HG_HEALTH_OVERALL_STATE='DEGRADED'
                    fi
                    ;;
            esac
        done
    fi

    HG_HEALTH_ATTENTION_COUNT=$((HG_HEALTH_COUNT_DEGRADED + HG_HEALTH_COUNT_DOWN + HG_HEALTH_COUNT_UNKNOWN))

    return 0
}

hg_health_print_evidence() {
    label="$1"
    state="$2"
    source="$3"
    freshness="$4"
    age="$5"
    attempts="$6"
    provider="$7"

    age_label='n/a'
    [ -n "$age" ] && age_label="${age}s"

    printf '  %-16s %-11s source=%-11s freshness=%-7s age=%-6s attempts=%s provider=%s\n' \
        "$label" "$state" "${source:-unknown}" "$freshness" "$age_label" "${attempts:-0}" "${provider:-unknown}"
}

hg_health_print() {
    hg_health_collect || return $?

    printf '%s — health\n\n' "$HG_NAME"
    printf 'Overall: %s\n' "$HG_HEALTH_OVERALL_STATE"
    printf 'Attention: %s\n\n' "$HG_HEALTH_ATTENTION_COUNT"

    printf 'Core\n'
    printf '  WAN:   %-11s %s\n' "$HG_HEALTH_WAN_STATE" "$HG_HEALTH_WAN_REASON"
    printf '  DNS:   %-11s %s\n' "$HG_HEALTH_DNS_STATE" "$HG_HEALTH_DNS_REASON"
    printf '  MAIN:  %-11s %s\n' "$HG_HEALTH_MAIN_STATE" "$HG_HEALTH_MAIN_REASON"

    printf '\nServices\n'
    printf '  Torrent:   %-11s %s\n' "$HG_HEALTH_TORRENT_STATE" "$HG_HEALTH_TORRENT_REASON"
    printf '  Redmi:     %-11s %s\n' "$HG_HEALTH_REDMI_STATE" "$HG_HEALTH_REDMI_REASON"
    printf '  ASATA:     %-11s %s\n' "$HG_HEALTH_ASATA_STATE" "$HG_HEALTH_ASATA_REASON"
    printf '  Tailscale: %-11s %s\n' "$HG_HEALTH_TAILSCALE_STATE" "$HG_HEALTH_TAILSCALE_REASON"

    printf '\nExternal evidence\n'
    hg_health_print_evidence 'Direct egress' "$HG_HEALTH_DIRECT_EGRESS_STATE" "${HG_NETWORK_DIRECT_SOURCE:-unknown}" "$HG_HEALTH_DIRECT_EGRESS_FRESHNESS" "$HG_HEALTH_DIRECT_EGRESS_AGE" "$HG_HEALTH_DIRECT_EGRESS_ATTEMPTS" "${HG_NETWORK_DIRECT_PROVIDER:-}"
    hg_health_print_evidence 'MAIN egress' "$HG_HEALTH_MAIN_EGRESS_STATE" "${HG_VPN_EGRESS_SOURCE:-unknown}" "$HG_HEALTH_MAIN_EGRESS_FRESHNESS" "$HG_HEALTH_MAIN_EGRESS_AGE" "$HG_HEALTH_MAIN_EGRESS_ATTEMPTS" "${HG_VPN_EGRESS_PROVIDER:-}"
    hg_health_print_evidence 'Torrent egress' "$HG_HEALTH_TORRENT_EGRESS_STATE" "${HG_TORRENT_EGRESS_SOURCE:-unknown}" "$HG_HEALTH_TORRENT_EGRESS_FRESHNESS" "$HG_HEALTH_TORRENT_EGRESS_AGE" "$HG_HEALTH_TORRENT_EGRESS_ATTEMPTS" "${HG_TORRENT_EGRESS_PROVIDER:-}"

    case "$HG_HEALTH_OVERALL_STATE" in
        OK|MAINTENANCE) return 0 ;;
        *) return "$HG_EXIT_UNHEALTHY" ;;
    esac
}

hg_health_json_component() {
    name="$1"
    state="$2"
    role="$3"
    reason="$4"
    comma="${5:-true}"

    printf '    "%s": {\n' "$name"
    printf '      "state": %s,\n' "$(hg_json_string "$state")"
    printf '      "role": %s,\n' "$(hg_json_string "$role")"
    printf '      "reason": %s\n' "$(hg_json_string "$reason")"

    if [ "$comma" = 'true' ]; then
        printf '    },\n'
    else
        printf '    }\n'
    fi
}

hg_health_json_evidence() {
    name="$1"
    state="$2"
    source="$3"
    checked_at="$4"
    age="$5"
    freshness="$6"
    attempts="$7"
    provider="$8"
    comma="${9:-true}"

    secondary_attempted='false'
    case "$attempts" in
        ''|*[!0-9]*) attempts='' ;;
        *)
            [ "$attempts" -gt 1 ] && secondary_attempted='true'
            ;;
    esac

    printf '    "%s": {\n' "$name"
    printf '      "state": %s,\n' "$(hg_json_string "$state")"
    printf '      "source": %s,\n' "$(hg_json_string "${source:-unknown}")"
    printf '      "provider": %s,\n' "$(hg_json_string_or_null "$provider")"
    printf '      "checked_at": %s,\n' "$(hg_json_number_or_null "$checked_at")"
    printf '      "age_seconds": %s,\n' "$(hg_json_number_or_null "$age")"
    printf '      "freshness": %s,\n' "$(hg_json_string "$freshness")"
    printf '      "probe_attempts": %s,\n' "$(hg_json_number_or_null "$attempts")"
    printf '      "secondary_attempted": %s\n' "$secondary_attempted"

    if [ "$comma" = 'true' ]; then
        printf '    },\n'
    else
        printf '    }\n'
    fi
}

hg_health_print_json() {
    hg_health_collect || return $?

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "gateway_version": %s,\n' "$(hg_json_string "$HG_VERSION")"
    printf '  "generated_at": {\n'
    printf '    "epoch": %s,\n' "$(hg_json_number_or_null "$HG_HEALTH_GENERATED_EPOCH")"
    printf '    "local": %s\n' "$(hg_json_string "${HG_STATUS_TIME_LOCAL:-unknown}")"
    printf '  },\n'
    printf '  "overall_state": %s,\n' "$(hg_json_string "$HG_HEALTH_OVERALL_STATE")"
    printf '  "attention_count": %s,\n' "$HG_HEALTH_ATTENTION_COUNT"
    printf '  "counts": {\n'
    printf '    "OK": %s,\n' "$HG_HEALTH_COUNT_OK"
    printf '    "DEGRADED": %s,\n' "$HG_HEALTH_COUNT_DEGRADED"
    printf '    "DOWN": %s,\n' "$HG_HEALTH_COUNT_DOWN"
    printf '    "UNKNOWN": %s,\n' "$HG_HEALTH_COUNT_UNKNOWN"
    printf '    "MAINTENANCE": %s\n' "$HG_HEALTH_COUNT_MAINTENANCE"
    printf '  },\n'
    printf '  "components": {\n'
    hg_health_json_component 'wan' "$HG_HEALTH_WAN_STATE" 'core' "$HG_HEALTH_WAN_REASON"
    hg_health_json_component 'dns' "$HG_HEALTH_DNS_STATE" 'core' "$HG_HEALTH_DNS_REASON"
    hg_health_json_component 'main' "$HG_HEALTH_MAIN_STATE" 'core' "$HG_HEALTH_MAIN_REASON"
    hg_health_json_component 'torrent' "$HG_HEALTH_TORRENT_STATE" 'service' "$HG_HEALTH_TORRENT_REASON"
    hg_health_json_component 'redmi' "$HG_HEALTH_REDMI_STATE" 'policy' "$HG_HEALTH_REDMI_REASON"
    hg_health_json_component 'asata' "$HG_HEALTH_ASATA_STATE" 'policy' "$HG_HEALTH_ASATA_REASON"
    hg_health_json_component 'tailscale' "$HG_HEALTH_TAILSCALE_STATE" 'service' "$HG_HEALTH_TAILSCALE_REASON" false
    printf '  },\n'
    printf '  "external_evidence": {\n'
    hg_health_json_evidence 'direct_egress' "$HG_HEALTH_DIRECT_EGRESS_STATE" "${HG_NETWORK_DIRECT_SOURCE:-unknown}" "${HG_NETWORK_DIRECT_CHECKED_AT:-}" "$HG_HEALTH_DIRECT_EGRESS_AGE" "$HG_HEALTH_DIRECT_EGRESS_FRESHNESS" "$HG_HEALTH_DIRECT_EGRESS_ATTEMPTS" "${HG_NETWORK_DIRECT_PROVIDER:-}"
    hg_health_json_evidence 'main_egress' "$HG_HEALTH_MAIN_EGRESS_STATE" "${HG_VPN_EGRESS_SOURCE:-unknown}" "${HG_VPN_EGRESS_CHECKED_AT:-}" "$HG_HEALTH_MAIN_EGRESS_AGE" "$HG_HEALTH_MAIN_EGRESS_FRESHNESS" "$HG_HEALTH_MAIN_EGRESS_ATTEMPTS" "${HG_VPN_EGRESS_PROVIDER:-}"
    hg_health_json_evidence 'torrent_egress' "$HG_HEALTH_TORRENT_EGRESS_STATE" "${HG_TORRENT_EGRESS_SOURCE:-unknown}" "${HG_TORRENT_EGRESS_CHECKED_AT:-}" "$HG_HEALTH_TORRENT_EGRESS_AGE" "$HG_HEALTH_TORRENT_EGRESS_FRESHNESS" "$HG_HEALTH_TORRENT_EGRESS_ATTEMPTS" "${HG_TORRENT_EGRESS_PROVIDER:-}" false
    printf '  }\n'
    printf '}\n'

    case "$HG_HEALTH_OVERALL_STATE" in
        OK|MAINTENANCE) return 0 ;;
        *) return "$HG_EXIT_UNHEALTHY" ;;
    esac
}
