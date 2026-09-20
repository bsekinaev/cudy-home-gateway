#!/bin/sh
# Read-only системный статус CUDY Home Gateway.

hg_status_model() {
    if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        model="$(ubus call system board 2>/dev/null | jsonfilter -e '@.model' 2>/dev/null || true)"
        if [ -n "$model" ]; then
            printf '%s' "$model"
            return 0
        fi
    fi

    if [ -r /tmp/sysinfo/model ]; then
        cat /tmp/sysinfo/model
    else
        printf 'unknown'
    fi
}

hg_status_collect() {
    HG_STATUS_HOSTNAME="$(cat /proc/sys/kernel/hostname 2>/dev/null || printf 'unknown')"
    HG_STATUS_MODEL="$(hg_status_model)"
    HG_STATUS_KERNEL="$(uname -r 2>/dev/null || printf 'unknown')"

    HG_STATUS_OPENWRT_RELEASE='unknown'
    HG_STATUS_OPENWRT_REVISION='unknown'
    if [ -r /etc/openwrt_release ]; then
        release="$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release | head -n 1)"
        revision="$(sed -n "s/^DISTRIB_REVISION='\(.*\)'/\1/p" /etc/openwrt_release | head -n 1)"
        [ -n "$release" ] && HG_STATUS_OPENWRT_RELEASE="$release"
        [ -n "$revision" ] && HG_STATUS_OPENWRT_REVISION="$revision"
    fi

    HG_STATUS_UPTIME_SECONDS="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || true)"

    set -- $(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || true)
    HG_STATUS_LOAD_1="${1:-}"
    HG_STATUS_LOAD_5="${2:-}"
    HG_STATUS_LOAD_15="${3:-}"

    set -- $(awk '
        /^MemTotal:/     { total = $2 }
        /^MemAvailable:/ { available = $2 }
        END {
            if (total > 0 && available >= 0) {
                used = total - available
                percent = int((used * 100) / total)
                print total, used, available, percent
            }
        }
    ' /proc/meminfo 2>/dev/null || true)
    HG_STATUS_MEMORY_TOTAL_KIB="${1:-}"
    HG_STATUS_MEMORY_USED_KIB="${2:-}"
    HG_STATUS_MEMORY_AVAILABLE_KIB="${3:-}"
    HG_STATUS_MEMORY_USED_PERCENT="${4:-}"

    set -- $(df -k /overlay 2>/dev/null | awk '
        NR == 2 {
            percent = $5
            gsub(/%/, "", percent)
            print $2, $3, $4, percent
        }
    ')
    HG_STATUS_OVERLAY_TOTAL_KIB="${1:-}"
    HG_STATUS_OVERLAY_USED_KIB="${2:-}"
    HG_STATUS_OVERLAY_AVAILABLE_KIB="${3:-}"
    HG_STATUS_OVERLAY_USED_PERCENT="${4:-}"

    HG_STATUS_TIME_LOCAL="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date 2>/dev/null || printf 'unknown')"
    HG_STATUS_TIMEZONE="$(date '+%Z' 2>/dev/null || printf 'unknown')"
    HG_STATUS_TIME_EPOCH="$(date '+%s' 2>/dev/null || true)"

    if ps w 2>/dev/null | grep -q '[n]tpd'; then
        HG_STATUS_NTP_PROCESS='running'
    else
        HG_STATUS_NTP_PROCESS='not_running'
    fi

    if ! command -v hg_network_collect >/dev/null 2>&1; then
        hg_load_module network >/dev/null 2>&1 || true
    fi
    if command -v hg_network_collect >/dev/null 2>&1; then
        hg_network_collect
    fi

    if ! command -v hg_vpn_collect >/dev/null 2>&1; then
        hg_load_module vpn >/dev/null 2>&1 || true
    fi
    if command -v hg_vpn_collect >/dev/null 2>&1; then
        hg_vpn_collect
    fi
}

hg_status_format_uptime() {
    uptime_seconds="${HG_STATUS_UPTIME_SECONDS:-0}"
    case "$uptime_seconds" in
        ''|*[!0-9]*) uptime_seconds=0 ;;
    esac

    days=$((uptime_seconds / 86400))
    hours=$(((uptime_seconds % 86400) / 3600))
    minutes=$(((uptime_seconds % 3600) / 60))

    if [ "$days" -gt 0 ]; then
        printf '%sд %sч %sм' "$days" "$hours" "$minutes"
    elif [ "$hours" -gt 0 ]; then
        printf '%sч %sм' "$hours" "$minutes"
    else
        printf '%sм' "$minutes"
    fi
}

hg_status_format_memory() {
    if [ -z "${HG_STATUS_MEMORY_TOTAL_KIB:-}" ]; then
        printf 'n/a'
        return 0
    fi

    awk \
        -v total="$HG_STATUS_MEMORY_TOTAL_KIB" \
        -v used="$HG_STATUS_MEMORY_USED_KIB" \
        -v available="$HG_STATUS_MEMORY_AVAILABLE_KIB" \
        -v percent="$HG_STATUS_MEMORY_USED_PERCENT" \
        'BEGIN {
            printf "%.0f / %.0f MiB (%d%%), доступно %.0f MiB", used / 1024, total / 1024, percent, available / 1024
        }'
}

