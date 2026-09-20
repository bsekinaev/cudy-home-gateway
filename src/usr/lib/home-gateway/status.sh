#!/bin/sh
# Read-only системный статус CUDY Home Gateway.

hg_status_uptime() {
    uptime_seconds="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || printf '0')"

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

hg_status_memory() {
    awk '
        /^MemTotal:/     { total = $2 }
        /^MemAvailable:/ { available = $2 }
        END {
            if (total <= 0) {
                print "n/a"
                exit
            }
            used = total - available
            percent = int((used * 100) / total)
            printf "%.0f / %.0f MiB (%d%%), доступно %.0f MiB", used / 1024, total / 1024, percent, available / 1024
        }
    ' /proc/meminfo 2>/dev/null
}

hg_status_overlay() {
    df -k /overlay 2>/dev/null | awk '
        NR == 2 {
            total = $2
            used = $3
            available = $4
            percent = $5
            gsub(/%/, "", percent)
            printf "%.1f / %.1f MiB (%s%%), свободно %.1f MiB", used / 1024, total / 1024, percent, available / 1024
        }
    '
}

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

hg_status_openwrt() {
    release='unknown'
    revision='unknown'

    if [ -r /etc/openwrt_release ]; then
        release="$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release | head -n 1)"
        revision="$(sed -n "s/^DISTRIB_REVISION='\(.*\)'/\1/p" /etc/openwrt_release | head -n 1)"
        [ -n "$release" ] || release='unknown'
        [ -n "$revision" ] || revision='unknown'
    fi

    printf '%s (%s)' "$release" "$revision"
}

hg_status_ntp() {
    if ps w 2>/dev/null | grep -q '[n]tpd'; then
        printf 'RUNNING'
    else
        printf 'NOT RUNNING'
    fi
}

hg_status_print() {
    hostname_value="$(cat /proc/sys/kernel/hostname 2>/dev/null || printf 'unknown')"
    kernel_value="$(uname -r 2>/dev/null || printf 'unknown')"
    load_value="$(awk '{print $1 " " $2 " " $3}' /proc/loadavg 2>/dev/null || printf 'n/a')"
    time_value="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date 2>/dev/null || printf 'unknown')"

    printf '%s — системный статус\n\n' "$HG_NAME"
    printf 'Система\n'
    printf '  Hostname: %-s\n' "$hostname_value"
    printf '  Model:    %s\n' "$(hg_status_model)"
    printf '  OpenWrt:  %s\n' "$(hg_status_openwrt)"
    printf '  Kernel:   %s\n' "$kernel_value"
    printf '  Uptime:   %s\n' "$(hg_status_uptime)"
    printf '  Load:     %s\n' "$load_value"
    printf '\nРесурсы\n'
    printf '  RAM:      %s\n' "$(hg_status_memory)"
    printf '  Overlay:  %s\n' "$(hg_status_overlay)"
    printf '\nВремя\n'
    printf '  Local:    %s\n' "$time_value"
    printf '  NTP:      %s\n' "$(hg_status_ntp)"
}
