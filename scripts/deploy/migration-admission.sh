#!/bin/sh
# Read-only persistent admission boundary. Installed only by a future verified
# migration coordinator; this file alone does not perform or authorize migration.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=
if [ "${1:-}" = --test-root ]; then
    ROOT=${2:-}
    case "$ROOT" in /*) ;; *) exit 64;; esac
    [ "$ROOT" != / ] && [ -f "$ROOT/.hg-deploy-test-root" ] || exit 64
    shift 2
fi
[ "$#" -eq 0 ] || exit 64
refuse() { printf 'MIGRATION_ADMISSION=BLOCKED\n' >&2; exit 73; }
BASE="$ROOT/etc/home-gateway-migration"
FENCE="$ROOT/tmp/home-gateway-deploy.lock"
# A RAM fence of any identity is busy, including a dangling symlink. Never clean it.
[ ! -e "$FENCE" ] && [ ! -L "$FENCE" ] || refuse
# Missing state means no migration has been admitted. Missing phase in existing
# state is ambiguous and must not reopen admission after crash/reboot.
[ -e "$BASE" ] || [ -L "$BASE" ] || exit 0
owner=0; group=0
if [ -n "$ROOT" ]; then owner=$(id -u); group=$(id -g); fi
safe() {
    path=$1; kind=$2; mode=$3
    component=$path
    while [ "$component" != / ] && [ -n "$component" ]; do
        [ ! -L "$component" ] || refuse
        if [ "$component" != "$path" ]; then
            [ -d "$component" ] || refuse
            uid=$(stat -c %u "$component")
            [ "$uid" = 0 ] || [ "$uid" = "$owner" ] || refuse
            bits=$(stat -c %a "$component")
            [ "$((0$bits & 022))" = 0 ] || [ "$((0$bits & 01000))" != 0 ] || refuse
        fi
        component=${component%/*}
    done
    [ "$(stat -c '%u:%g:%a' "$path" 2>/dev/null)" = "$owner:$group:$mode" ] || refuse
    if [ "$kind" = dir ]; then [ -d "$path" ] || refuse
    else [ -f "$path" ] && [ "$(stat -c %h "$path")" = 1 ] && [ "$(stat -c %s "$path")" -le 128 ] || refuse
    fi
}
safe "$BASE" dir 700
safe "$BASE/phase" file 600
phase=$(cat "$BASE/phase")
case "$phase" in COMMITTED|ROLLED_BACK) ;; *) refuse;; esac
[ "$(stat -c %s "$BASE/phase")" -eq "$((${#phase} + 1))" ] &&
    [ "$(wc -l < "$BASE/phase")" -eq 1 ] || refuse
# The coordinator publishes this only after exact runtime/receiver/latest
# verification and durability barriers. An interrupted or mismatched receipt
# stays blocked even if a terminal phase rename has already occurred.
safe "$BASE/admission" file 600
expected="HG_MIGRATION_ADMITTED_V1 $phase"
[ "$(cat "$BASE/admission")" = "$expected" ] &&
    [ "$(stat -c %s "$BASE/admission")" -eq "$((${#expected} + 1))" ] &&
    [ "$(wc -l < "$BASE/admission")" -eq 1 ] || refuse
printf 'MIGRATION_ADMISSION=ADMITTED\n'
