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

hg_selftest_api() {
    name="$1"
    function_name="$2"

    if command -v "$function_name" >/dev/null 2>&1; then
        hg_selftest_result PASS "$name" "$function_name"
    else
        hg_selftest_result FAIL "$name" "нет функции: $function_name"
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
    network_module="${HG_LIBDIR}/network.sh"
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
    hg_selftest_readable 'network.sh' "$network_module"
    hg_selftest_readable 'doctor.sh' "$doctor_module"
    hg_selftest_readable 'selftest.sh' "$selftest_module"

    [ -n "$entrypoint" ] && hg_selftest_syntax 'CLI syntax' "$entrypoint"
    hg_selftest_syntax 'common.sh syntax' "$common_module"
    hg_selftest_syntax 'status.sh syntax' "$status_module"
    hg_selftest_syntax 'network.sh syntax' "$network_module"
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

    if hg_load_module network >/dev/null 2>&1; then
        hg_selftest_api 'Network API' 'hg_network_collect'
    else
        hg_selftest_result FAIL 'Network API' 'модуль network не загружается'
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
