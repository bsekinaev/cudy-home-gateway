#!/bin/sh
# Self-test установки CUDY Home Gateway.
# Проверяет только сам Gateway CLI и его локальный контракт, не состояние сети.

HG_SELFTEST_PASS=0
HG_SELFTEST_FAIL=0

hg_selftest_result() {
    state="$1"
    name="$2"
    detail="${3:-}"

    case "$state" in
        PASS)
            HG_SELFTEST_PASS=$((HG_SELFTEST_PASS + 1))
            ;;
        FAIL)
            HG_SELFTEST_FAIL=$((HG_SELFTEST_FAIL + 1))
            ;;
        *)
            state='FAIL'
            HG_SELFTEST_FAIL=$((HG_SELFTEST_FAIL + 1))
            ;;
    esac

    if [ -n "$detail" ]; then
        printf '[%-4s] %s — %s\n' "$state" "$name" "$detail"
    else
        printf '[%-4s] %s\n' "$state" "$name"
    fi
}

hg_selftest_readable() {
    name="$1"
    path="$2"

    if [ -r "$path" ]; then
        hg_selftest_result PASS "$name" "$path"
    else
        hg_selftest_result FAIL "$name" "не читается: $path"
    fi
}

hg_selftest_executable() {
    name="$1"
    path="$2"

    if [ -x "$path" ]; then
        hg_selftest_result PASS "$name" "$path"
    else
        hg_selftest_result FAIL "$name" "не исполняется: $path"
    fi
}

hg_selftest_service_contract() {
    path="$1"

    if [ ! -r "$path" ]; then
        hg_selftest_result FAIL 'Telegram service contract' "файл недоступен: $path"
        return 0
    fi

    if grep -q '^USE_PROCD=1$' "$path" 2>/dev/null &&
       grep -q 'procd_set_param command' "$path" 2>/dev/null &&
       grep -q 'procd_set_param respawn' "$path" 2>/dev/null; then
        hg_selftest_result PASS 'Telegram service contract' 'procd command/respawn объявлены'
    else
        hg_selftest_result FAIL 'Telegram service contract' 'неполный procd contract'
    fi
}

hg_selftest_syntax() {
    name="$1"
    path="$2"

    if [ ! -r "$path" ]; then
        hg_selftest_result FAIL "$name" "файл недоступен: $path"
        return 0
    fi

    if sh -n "$path" >/dev/null 2>&1; then
        hg_selftest_result PASS "$name" 'shell-синтаксис корректен'
    else
        hg_selftest_result FAIL "$name" 'ошибка shell-синтаксиса'
    fi
}

hg_selftest_ucode_syntax() {
    name="$1"
    path="$2"
    tmp_file="/tmp/home-gateway-ucode-selftest.$$.out"

    if [ ! -r "$path" ]; then
        hg_selftest_result FAIL "$name" "файл недоступен: $path"
        return 0
    fi

    if ! command -v ucode >/dev/null 2>&1; then
        hg_selftest_result FAIL "$name" 'ucode не найден'
        return 0
    fi

    if ucode -c -o "$tmp_file" "$path" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        hg_selftest_result PASS "$name" 'ucode-синтаксис корректен'
    else
        rm -f "$tmp_file"
        hg_selftest_result FAIL "$name" 'ошибка ucode-синтаксиса'
    fi
}

hg_selftest_incidents_engine() {
    path="$1"
    entrypoint="$2"
    tmp_file="/tmp/home-gateway-incidents-selftest.$$.out"

    if [ ! -r "$path" ]; then
        hg_selftest_result FAIL 'Incident Engine selftest' "файл недоступен: $path"
        return 0
    fi

    if ! command -v ucode >/dev/null 2>&1; then
        hg_selftest_result FAIL 'Incident Engine selftest' 'ucode не найден'
        return 0
    fi

    if ucode "$path" "$entrypoint" selftest >"$tmp_file" 2>&1; then
        rm -f "$tmp_file"
        hg_selftest_result PASS 'Incident Engine selftest' 'debounce/hysteresis contract'
    else
        detail="$(tail -n 1 "$tmp_file" 2>/dev/null || true)"
        rm -f "$tmp_file"
        hg_selftest_result FAIL 'Incident Engine selftest' "${detail:-state machine test failed}"
    fi
}

