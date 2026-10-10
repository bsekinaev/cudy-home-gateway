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

    for bin in sh awk sed grep wc date ps df curl nslookup jsonfilter uci ubus nft flock ucode ip; do
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
    hg_load_module asata
    if hg_asata_keeper check >/dev/null 2>&1; then
        hg_doctor_result OK 'ASATA UDP DIRECT' 'точное правило первым в цепочке'
    else
        hg_doctor_result FAIL 'ASATA UDP DIRECT' 'семантика или порядок правила не подтверждены'
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

hg_vtest_size_within() {
    file_size="$(stat -c %s "$1" 2>/dev/null)" || return 1
    case "$file_size" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#file_size}" -le 9 ] && [ "$file_size" -le "$2" ]
}

# Capture at most limit+1 bytes in private RAM. The extra byte detects growth
# after stat; only a complete bounded snapshot receives a fingerprint.
hg_vtest_fingerprint() (
    umask 077
    copy="$(mktemp /tmp/hg-vtest-fingerprint.XXXXXX)" || exit 1
    trap 'rm -f "$copy"' EXIT
    trap 'exit 1' INT TERM
    head -c 262145 "$1" > "$copy" 2>/dev/null || exit 1
    hg_vtest_size_within "$copy" 262144 || exit 1
    set -o pipefail
    sha256sum "$copy" | awk '{ print $1 }'
)

# Metadata only: an unaudited external vtest is never executed, even for status.
# Local path overrides support inspection/tests; Telegram cannot supply them.
hg_vtest_inspect_json() {
    vtest_path="${HG_VTEST_PATH:-/usr/bin/vtest}"
    cron_path="${HG_VTEST_CRONTAB:-/etc/crontabs/root}"
    installed=false
    executable=false
    digest=''
    scheduled=false
    audit_reason='EXTERNAL_CONTRACT_UNAUDITED'
    if [ "$vtest_path" = '/usr/bin/vtest' ] && [ -L "$vtest_path" ] &&
       [ "$(readlink "$vtest_path" 2>/dev/null)" = '/root/vless-auto.sh' ] &&
       [ ! -L /root/vless-auto.sh ]; then
        vtest_path='/root/vless-auto.sh'
    fi
    if [ -L "$vtest_path" ]; then
        audit_reason='PROVIDER_SYMLINK'
    elif [ -f "$vtest_path" ] && [ -r "$vtest_path" ]; then
        installed=true
        [ ! -x "$vtest_path" ] || executable=true
        if hg_vtest_size_within "$vtest_path" 262144; then
            if ! digest="$(hg_vtest_fingerprint "$vtest_path")"; then
                digest=''
                audit_reason='PROVIDER_UNREADABLE'
            fi
            case "$digest" in *[!0-9a-f]*|'') digest=''; audit_reason='PROVIDER_UNREADABLE';; esac
            if [ "${#digest}" -ne 64 ]; then digest=''; audit_reason='PROVIDER_UNREADABLE'; fi
        else
            audit_reason='PROVIDER_TOO_LARGE'
        fi
    else
        audit_reason='PROVIDER_MISSING'
    fi
    source_confirmed=false
    if [ "$digest" = 'cab3ffda3cdbdff192c3a91729b806c3998f2340418306ce5c4af67573fb6279' ]; then
        source_confirmed=true
        audit_reason='DEPENDENCIES_AND_CLEANUP_UNAUDITED'
    fi
    if [ -f "$cron_path" ] && [ ! -L "$cron_path" ] && [ -r "$cron_path" ] &&
       hg_vtest_size_within "$cron_path" 65536; then
        if (set -o pipefail; head -c 65536 "$cron_path" 2>/dev/null | awk 'NF >= 6 && $1 !~ /^#/ && ($6 == "/usr/bin/vtest" || $6 == "vtest") { found = 1 }
                END { exit(found ? 0 : 1) }'); then scheduled=true; fi
    fi
    printf '{"schema_version":1,"integration":"BLOCKED","state":"UNKNOWN","reason":'
    hg_json_string "$audit_reason"
    printf ',"provider":{"installed":%s,"executable":%s,"sha256":' "$installed" "$executable"
    hg_json_string_or_null "$digest"
    printf ',"source_confirmed":%s},"cron_configured":%s,' "$source_confirmed" "$scheduled"
    if [ "$source_confirmed" = true ]; then hg_vtest_results_json
    else printf '"latest":null,"history":null'; fi
    printf ',"run_supported":false}\n'
}

