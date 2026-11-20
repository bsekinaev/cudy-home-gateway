# Appended after committed monitor definitions; streamed over SSH stdin.
umask 077
HG_MONITOR_PROBE_TMP="$(mktemp -d /tmp/hg-monitor-readiness.XXXXXX)" || exit 70
hg_monitor_probe_cleanup() {
    rm -f "$HG_MONITOR_PROBE_TMP/direct" "$HG_MONITOR_PROBE_TMP/main" \
        "$HG_MONITOR_PROBE_TMP/torrent" "$HG_MONITOR_PROBE_TMP/health.json"
    rmdir "$HG_MONITOR_PROBE_TMP" 2>/dev/null || true
}
trap hg_monitor_probe_cleanup EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
export HG_LIBDIR=/usr/lib/home-gateway HG_MONITOR_ACTIVE=1 HG_MONITOR_SEQUENCE=1
HG_MONITOR_INCARNATION="$(cat /proc/sys/kernel/random/uuid)" || exit 70
export HG_MONITOR_INCARNATION
export HG_EGRESS_CACHE_FILE="$HG_MONITOR_PROBE_TMP/direct"
export HG_MAIN_EGRESS_CACHE_FILE="$HG_MONITOR_PROBE_TMP/main"
export HG_TORRENT_EGRESS_CACHE_FILE="$HG_MONITOR_PROBE_TMP/torrent"
HG_MONITOR_PROBE_TIMEOUT=false
HG_MONITOR_PROBE_SETSID=false
if command -v timeout >/dev/null 2>&1 && timeout -k 1 2 sh -c 'exit 0'; then
    HG_MONITOR_PROBE_TIMEOUT=true
    if command -v setsid >/dev/null 2>&1 &&
        timeout -k 1 2 setsid sh -c 'session=$(awk "{print \$6}" /proc/$$/stat); test "$session" = "$$"'; then
        HG_MONITOR_PROBE_SETSID=true
    fi
fi
HG_MONITOR_PROBE_START="$(awk '{print $1}' /proc/uptime)"
HG_MONITOR_PROBE_MEMORY_BEFORE="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)"
hg_health_print_json >"$HG_MONITOR_PROBE_TMP/health.json"
HG_MONITOR_PROBE_HEALTH_EXIT=$?
HG_MONITOR_PROBE_END="$(awk '{print $1}' /proc/uptime)"
HG_MONITOR_PROBE_MEMORY_AFTER="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)"
HG_MONITOR_PROBE_ELAPSED="$(awk -v start="$HG_MONITOR_PROBE_START" -v end="$HG_MONITOR_PROBE_END" 'BEGIN { printf "%.2f", end-start }')"
printf 'HG_MONITOR_READINESS_V1\n'
printf '{"schema_version":1,"source_commit":%s,"capabilities":{"timeout":%s,"setsid_functional":%s},"elapsed_seconds":%s,"memory_available_before_kib":%s,"memory_available_after_kib":%s,"health_exit":%s,"health":' \
    "$(hg_json_string "$HG_MONITOR_PROBE_SOURCE")" "$HG_MONITOR_PROBE_TIMEOUT" "$HG_MONITOR_PROBE_SETSID" \
    "$(hg_json_number_or_null "$HG_MONITOR_PROBE_ELAPSED")" \
    "$(hg_json_number_or_null "$HG_MONITOR_PROBE_MEMORY_BEFORE")" \
    "$(hg_json_number_or_null "$HG_MONITOR_PROBE_MEMORY_AFTER")" "$HG_MONITOR_PROBE_HEALTH_EXIT"
if [ -s "$HG_MONITOR_PROBE_TMP/health.json" ]; then
    cat "$HG_MONITOR_PROBE_TMP/health.json"
else
    printf null
fi
printf '}\n'
# An unhealthy health result is evidence, not a failed transport.
case "$HG_MONITOR_PROBE_HEALTH_EXIT" in 0|1) exit 0 ;; *) exit "$HG_MONITOR_PROBE_HEALTH_EXIT" ;; esac
