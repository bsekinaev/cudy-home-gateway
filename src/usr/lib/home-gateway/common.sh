#!/bin/sh
# Общие функции CUDY Home Gateway.

HG_NAME='CUDY Home Gateway'
HG_VERSION='0.3.0-dev'
HG_EXIT_UNHEALTHY=1
HG_EXIT_USAGE=2
HG_EXIT_SOFTWARE=70

hg_error() {
    printf '%s: %s\n' 'gateway' "$*" >&2
}

hg_print_version() {
    printf '%s %s\n' "$HG_NAME" "$HG_VERSION"
}

hg_load_module() {
    module="$1"
    module_path="${HG_LIBDIR}/${module}.sh"

    if [ ! -r "$module_path" ]; then
        hg_error "не найден модуль: $module_path"
        return "$HG_EXIT_SOFTWARE"
    fi

    # shellcheck source=/dev/null
    . "$module_path"
}

hg_json_string() {
    value="$1"

    printf '%s' "$value" | awk '
        BEGIN { printf "\"" }
        {
            if (NR > 1) {
                printf "\\n"
            }
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "\\")
                    printf "\\\\"
                else if (c == "\"")
                    printf "\\\""
                else if (c == "\t")
                    printf "\\t"
                else if (c == "\r")
                    printf "\\r"
                else
                    printf "%s", c
            }
        }
        END { printf "\"" }
    '
}

hg_json_number_or_null() {
    value="$1"

    if awk -v value="$value" 'BEGIN { exit(value ~ /^-?[0-9]+([.][0-9]+)?$/ ? 0 : 1) }'; then
        printf '%s' "$value"
    else
        printf 'null'
    fi
}

hg_json_string_or_null() {
    value="${1:-}"

    if [ -n "$value" ]; then
        hg_json_string "$value"
    else
        printf 'null'
    fi
}
