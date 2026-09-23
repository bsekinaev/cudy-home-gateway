#!/bin/sh
# Never eval or execute SSH_ORIGINAL_COMMAND. No SFTP/SCP or interactive shell.
set -eu
set -f
IFS=' '
set -- ${SSH_ORIGINAL_COMMAND:-}
case "${1:-}" in
    plan|apply) [ "$#" -eq 3 ] || exit 64;;
    status|recover|rollback) [ "$#" -eq 1 ] || exit 64;;
    *) exit 64;;
esac
exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    /bin/sh /usr/libexec/home-gateway-deploy/engine.sh "$@"