# Offline observations only. No external status, log tail, UCI or provider execution.
# All parsers operate on private bounded snapshots, never emit node IDs/names/errors.
hg_vtest_result_json() (
    umask 077
    input="$1"
    kind="$2"
    [ -f "$input" ] && [ ! -L "$input" ] && [ -r "$input" ] || exit 1
    hg_vtest_size_within "$input" 262144 || exit 1
    snapshot="$(mktemp /tmp/hg-vtest-result.XXXXXX)" || exit 1
    trap 'rm -f "$snapshot"' EXIT
    trap 'exit 1' INT TERM
    head -c 262145 "$input" > "$snapshot" 2>/dev/null || exit 1
    hg_vtest_size_within "$snapshot" 262144 || exit 1
    # A provider may be halfway through writing the last record.
    [ "$(tail -c 1 "$snapshot" | od -An -tu1 | tr -d ' \n')" = 10 ] || exit 1
    awk -F '\t' -v kind="$kind" -v expected="${3:-}" '
        BEGIN {
            raw="run_id\tstage\tnode_id\tname\tround\tprovider\tstatus\tcurl_rc\thttp_code\tlatency_ms\tttfb_ms\tspeed_mbps\ttotal_sec\tbytes\terror"
            summary="node_id\tname\tscore\teligible\tmedian_mbps\tmedian_latency_ms\tsuccess_rate_pct\tspread_pct\tfailures\tstalls\tprovider_good\tcapability\tchatgpt_pass\topenai_pass\thttps_pass\tloc\tsource_stage"
            capability="stage\tnode_id\tname\teligible\tgoogle_pass\tchatgpt_pass\topenai_pass\thttps_pass\tloc"
        }
        NR == 1 { if ($0 != (kind == "raw" ? raw : kind == "summary" ? summary : capability)) bad=1; next }
        {
            if (++rows > 4096 || length($0) > 4096) { bad=1; next }
            if (kind == "raw") {
                if (NF != 15 || (length($1) != 15 || $1 !~ /^[0-9]+-[0-9]+$/ || substr($1,9,1) != "-") || ($7 != "OK" && $7 != "FAIL")) bad=1
                if (expected != "" && $1 != expected) bad=1
                if (row_run != "" && $1 != row_run) bad=1
                row_run=$1
                for (i=8;i<=14;i++) if ($i !~ /^[0-9]+([.][0-9]+)?$/) bad=1
                if ($7 == "OK") success++; else failed++
            } else {
                col = 4
                if (NF != (kind == "summary" ? 17 : 9) || ($col != "YES" && $col != "NO")) bad=1
                if (kind == "summary") {
                    for (i=3;i<=15;i++) if (i != 4 && i != 12 && $i !~ /^[0-9]+([.][0-9]+)?$/) bad=1
                } else for (i=5;i<=8;i++) if ($i !~ /^[0-9]+$/) bad=1
                if ($col == "YES") eligible++
            }
        }
        END {
            if (NR == 0 || bad) exit 1
            if (kind == "raw") printf "{\"samples\":%d,\"success\":%d,\"failed\":%d}", rows, success, failed
            else printf "{\"nodes\":%d,\"eligible\":%d}", rows, eligible
        }
    ' "$snapshot"
)

hg_vtest_results_json() {
    result_dir="${HG_VTEST_RESULTS_DIR:-/root/vless-auto}"
    # Directory symlinks are intentionally refused; the provider symlink is unrelated.
    if [ ! -d "$result_dir" ] || [ -L "$result_dir" ]; then
        printf '"latest":null,"history":null'
        return
    fi
    raw_json="$(hg_vtest_result_json "$result_dir/latest.tsv" raw)" || raw_json=null
    summary_json="$(hg_vtest_result_json "$result_dir/latest-summary.tsv" summary)" || summary_json=null
    cap_json="$(hg_vtest_result_json "$result_dir/latest-capability.tsv" capability)" || cap_json=null
    printf '"latest":{"speed":%s,"summary":%s,"capability":%s},"history":' "$raw_json" "$summary_json" "$cap_json"
    hg_vtest_history_json "$result_dir/history" || printf null
}

hg_vtest_history_json() (
    umask 077
    [ -d "$1" ] && [ ! -L "$1" ] || exit 1
    listing="$(mktemp /tmp/hg-vtest-history.XXXXXX)" || exit 1
    trap 'rm -f "$listing"' EXIT
    trap 'exit 1' INT TERM
    # Bounded directory capture; fail closed if the history exceeds its budget.
    set -o pipefail
    timeout 2 find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | head -c 8193 > "$listing" || exit 1
    hg_vtest_size_within "$listing" 8192 || exit 1
    # Fixed numeric basenames prevent path/JSON injection. Preserve no node metadata.
    ids="$(sed 's|.*/||' "$listing" | awk '/^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9][.]tsv$/ {sub(/[.]tsv$/, "");print}' | sort -r | head -n 20)" || exit 1
    out='['
    separator=''
    for id in $ids; do
        result="$(hg_vtest_result_json "$1/$id.tsv" raw "$id")" || result=null
        out="$out$separator{\"run_id\":\"$id\",\"speed\":$result}"
        separator=','
    done
    printf '%s]' "$out"
)
