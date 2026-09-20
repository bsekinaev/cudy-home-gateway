#!/bin/sh
# Общие функции CUDY Home Gateway.

HG_NAME='CUDY Home Gateway'
HG_VERSION='0.2.0-dev'
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
