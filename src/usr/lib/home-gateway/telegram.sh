#!/bin/sh
# Telegram Bot API transport для CUDY Home Gateway.
# Token читается только из локального файла и не передаётся в argv curl.

hg_telegram_token_file() {
    printf '%s' "${HG_TELEGRAM_TOKEN_FILE:-/etc/home-gateway/secrets/telegram.token}"
}

hg_telegram_proxy() {
    printf '%s' "${HG_TELEGRAM_PROXY:-127.0.0.1:1082}"
}

hg_telegram_read_token() {
    token_file="$(hg_telegram_token_file)"

    if [ ! -r "$token_file" ]; then
        hg_error "Telegram token недоступен: $token_file"
        return "$HG_EXIT_SOFTWARE"
    fi

    IFS= read -r token <"$token_file" || true

    case "$token" in
        ''|*[!0-9A-Za-z:_-]*)
            hg_error 'Telegram token имеет некорректный формат'
            return "$HG_EXIT_SOFTWARE"
            ;;
        *:*)
            ;;
        *)
            hg_error 'Telegram token имеет некорректный формат'
            return "$HG_EXIT_SOFTWARE"
            ;;
    esac

    printf '%s' "$token"
}

hg_telegram_api_request() {
    method="${1:-}"
    max_time="${2:-10}"
    shift 2

    case "$method" in
        ''|*[!0-9A-Za-z_]*)
            hg_error 'некорректный Telegram API method'
            return "$HG_EXIT_USAGE"
            ;;
    esac

    case "$max_time" in
        ''|*[!0-9]*)
            hg_error 'некорректный timeout Telegram API'
            return "$HG_EXIT_USAGE"
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        hg_error 'curl не найден'
        return "$HG_EXIT_SOFTWARE"
    fi

    token="$(hg_telegram_read_token)" || return $?
    proxy="$(hg_telegram_proxy)"

    # URL с token передаётся curl через stdin config, поэтому token не виден в ps/argv.
    curl \
        --silent \
        --show-error \
        --fail-with-body \
        --socks5-hostname "$proxy" \
        --connect-timeout 5 \
        --max-time "$max_time" \
        --config - \
        "$@" <<EOF_CURL
url = "https://api.telegram.org/bot${token}/${method}"
EOF_CURL
}

hg_telegram_get_me() {
    hg_telegram_api_request getMe 10
}

hg_telegram_get_updates() {
    offset="${1:-}"
    timeout="${2:-0}"

    case "$offset" in
        ''|*[!0-9]*)
            if [ -n "$offset" ]; then
                hg_error 'offset должен быть неотрицательным целым'
                return "$HG_EXIT_USAGE"
            fi
            ;;
    esac

    case "$timeout" in
        ''|*[!0-9]*)
            hg_error 'timeout должен быть целым от 0 до 50'
            return "$HG_EXIT_USAGE"
            ;;
    esac

    if [ "$timeout" -gt 50 ]; then
        hg_error 'timeout должен быть целым от 0 до 50'
        return "$HG_EXIT_USAGE"
    fi

    max_time=$((timeout + 5))

    if [ -n "$offset" ]; then
        hg_telegram_api_request getUpdates "$max_time" \
            --request POST \
            --data-urlencode "offset=$offset" \
            --data-urlencode "timeout=$timeout"
    else
        hg_telegram_api_request getUpdates "$max_time" \
            --request POST \
            --data-urlencode "timeout=$timeout"
    fi
}

# Внутренний transport primitive. Не экспортируется отдельной CLI-командой,
# но понадобится dashboard/poller для ответов пользователю.
hg_telegram_send_message() {
    chat_id="${1:-}"
    text="${2:-}"

    case "$chat_id" in
        ''|*[!0-9-]*)
            hg_error 'некорректный Telegram chat_id'
            return "$HG_EXIT_USAGE"
            ;;
    esac

    [ -n "$text" ] || {
        hg_error 'пустой Telegram message'
        return "$HG_EXIT_USAGE"
    }

    hg_telegram_api_request sendMessage 10 \
        --request POST \
        --data-urlencode "chat_id=$chat_id" \
        --data-urlencode "text=$text"
}
