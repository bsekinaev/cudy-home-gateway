#!/bin/sh
# Read-only диагностика окружения CUDY Home Gateway.

HG_DOCTOR_OK=0
HG_DOCTOR_WARN=0
HG_DOCTOR_FAIL=0

hg_doctor_result() {
    state="$1"
    name="$2"
    detail="${3:-}"

    case "$state" in
        OK)
            HG_DOCTOR_OK=$((HG_DOCTOR_OK + 1))
            ;;
        WARN)
            HG_DOCTOR_WARN=$((HG_DOCTOR_WARN + 1))
            ;;
        FAIL)
            HG_DOCTOR_FAIL=$((HG_DOCTOR_FAIL + 1))
            ;;
        *)
            state='FAIL'
            HG_DOCTOR_FAIL=$((HG_DOCTOR_FAIL + 1))
            ;;
    esac

    if [ -n "$detail" ]; then
        printf '[%-4s] %s — %s\n' "$state" "$name" "$detail"
    else
        printf '[%-4s] %s\n' "$state" "$name"
    fi
}

hg_doctor_runtime() {
    missing=''

    for bin in sh awk sed grep wc date ps df curl jsonfilter uci ubus nft flock ucode ip; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            missing="${missing}${missing:+, }${bin}"
        fi
    done

    if [ -z "$missing" ]; then
        hg_doctor_result OK 'Runtime' 'все обязательные утилиты доступны'
    else
        hg_doctor_result FAIL 'Runtime' "отсутствуют: $missing"
    fi
}

hg_doctor_openwrt() {
    if [ -r /etc/openwrt_release ] && [ -r /proc/uptime ] && [ -r /proc/meminfo ]; then
        hg_doctor_result OK 'OpenWrt / procfs' 'базовые системные источники доступны'
    else
        hg_doctor_result FAIL 'OpenWrt / procfs' 'не хватает системных источников'
    fi
}

hg_doctor_overlay() {
    available_kib="$(df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"

    case "$available_kib" in
        ''|*[!0-9]*)
            hg_doctor_result FAIL 'Overlay' 'не удалось определить свободное место'
            return 0
            ;;
    esac

    available_mib=$((available_kib / 1024))

    if [ "$available_kib" -lt 8192 ]; then
        hg_doctor_result FAIL 'Overlay' "свободно ${available_mib} MiB (< 8 MiB)"
    elif [ "$available_kib" -lt 16384 ]; then
        hg_doctor_result WARN 'Overlay' "свободно ${available_mib} MiB (< 16 MiB)"
    else
        hg_doctor_result OK 'Overlay' "свободно ${available_mib} MiB"
    fi
}

hg_doctor_time() {
    year="$(date '+%Y' 2>/dev/null || true)"

    case "$year" in
        ''|*[!0-9]*)
            hg_doctor_result FAIL 'Системное время' 'не удалось прочитать год'
            ;;
        *)
            if [ "$year" -ge 2025 ]; then
                hg_doctor_result OK 'Системное время' "год выглядит корректно: $year"
            else
                hg_doctor_result FAIL 'Системное время' "подозрительный год: $year"
            fi
            ;;
    esac

    if ps w 2>/dev/null | grep -q '[n]tpd'; then
        hg_doctor_result OK 'NTP process' 'ntpd запущен'
    else
        hg_doctor_result WARN 'NTP process' 'ntpd не найден'
    fi
}

hg_doctor_vtest() {
    if command -v vtest >/dev/null 2>&1; then
        hg_doctor_result OK 'vtest' "$(command -v vtest)"
    else
        hg_doctor_result FAIL 'vtest' 'команда не найдена'
    fi

    if [ -r /etc/crontabs/root ] && grep -q '/usr/bin/vtest' /etc/crontabs/root 2>/dev/null; then
        hg_doctor_result OK 'vtest cron' 'расписание найдено'
    else
        hg_doctor_result WARN 'vtest cron' 'расписание не найдено'
    fi
}

hg_doctor_passwall2() {
    if uci -q show passwall2 >/dev/null 2>&1; then
        hg_doctor_result OK 'PassWall2 config' 'UCI-конфигурация доступна'
    else
        hg_doctor_result FAIL 'PassWall2 config' 'UCI-конфигурация не найдена'
    fi

    if ps w 2>/dev/null | grep -q '[x]ray'; then
        xray_count="$(ps w 2>/dev/null | grep '[x]ray' | wc -l | awk '{print $1}')"
        hg_doctor_result OK 'Xray' "процессов: ${xray_count:-unknown}"
    else
        hg_doctor_result FAIL 'Xray' 'работающие процессы не найдены'
    fi
}

hg_doctor_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        hg_doctor_result WARN 'Tailscale' 'CLI не найден'
        return 0
    fi

    if ps w 2>/dev/null | grep -q '[t]ailscaled'; then
        hg_doctor_result OK 'Tailscale' 'tailscaled запущен'
    else
        hg_doctor_result WARN 'Tailscale' 'tailscaled не запущен'
    fi
}

hg_doctor_asata() {
    if nft -a list chain inet passwall2 PSW2_MANGLE 2>/dev/null | grep -q 'ASATA-UDP-DIRECT'; then
        hg_doctor_result OK 'ASATA UDP DIRECT' 'правило присутствует'
    else
        hg_doctor_result FAIL 'ASATA UDP DIRECT' 'правило не найдено'
    fi
}

hg_doctor_run() {
    HG_DOCTOR_OK=0
    HG_DOCTOR_WARN=0
    HG_DOCTOR_FAIL=0

    printf '%s — doctor\n\n' "$HG_NAME"

    hg_doctor_runtime
    hg_doctor_openwrt
    hg_doctor_overlay
    hg_doctor_time
    hg_doctor_vtest
    hg_doctor_passwall2
    hg_doctor_tailscale
    hg_doctor_asata

    printf '\nИтог: OK=%s WARN=%s FAIL=%s\n' \
        "$HG_DOCTOR_OK" "$HG_DOCTOR_WARN" "$HG_DOCTOR_FAIL"

    if [ "$HG_DOCTOR_FAIL" -gt 0 ]; then
        printf 'Результат: FAIL\n'
        return "$HG_EXIT_UNHEALTHY"
    fi

    if [ "$HG_DOCTOR_WARN" -gt 0 ]; then
        printf 'Результат: OK с предупреждениями\n'
    else
        printf 'Результат: OK\n'
    fi

    return 0
}