hg_status_format_overlay() {
    if [ -z "${HG_STATUS_OVERLAY_TOTAL_KIB:-}" ]; then
        printf 'n/a'
        return 0
    fi

    awk \
        -v total="$HG_STATUS_OVERLAY_TOTAL_KIB" \
        -v used="$HG_STATUS_OVERLAY_USED_KIB" \
        -v available="$HG_STATUS_OVERLAY_AVAILABLE_KIB" \
        -v percent="$HG_STATUS_OVERLAY_USED_PERCENT" \
        'BEGIN {
            printf "%.1f / %.1f MiB (%d%%), свободно %.1f MiB", used / 1024, total / 1024, percent, available / 1024
        }'
}

hg_status_json_words_array() {
    words="${1:-}"
    first=1

    printf '['
    for word in $words; do
        if [ "$first" -eq 0 ]; then
            printf ', '
        fi
        hg_json_string "$word"
        first=0
    done
    printf ']'
}

hg_status_print() {
    hg_status_collect

    printf '%s — системный статус\n\n' "$HG_NAME"
    printf 'Система\n'
    printf '  Hostname: %-s\n' "$HG_STATUS_HOSTNAME"
    printf '  Model:    %s\n' "$HG_STATUS_MODEL"
    printf '  OpenWrt:  %s (%s)\n' "$HG_STATUS_OPENWRT_RELEASE" "$HG_STATUS_OPENWRT_REVISION"
    printf '  Kernel:   %s\n' "$HG_STATUS_KERNEL"
    printf '  Uptime:   %s\n' "$(hg_status_format_uptime)"
    printf '  Load:     %s %s %s\n' "${HG_STATUS_LOAD_1:-n/a}" "${HG_STATUS_LOAD_5:-n/a}" "${HG_STATUS_LOAD_15:-n/a}"
    printf '\nРесурсы\n'
    printf '  RAM:      %s\n' "$(hg_status_format_memory)"
    printf '  Overlay:  %s\n' "$(hg_status_format_overlay)"
    printf '\nВремя\n'
    printf '  Local:    %s\n' "$HG_STATUS_TIME_LOCAL"
    if [ "$HG_STATUS_NTP_PROCESS" = 'running' ]; then
        printf '  NTP:      RUNNING\n'
    else
        printf '  NTP:      NOT RUNNING\n'
    fi

    case "${HG_NETWORK_WAN_CGNAT:-unknown}" in
        true) cgnat_label='yes' ;;
        false) cgnat_label='no' ;;
        *) cgnat_label='unknown' ;;
    esac

    if [ -n "${HG_NETWORK_WAN_IPV4:-}" ]; then
        wan_ipv4_label="$HG_NETWORK_WAN_IPV4"
        [ -n "${HG_NETWORK_WAN_PREFIX:-}" ] && wan_ipv4_label="${wan_ipv4_label}/${HG_NETWORK_WAN_PREFIX}"
    else
        wan_ipv4_label='n/a'
    fi

    direct_ipv4_label="${HG_NETWORK_DIRECT_IPV4:-n/a}"

    printf '\nСеть\n'
    printf '  WAN:           %s\n' "${HG_NETWORK_WAN_STATE:-UNKNOWN}"
    printf '  Interface:     %s\n' "${HG_NETWORK_WAN_INTERFACE:-wan}"
    printf '  Device:        %s\n' "${HG_NETWORK_WAN_DEVICE:-n/a}"
    printf '  Protocol:      %s\n' "${HG_NETWORK_WAN_PROTO:-n/a}"
    printf '  WAN IPv4:      %s\n' "$wan_ipv4_label"
    printf '  Gateway:       %s\n' "${HG_NETWORK_WAN_GATEWAY:-n/a}"
    printf '  CGNAT:         %s\n' "$cgnat_label"
    printf '  Direct egress: %s (%s)\n' "$direct_ipv4_label" "${HG_NETWORK_DIRECT_STATE:-UNKNOWN}"

    case "${HG_VPN_PASSWALL_ENABLED:-unknown}" in
        true) passwall_label='enabled' ;;
        false) passwall_label='disabled' ;;
        *) passwall_label='unknown' ;;
    esac
    case "${HG_VPN_AUTOSWITCH_ENABLED:-unknown}" in
        true) autoswitch_label='enabled' ;;
        false) autoswitch_label='disabled' ;;
        *) autoswitch_label='unknown' ;;
    esac

    vpn_name_label="${HG_VPN_MAIN_NAME:-n/a}"
    vpn_backups_label="${HG_VPN_BACKUP_NODES:-none}"
    vpn_egress_label="${HG_VPN_EGRESS_IPV4:-n/a}"
    if [ -n "${HG_VPN_MAIN_SOCKS_PORT:-}" ]; then
        vpn_socks_label="${HG_VPN_MAIN_SOCKS_HOST:-127.0.0.1}:${HG_VPN_MAIN_SOCKS_PORT}"
    else
        vpn_socks_label='n/a'
    fi

    printf '\nVPN\n'
    printf '  PassWall2:      %s\n' "$passwall_label"
    printf '  MAIN state:     %s\n' "${HG_VPN_MAIN_STATE:-UNKNOWN}"
    printf '  Profile:        %s\n' "${HG_VPN_MAIN_PROFILE:-n/a}"
    printf '  Node:           %s\n' "${HG_VPN_MAIN_NODE:-n/a}"
    printf '  Name:           %s\n' "$vpn_name_label"
    printf '  SOCKS:          %s\n' "$vpn_socks_label"
    printf '  Xray:           %s\n' "${HG_VPN_MAIN_XRAY_STATE:-UNKNOWN}"
    printf '  Autoswitch:     %s\n' "$autoswitch_label"
    printf '  Backups:        %s\n' "$vpn_backups_label"
    printf '  MAIN egress:    %s (%s)\n' "$vpn_egress_label" "${HG_VPN_EGRESS_STATE:-UNKNOWN}"
    printf '  Active route:   %s\n' "${HG_VPN_ACTIVE_NODE_STATE:-UNKNOWN}"
}

