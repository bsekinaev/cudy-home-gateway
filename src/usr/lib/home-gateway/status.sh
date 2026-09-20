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
