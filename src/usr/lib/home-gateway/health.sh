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
    if [ "${HG_MONITOR_ACTIVE:-0}" = 1 ] &&
       [ "${HG_NETWORK_WAN_STATE:-UNKNOWN}" = OK ] &&
       [ "${HG_NETWORK_DIRECT_STATE:-UNKNOWN}" != OK ]; then
        printf 'wan_egress_unconfirmed'
        return
    fi
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
    elif [ "${HG_REDMI_DNS_STATE:-UNKNOWN}" = 'DOWN' ]; then
        printf 'redmi_dns_failed'
    elif [ "${HG_REDMI_DNS_STATE:-UNKNOWN}" = 'UNKNOWN' ]; then
        printf 'redmi_dns_unverified'
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

# Fingerprints contain only hashes of configuration; no configuration or node
# credentials are emitted. Missing optional generated files remain explicit.
hg_health_config_fingerprint() (
    hg_cfg="${HG_MONITOR_CONFIG_DIR:-/etc/config}"
    hg_generated="${HG_MONITOR_GENERATED_DIR:-/tmp/etc/passwall2}"
    {
        for hg_file in "$hg_cfg/network" "$hg_cfg/passwall2" "$hg_generated"/*.json; do
            if [ -f "$hg_file" ] && [ ! -L "$hg_file" ]; then
                sha256sum "$hg_file" 2>/dev/null | awk '{print $1}'
            else
                printf 'missing\n'
            fi
        done
    } | sha256sum | awk '{print $1}'
)

hg_health_observation_begin() {
    HG_OBS_BOOT="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    HG_OBS_INCARNATION="${HG_MONITOR_INCARNATION:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)}"
    HG_OBS_SEQUENCE="${HG_MONITOR_SEQUENCE:-1}"
    case "$HG_OBS_SEQUENCE" in ''|*[!0-9]*) HG_OBS_SEQUENCE=0 ;; esac
    HG_OBS_START="$(awk '{print int($1)}' /proc/uptime)"
    HG_OBS_CONFIG_BEFORE="$(hg_health_config_fingerprint)"
}

hg_health_observation_finish() {
    HG_OBS_FINISH="$(awk '{print int($1)}' /proc/uptime)"
    HG_OBS_CONFIG_AFTER="$(hg_health_config_fingerprint)"
    HG_OBS_VALID=true
    [ "$HG_OBS_CONFIG_BEFORE" = "$HG_OBS_CONFIG_AFTER" ] || HG_OBS_VALID=false
    [ "$HG_OBS_FINISH" -ge "$HG_OBS_START" ] &&
        [ "$((HG_OBS_FINISH - HG_OBS_START))" -le 35 ] || HG_OBS_VALID=false
    case "$HG_OBS_BOOT:$HG_OBS_INCARNATION" in *[!a-fA-F0-9:-]*|:*) HG_OBS_VALID=false ;; esac
    [ "${#HG_OBS_BOOT}" -eq 36 ] && [ "${#HG_OBS_INCARNATION}" -eq 36 ] || HG_OBS_VALID=false
    # Address and route identify the connection, not the public egress IP or uptime.
    HG_OBS_CONTEXT="$(printf '%s\n' "$HG_OBS_CONFIG_AFTER" \
        "${HG_NETWORK_WAN_INTERFACE:-}" "${HG_NETWORK_WAN_DEVICE:-}" \
        "${HG_NETWORK_WAN_PROTO:-}" "${HG_NETWORK_WAN_IPV4:-}" \
        "${HG_NETWORK_WAN_GATEWAY:-}" "${HG_NETWORK_WAN_PREFIX:-}" \
        "${HG_NETWORK_PATH_CONTEXT:-}" | sha256sum | awk '{print $1}')"
    [ "${#HG_OBS_CONTEXT}" -eq 64 ] || HG_OBS_VALID=false
    [ "${#HG_OBS_CONFIG_BEFORE}" -eq 64 ] || HG_OBS_VALID=false
    case "$HG_OBS_CONTEXT:$HG_OBS_CONFIG_BEFORE" in *[!a-f0-9:]*) HG_OBS_VALID=false ;; esac
}

hg_health_sample_json() {
    local hs_name="$1" hs_source=live_probe hs_checked="$HG_OBS_FINISH"
    local hs_id="$HG_OBS_BOOT:$HG_OBS_INCARNATION:$HG_OBS_SEQUENCE:$1"
    local hs_valid="$HG_OBS_VALID" hs_epoch='' hs_attempts=0 hs_age=''
    case "$hs_name" in
        wan)
            if [ "${HG_NETWORK_WAN_STATE:-UNKNOWN}" = OK ]; then
                hs_source="${HG_NETWORK_DIRECT_SOURCE:-unknown}"
                hs_epoch="${HG_NETWORK_DIRECT_CHECKED_AT:-}"
                hs_attempts="${HG_NETWORK_DIRECT_PROBE_ATTEMPTS:-0}"
            fi
            ;;
        main)
            hs_source="${HG_VPN_EGRESS_SOURCE:-unknown}"
            hs_epoch="${HG_VPN_EGRESS_CHECKED_AT:-}"
            hs_attempts="${HG_VPN_EGRESS_PROBE_ATTEMPTS:-0}"
            case "$HG_HEALTH_MAIN_REASON" in main_config_down|main_xray_down) hs_source=live_probe ;; esac
            ;;
        torrent)
            hs_source="${HG_TORRENT_EGRESS_SOURCE:-unknown}"
            hs_epoch="${HG_TORRENT_EGRESS_CHECKED_AT:-}"
            hs_attempts="${HG_TORRENT_EGRESS_PROBE_ATTEMPTS:-0}"
            case "$HG_HEALTH_TORRENT_REASON" in torrent_config_down|torrent_xray_down) hs_source=live_probe ;; esac
            ;;
    esac
    # A new failed attempt remains a new observation even if an old positive IP
    # is retained for display by the adapter. Display cache is never its evidence.
    if [ "$hs_attempts" -gt 0 ] 2>/dev/null; then hs_source=live_probe; fi
    case "$hs_source" in
        cache)
            hs_age="$(hg_health_age_seconds "$hs_epoch")"
            case "$hs_age" in ''|*[!0-9]*) hs_valid=false ;; *)
                [ "$hs_age" -le 120 ] || hs_valid=false
                hs_checked=$((HG_OBS_FINISH - hs_age)) ;;
            esac
            hs_id="$HG_OBS_BOOT:$HG_OBS_CONTEXT:$hs_name:cache:$hs_epoch"
            ;;
        live_probe) ;;
        *) hs_valid=false ;;
    esac
    printf '      "sample": {"id":%s,"context":%s,"boot_id":%s,"checked_uptime":%s,"expires_uptime":%s,"source":%s,"valid":%s}\n' \
        "$(hg_json_string "$hs_id")" "$(hg_json_string "$HG_OBS_CONTEXT")" \
        "$(hg_json_string "$HG_OBS_BOOT")" "$hs_checked" "$((hs_checked + 120))" \
        "$(hg_json_string "$hs_source")" "$hs_valid"
}

hg_health_collect() {
    if ! command -v hg_status_collect >/dev/null 2>&1; then
        hg_load_module status >/dev/null 2>&1 || return "$HG_EXIT_SOFTWARE"
    fi

    hg_health_observation_begin
    if [ "${HG_MONITOR_ACTIVE:-0}" = 1 ]; then
        # The independent minute worker must make new probes; dashboard reads
        # keep their existing bounded cache behavior.
        export HG_EGRESS_CACHE_TTL=0 HG_MAIN_EGRESS_CACHE_TTL=0 HG_TORRENT_EGRESS_CACHE_TTL=0
    fi
    hg_status_collect
    hg_health_observation_finish

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

    if [ "${HG_MONITOR_ACTIVE:-0}" = 1 ]; then
        if [ "$HG_HEALTH_WAN_STATE" = OK ] && [ "${HG_NETWORK_DIRECT_STATE:-UNKNOWN}" != OK ]; then
            if [ "${HG_NETWORK_DIRECT_PROBE_ATTEMPTS:-0}" -gt 0 ]; then
                HG_HEALTH_WAN_STATE=DEGRADED
            else
                HG_HEALTH_WAN_STATE=UNKNOWN
            fi
        fi
        # No attempted external check is missing evidence, never a confirmed
        # outage. Local config/process failures retain their own DOWN scope.
        if [ "$HG_HEALTH_MAIN_STATE" = DEGRADED ] &&
           [ "${HG_VPN_EGRESS_STATE:-UNKNOWN}" = UNKNOWN ] &&
           [ "${HG_VPN_EGRESS_PROBE_ATTEMPTS:-0}" = 0 ]; then
            HG_HEALTH_MAIN_STATE=UNKNOWN
        fi
        if [ "$HG_HEALTH_REDMI_STATE" = DEGRADED ] &&
           [ "${HG_REDMI_DNS_STATE:-UNKNOWN}" = UNKNOWN ] &&
           [ "${HG_REDMI_KILLSWITCH_STATE:-UNKNOWN}" != DOWN ] &&
           [ "${HG_REDMI_POLICY_STATE:-UNKNOWN}" != DOWN ] &&
           [ "${HG_REDMI_XRAY_STATE:-UNKNOWN}" != DOWN ]; then
            HG_HEALTH_REDMI_STATE=UNKNOWN
        fi
    fi

    if [ -r "${HG_ACTION_STATE_DIR:-/etc/home-gateway/state}/actions.json" ] &&
       [ -r "${HG_LIBDIR}/actions.uc" ] &&
       [ "$(ucode "${HG_LIBDIR}/actions.uc" maintenance 2>/dev/null || true)" = MAINTENANCE ]; then
        HG_HEALTH_TAILSCALE_STATE='MAINTENANCE'
    fi

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
    printf '      "reason": %s,\n' "$(hg_json_string "$reason")"
    hg_health_sample_json "$name"

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
    printf '  "observation": {"schema_version":1,"boot_id":%s,"incarnation":%s,"sequence":%s,"started_uptime":%s,"finished_uptime":%s,"context":%s,"valid":%s,"wall_time_trusted":%s,"wall_time_quality":"unconfirmed"},\n' \
        "$(hg_json_string "$HG_OBS_BOOT")" "$(hg_json_string "$HG_OBS_INCARNATION")" \
        "$HG_OBS_SEQUENCE" "$HG_OBS_START" "$HG_OBS_FINISH" "$(hg_json_string "$HG_OBS_CONTEXT")" \
        "$HG_OBS_VALID" "$(if [ "${HG_MONITOR_TIME_TRUSTED:-0}" = 1 ]; then printf true; else printf false; fi)"
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