hg_status_print_json() {
    hg_status_collect

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "gateway_version": %s,\n' "$(hg_json_string "$HG_VERSION")"
    printf '  "generated_at": {\n'
    printf '    "epoch": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_TIME_EPOCH")"
    printf '    "local": %s,\n' "$(hg_json_string "$HG_STATUS_TIME_LOCAL")"
    printf '    "timezone": %s\n' "$(hg_json_string "$HG_STATUS_TIMEZONE")"
    printf '  },\n'
    printf '  "system": {\n'
    printf '    "hostname": %s,\n' "$(hg_json_string "$HG_STATUS_HOSTNAME")"
    printf '    "model": %s,\n' "$(hg_json_string "$HG_STATUS_MODEL")"
    printf '    "openwrt_version": %s,\n' "$(hg_json_string "$HG_STATUS_OPENWRT_RELEASE")"
    printf '    "openwrt_revision": %s,\n' "$(hg_json_string "$HG_STATUS_OPENWRT_REVISION")"
    printf '    "kernel": %s,\n' "$(hg_json_string "$HG_STATUS_KERNEL")"
    printf '    "uptime_seconds": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_UPTIME_SECONDS")"
    printf '    "load": {\n'
    printf '      "1m": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_LOAD_1")"
    printf '      "5m": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_LOAD_5")"
    printf '      "15m": %s\n' "$(hg_json_number_or_null "$HG_STATUS_LOAD_15")"
    printf '    }\n'
    printf '  },\n'
    case "${HG_NETWORK_WAN_CGNAT:-unknown}" in
        true|false) cgnat_json="$HG_NETWORK_WAN_CGNAT" ;;
        *) cgnat_json='null' ;;
    esac
    printf '  "network": {\n'
    printf '    "wan": {\n'
    printf '      "state": %s,\n' "$(hg_json_string "${HG_NETWORK_WAN_STATE:-UNKNOWN}")"
    printf '      "interface": %s,\n' "$(hg_json_string "${HG_NETWORK_WAN_INTERFACE:-wan}")"
    printf '      "device": %s,\n' "$(hg_json_string_or_null "${HG_NETWORK_WAN_DEVICE:-}")"
    printf '      "proto": %s,\n' "$(hg_json_string_or_null "${HG_NETWORK_WAN_PROTO:-}")"
    printf '      "ipv4": %s,\n' "$(hg_json_string_or_null "${HG_NETWORK_WAN_IPV4:-}")"
    printf '      "prefix_length": %s,\n' "$(hg_json_number_or_null "${HG_NETWORK_WAN_PREFIX:-}")"
    printf '      "gateway": %s,\n' "$(hg_json_string_or_null "${HG_NETWORK_WAN_GATEWAY:-}")"
    printf '      "cgnat": %s\n' "$cgnat_json"
    printf '    },\n'
    printf '    "direct_egress": {\n'
    printf '      "state": %s,\n' "$(hg_json_string "${HG_NETWORK_DIRECT_STATE:-UNKNOWN}")"
    printf '      "ipv4": %s,\n' "$(hg_json_string_or_null "${HG_NETWORK_DIRECT_IPV4:-}")"
    printf '      "source": %s,\n' "$(hg_json_string "${HG_NETWORK_DIRECT_SOURCE:-live_probe}")"
    printf '      "provider": %s,\n' "$(hg_json_string_or_null "${HG_NETWORK_DIRECT_PROVIDER:-}")"
    printf '      "checked_at": %s\n' "$(hg_json_number_or_null "${HG_NETWORK_DIRECT_CHECKED_AT:-}")"
    printf '    }\n'
    printf '  },\n'

    case "${HG_VPN_PASSWALL_ENABLED:-unknown}" in
        true|false) passwall_json="$HG_VPN_PASSWALL_ENABLED" ;;
        *) passwall_json='null' ;;
    esac
    case "${HG_VPN_MAIN_PROFILE_ENABLED:-unknown}" in
        true|false) profile_enabled_json="$HG_VPN_MAIN_PROFILE_ENABLED" ;;
        *) profile_enabled_json='null' ;;
    esac
    case "${HG_VPN_AUTOSWITCH_ENABLED:-unknown}" in
        true|false) autoswitch_json="$HG_VPN_AUTOSWITCH_ENABLED" ;;
        *) autoswitch_json='null' ;;
    esac

    printf '  "vpn": {\n'
    printf '    "passwall2": {\n'
    printf '      "enabled": %s\n' "$passwall_json"
    printf '    },\n'
    printf '    "main": {\n'
    printf '      "state": %s,\n' "$(hg_json_string "${HG_VPN_MAIN_STATE:-UNKNOWN}")"
    printf '      "config_state": %s,\n' "$(hg_json_string "${HG_VPN_MAIN_CONFIG_STATE:-UNKNOWN}")"
    printf '      "profile": %s,\n' "$(hg_json_string_or_null "${HG_VPN_MAIN_PROFILE:-}")"
    printf '      "profile_enabled": %s,\n' "$profile_enabled_json"
    printf '      "configured_node": {\n'
    printf '        "id": %s,\n' "$(hg_json_string_or_null "${HG_VPN_MAIN_NODE:-}")"
    printf '        "name": %s\n' "$(hg_json_string_or_null "${HG_VPN_MAIN_NAME:-}")"
    printf '      },\n'
    printf '      "socks": {\n'
    printf '        "host": %s,\n' "$(hg_json_string "${HG_VPN_MAIN_SOCKS_HOST:-127.0.0.1}")"
    printf '        "port": %s\n' "$(hg_json_number_or_null "${HG_VPN_MAIN_SOCKS_PORT:-}")"
    printf '      },\n'
    printf '      "xray_process": %s,\n' "$(hg_json_string "${HG_VPN_MAIN_XRAY_STATE:-UNKNOWN}")"
    printf '      "autoswitch": {\n'
    printf '        "enabled": %s,\n' "$autoswitch_json"
    printf '        "backup_nodes": %s,\n' "$(hg_status_json_words_array "${HG_VPN_BACKUP_NODES:-}")"
    printf '        "active_node": %s,\n' "$(hg_json_string_or_null "${HG_VPN_ACTIVE_NODE:-}")"
    printf '        "active_node_state": %s\n' "$(hg_json_string "${HG_VPN_ACTIVE_NODE_STATE:-UNKNOWN}")"
    printf '      },\n'
    printf '      "egress": {\n'
    printf '        "state": %s,\n' "$(hg_json_string "${HG_VPN_EGRESS_STATE:-UNKNOWN}")"
    printf '        "ipv4": %s,\n' "$(hg_json_string_or_null "${HG_VPN_EGRESS_IPV4:-}")"
    printf '        "source": %s,\n' "$(hg_json_string "${HG_VPN_EGRESS_SOURCE:-live_probe}")"
    printf '        "provider": %s,\n' "$(hg_json_string_or_null "${HG_VPN_EGRESS_PROVIDER:-}")"
    printf '        "checked_at": %s\n' "$(hg_json_number_or_null "${HG_VPN_EGRESS_CHECKED_AT:-}")"
    printf '      }\n'
    printf '    }\n'
    printf '  },\n'
    printf '  "resources": {\n'
    printf '    "memory": {\n'
    printf '      "total_kib": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_MEMORY_TOTAL_KIB")"
    printf '      "used_kib": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_MEMORY_USED_KIB")"
    printf '      "available_kib": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_MEMORY_AVAILABLE_KIB")"
    printf '      "used_percent": %s\n' "$(hg_json_number_or_null "$HG_STATUS_MEMORY_USED_PERCENT")"
    printf '    },\n'
    printf '    "overlay": {\n'
    printf '      "total_kib": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_OVERLAY_TOTAL_KIB")"
    printf '      "used_kib": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_OVERLAY_USED_KIB")"
    printf '      "available_kib": %s,\n' "$(hg_json_number_or_null "$HG_STATUS_OVERLAY_AVAILABLE_KIB")"
    printf '      "used_percent": %s\n' "$(hg_json_number_or_null "$HG_STATUS_OVERLAY_USED_PERCENT")"
    printf '    }\n'
    printf '  },\n'
    printf '  "time": {\n'
    printf '    "ntp_process": %s\n' "$(hg_json_string "$HG_STATUS_NTP_PROCESS")"
    printf '  }\n'
    printf '}\n'
}
