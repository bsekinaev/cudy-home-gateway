#!/bin/sh
# Read-only preflight для CUDY Home Gateway.
# Скрипт не меняет UCI, firewall, сервисы или пакеты.

set -u

section() {
    printf '\n===== %s =====\n' "$1"
}

has() {
    command -v "$1" >/dev/null 2>&1
}

print_cmd() {
    label="$1"
    shift
    printf '%-22s ' "$label"
    if "$@" >/tmp/hg-preflight.out 2>/tmp/hg-preflight.err; then
        head -n 1 /tmp/hg-preflight.out
    else
        printf 'NO/ERROR\n'
    fi
}

section "SYSTEM"
date 2>/dev/null || true
uname -a 2>/dev/null || true
[ -r /etc/openwrt_release ] && cat /etc/openwrt_release

section "BOARD"
if has ubus; then
    ubus call system board 2>/dev/null | jsonfilter -e '@.model' -e '@.board_name' 2>/dev/null || true
else
    echo "ubus: missing"
fi

section "RESOURCES"
uptime 2>/dev/null || true
printf 'loadavg: '; cat /proc/loadavg 2>/dev/null || true
free -m 2>/dev/null || free 2>/dev/null || true
df -h /overlay /tmp 2>/dev/null || true

section "RUNTIME"
for bin in sh ash curl jsonfilter uci ubus nft flock ucode; do
    if has "$bin"; then
        printf '%-12s %s\n' "$bin" "$(command -v "$bin")"
    else
        printf '%-12s %s\n' "$bin" "MISSING"
    fi
done

if has ucode; then
    echo "ucode help/version:"
    ucode -h 2>&1 | head -n 3 || true
fi

section "PACKAGES"
if has apk; then
    for pkg in ucode curl jsonfilter tailscale irqbalance; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            echo "$pkg: installed"
        else
            echo "$pkg: not-installed-or-different-package-name"
        fi
    done
else
    echo "apk: missing"
fi

section "PROCESSES"
echo "xray:"
ps w 2>/dev/null | grep '[x]ray' || true
echo "tailscale:"
ps w 2>/dev/null | grep '[t]ailscaled' || true
echo "cron:"
ps w 2>/dev/null | grep '[c]rond' || true

section "MEMORY TOP"
if has top; then
    top -bn1 2>/dev/null | head -n 20 || true
fi

section "LISTENERS"
netstat -lntp 2>/dev/null | head -n 40 || true

section "VTEST"
if has vtest; then
    vtest status 2>/dev/null || true
else
    echo "vtest: missing"
fi

section "ASATA RULE"
if has nft; then
    nft -a list chain inet passwall2 PSW2_MANGLE 2>/dev/null | grep 'ASATA-UDP-DIRECT' || echo "ASATA-UDP-DIRECT: not found"
fi

section "FINISHED"
echo "Read-only preflight completed."

rm -f /tmp/hg-preflight.out /tmp/hg-preflight.err