hg_selftest_api() {
    name="$1"
    function_name="$2"

    if command -v "$function_name" >/dev/null 2>&1; then
        hg_selftest_result PASS "$name" "$function_name"
    else
        hg_selftest_result FAIL "$name" "нет функции: $function_name"
    fi
}

hg_selftest_telegram_validation() {
    if hg_telegram_validate_chat_id '123456789' >/dev/null 2>&1 &&
       hg_telegram_validate_chat_id '-100123456789' >/dev/null 2>&1 &&
       ! hg_telegram_validate_chat_id '12-34' >/dev/null 2>&1 &&
       ! hg_telegram_validate_chat_id '--123' >/dev/null 2>&1 &&
       ! hg_telegram_validate_chat_id 'abc' >/dev/null 2>&1 &&
       hg_telegram_validate_message_id '42' >/dev/null 2>&1 &&
       ! hg_telegram_validate_message_id '4-2' >/dev/null 2>&1; then
        hg_selftest_result PASS 'Telegram ID validation' 'chat_id/message_id contract'
    else
        hg_selftest_result FAIL 'Telegram ID validation' 'validation contract нарушен'
    fi
}

hg_selftest_json_contract() {
    tmp_file="/tmp/home-gateway-selftest.$$.json"

    if ! command -v jsonfilter >/dev/null 2>&1; then
        hg_selftest_result FAIL 'Status JSON contract' 'jsonfilter не найден'
        return 0
    fi

    if ! hg_status_print_json >"$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        hg_selftest_result FAIL 'Status JSON contract' 'status --json завершился ошибкой'
        return 0
    fi

    schema_version="$(jsonfilter -i "$tmp_file" -e '@.schema_version' 2>/dev/null || true)"
    gateway_version="$(jsonfilter -i "$tmp_file" -e '@.gateway_version' 2>/dev/null || true)"
    rm -f "$tmp_file"

    if [ "$schema_version" = '1' ] && [ "$gateway_version" = "$HG_VERSION" ]; then
        hg_selftest_result PASS 'Status JSON contract' "schema=1, version=$gateway_version"
    else
        hg_selftest_result FAIL 'Status JSON contract'             "schema=${schema_version:-missing}, version=${gateway_version:-missing}"
    fi
}

hg_selftest_run() {
    entrypoint="${1:-}"
    common_module="${HG_LIBDIR}/common.sh"
    status_module="${HG_LIBDIR}/status.sh"
    health_module="${HG_LIBDIR}/health.sh"
    incidents_engine="${HG_LIBDIR}/incidents.uc"
    network_module="${HG_LIBDIR}/network.sh"
    vpn_module="${HG_LIBDIR}/vpn.sh"
    dns_module="${HG_LIBDIR}/dns.sh"
    torrent_module="${HG_LIBDIR}/torrent.sh"
    redmi_module="${HG_LIBDIR}/redmi.sh"
    asata_module="${HG_LIBDIR}/asata.sh"
    tailscale_module="${HG_LIBDIR}/tailscale.sh"
    telegram_module="${HG_LIBDIR}/telegram.sh"
    telegram_poller="${HG_LIBDIR}/telegram-poller.uc"
    telegram_service="${HG_TELEGRAM_SERVICE:-/etc/init.d/home-gateway-telegram}"
    doctor_module="${HG_LIBDIR}/doctor.sh"
    selftest_module="${HG_LIBDIR}/selftest.sh"

    HG_SELFTEST_PASS=0
    HG_SELFTEST_FAIL=0

    printf '%s — selftest\n\n' "$HG_NAME"

    if [ -n "$entrypoint" ]; then
        hg_selftest_readable 'CLI entrypoint' "$entrypoint"
    else
        hg_selftest_result FAIL 'CLI entrypoint' 'путь не определён'
    fi

    hg_selftest_readable 'common.sh' "$common_module"
    hg_selftest_readable 'status.sh' "$status_module"
    hg_selftest_readable 'health.sh' "$health_module"
    hg_selftest_readable 'incidents.uc' "$incidents_engine"
    hg_selftest_readable 'network.sh' "$network_module"
    hg_selftest_readable 'vpn.sh' "$vpn_module"
    hg_selftest_readable 'dns.sh' "$dns_module"
    hg_selftest_readable 'torrent.sh' "$torrent_module"
    hg_selftest_readable 'redmi.sh' "$redmi_module"
    hg_selftest_readable 'asata.sh' "$asata_module"
    hg_selftest_readable 'tailscale.sh' "$tailscale_module"
    hg_selftest_readable 'telegram.sh' "$telegram_module"
    hg_selftest_readable 'telegram-poller.uc' "$telegram_poller"
    hg_selftest_readable 'Telegram procd service' "$telegram_service"
    hg_selftest_executable 'Telegram procd service executable' "$telegram_service"
    hg_selftest_readable 'doctor.sh' "$doctor_module"
    hg_selftest_readable 'selftest.sh' "$selftest_module"

    [ -n "$entrypoint" ] && hg_selftest_syntax 'CLI syntax' "$entrypoint"
    hg_selftest_syntax 'common.sh syntax' "$common_module"
    hg_selftest_syntax 'status.sh syntax' "$status_module"
    hg_selftest_syntax 'health.sh syntax' "$health_module"
    hg_selftest_ucode_syntax 'incidents.uc syntax' "$incidents_engine"
    hg_selftest_incidents_engine "$incidents_engine" "$entrypoint"
    hg_selftest_syntax 'network.sh syntax' "$network_module"
    hg_selftest_syntax 'vpn.sh syntax' "$vpn_module"
    hg_selftest_syntax 'dns.sh syntax' "$dns_module"
    hg_selftest_syntax 'torrent.sh syntax' "$torrent_module"
    hg_selftest_syntax 'redmi.sh syntax' "$redmi_module"
    hg_selftest_syntax 'asata.sh syntax' "$asata_module"
    hg_selftest_syntax 'tailscale.sh syntax' "$tailscale_module"
    hg_selftest_syntax 'telegram.sh syntax' "$telegram_module"
    hg_selftest_ucode_syntax 'telegram-poller.uc syntax' "$telegram_poller"
    hg_selftest_syntax 'Telegram procd service syntax' "$telegram_service"
    hg_selftest_service_contract "$telegram_service"
    hg_selftest_syntax 'doctor.sh syntax' "$doctor_module"
    hg_selftest_syntax 'selftest.sh syntax' "$selftest_module"

    # Загружаем публичные read-only модули и проверяем их ожидаемый API.
    if hg_load_module status >/dev/null 2>&1; then
        hg_selftest_api 'Status API' 'hg_status_print'
        hg_selftest_api 'Status JSON API' 'hg_status_print_json'
        hg_selftest_json_contract
    else
        hg_selftest_result FAIL 'Status API' 'модуль status не загружается'
        hg_selftest_result FAIL 'Status JSON API' 'модуль status не загружается'
        hg_selftest_result FAIL 'Status JSON contract' 'модуль status не загружается'
    fi

    if hg_load_module health >/dev/null 2>&1; then
        hg_selftest_api 'Health collect API' 'hg_health_collect'
        hg_selftest_api 'Health human API' 'hg_health_print'
        hg_selftest_api 'Health JSON API' 'hg_health_print_json'
    else
        hg_selftest_result FAIL 'Health collect API' 'модуль health не загружается'
        hg_selftest_result FAIL 'Health human API' 'модуль health не загружается'
        hg_selftest_result FAIL 'Health JSON API' 'модуль health не загружается'
    fi

    if hg_load_module network >/dev/null 2>&1; then
        hg_selftest_api 'Network API' 'hg_network_collect'
    else
        hg_selftest_result FAIL 'Network API' 'модуль network не загружается'
    fi

    if hg_load_module vpn >/dev/null 2>&1; then
        hg_selftest_api 'VPN API' 'hg_vpn_collect'
    else
        hg_selftest_result FAIL 'VPN API' 'модуль vpn не загружается'
    fi

    if hg_load_module dns >/dev/null 2>&1; then
        hg_selftest_api 'DNS API' 'hg_dns_collect'
    else
        hg_selftest_result FAIL 'DNS API' 'модуль dns не загружается'
    fi

    if hg_load_module torrent >/dev/null 2>&1; then
        hg_selftest_api 'Torrent API' 'hg_torrent_collect'
    else
        hg_selftest_result FAIL 'Torrent API' 'модуль torrent не загружается'
    fi

    if hg_load_module redmi >/dev/null 2>&1; then
        hg_selftest_api 'Redmi API' 'hg_redmi_collect'
    else
        hg_selftest_result FAIL 'Redmi API' 'модуль redmi не загружается'
    fi

    if hg_load_module asata >/dev/null 2>&1; then
        hg_selftest_api 'ASATA API' 'hg_asata_collect'
    else
        hg_selftest_result FAIL 'ASATA API' 'модуль asata не загружается'
    fi

    if hg_load_module tailscale >/dev/null 2>&1; then
        hg_selftest_api 'Tailscale API' 'hg_tailscale_collect'
    else
        hg_selftest_result FAIL 'Tailscale API' 'модуль tailscale не загружается'
    fi

    if hg_load_module telegram >/dev/null 2>&1; then
        hg_selftest_api 'Telegram getMe API' 'hg_telegram_get_me'
        hg_selftest_api 'Telegram getUpdates API' 'hg_telegram_get_updates'
        hg_selftest_api 'Telegram sendMessage API' 'hg_telegram_send_message'
        hg_selftest_api 'Telegram editMessage API' 'hg_telegram_edit_message'
        hg_selftest_api 'Telegram answerCallback API' 'hg_telegram_answer_callback'
        hg_selftest_telegram_validation
    else
        hg_selftest_result FAIL 'Telegram getMe API' 'модуль telegram не загружается'
        hg_selftest_result FAIL 'Telegram getUpdates API' 'модуль telegram не загружается'
        hg_selftest_result FAIL 'Telegram sendMessage API' 'модуль telegram не загружается'
        hg_selftest_result FAIL 'Telegram editMessage API' 'модуль telegram не загружается'
        hg_selftest_result FAIL 'Telegram answerCallback API' 'модуль telegram не загружается'
        hg_selftest_result FAIL 'Telegram ID validation' 'модуль telegram не загружается'
    fi

    if hg_load_module doctor >/dev/null 2>&1; then
        hg_selftest_api 'Doctor API' 'hg_doctor_run'
    else
        hg_selftest_result FAIL 'Doctor API' 'модуль doctor не загружается'
    fi

    case "$HG_VERSION" in
        ''|*[!0-9A-Za-z._-]*)
            hg_selftest_result FAIL 'Gateway version' "некорректное значение: ${HG_VERSION:-empty}"
            ;;
        *)
            hg_selftest_result PASS 'Gateway version' "$HG_VERSION"
            ;;
    esac

    printf '\nИтог: PASS=%s FAIL=%s\n' "$HG_SELFTEST_PASS" "$HG_SELFTEST_FAIL"

    if [ "$HG_SELFTEST_FAIL" -gt 0 ]; then
        printf 'Результат: FAIL\n'
        return "$HG_EXIT_UNHEALTHY"
    fi

    printf 'Результат: PASS\n'
    return 0
}
