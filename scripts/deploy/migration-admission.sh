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
scope=default
case "${1:-}" in
    --receiver-recover) scope=recover; shift;;
    --telegram-start) scope=telegram; shift;;
esac
[ "$#" -eq 0 ] || exit 64
refuse() { printf 'MIGRATION_ADMISSION=BLOCKED\n' >&2; exit 73; }
BASE="$ROOT/etc/home-gateway-migration"
FENCE="$ROOT/tmp/home-gateway-deploy.lock"
# A symlink migration fence is never a recoverable receiver PID lease.
# Missing state means no migration has been admitted. Missing phase in existing
# state is ambiguous and must not reopen admission after crash/reboot.
if [ ! -e "$BASE" ] && [ ! -L "$BASE" ]; then
    [ ! -e "$FENCE" ] && [ ! -L "$FENCE" ] || refuse
    exit 0
fi
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
    else [ -f "$path" ] && [ "$(stat -c %h "$path")" = 1 ] && [ "$(stat -c %s "$path")" -le "${4:-128}" ] || refuse
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
lease=0
if [ -e "$FENCE" ] || [ -L "$FENCE" ]; then
    [ "$scope" != default ] || refuse
    safe "$FENCE" dir 700
    safe "$FENCE/pid" file 600 16
    pid=$(cat "$FENCE/pid")
    printf '%s' "$pid" | grep -Eq '^[1-9][0-9]{0,9}$' || refuse
    [ "$(stat -c %s "$FENCE/pid")" -eq "$((${#pid} + 1))" ] &&
        [ "$(wc -l < "$FENCE/pid")" -eq 1 ] || refuse
    lease=1
    # Recovery itself validates PID liveness and owns any eventual cleanup.
    # This read-only helper never removes a stale lease or signals its owner.
fi
if [ "$scope" = telegram ]; then
    DEPLOY="$ROOT/etc/home-gateway-deploy"
    if [ -e "$DEPLOY/active" ] || [ -L "$DEPLOY/active" ]; then
        safe "$DEPLOY" dir 700
        safe "$DEPLOY/active" file 600 40
        tx=$(cat "$DEPLOY/active")
        printf '%s' "$tx" | grep -Eq '^tx\.[a-zA-Z0-9]{1,32}$' || refuse
        [ "$(stat -c %s "$DEPLOY/active")" -eq "$((${#tx} + 1))" ] &&
            [ "$(wc -l < "$DEPLOY/active")" -eq 1 ] || refuse
        TX="$DEPLOY/$tx"
        safe "$TX" dir 700
        safe "$TX/phase" file 600 16
        stage=$(cat "$TX/phase")
        [ "$(stat -c %s "$TX/phase")" -eq "$((${#stage} + 1))" ] &&
            [ "$(wc -l < "$TX/phase")" -eq 1 ] || refuse
        case "$stage" in CHECKING|COMMITTED) manifest=new.sha256;; RESTORED) manifest=backup.sha256;; *) refuse;; esac
        safe "$TX/inventory-version" file 600 10
        [ "$(cat "$TX/inventory-version")" = HGDEPLOY2 ] &&
            [ "$(stat -c %s "$TX/inventory-version")" -eq 10 ] &&
            [ "$(wc -l < "$TX/inventory-version")" -eq 1 ] || refuse
        safe "$TX/$manifest" file 600 8192
        runtime_files() {
            cat <<'INVENTORY'
etc/init.d/home-gateway-telegram
usr/bin/gateway
usr/bin/home-gateway-ci-smoke
usr/lib/home-gateway/actions.uc
usr/lib/home-gateway/asata.sh
usr/lib/home-gateway/common.sh
usr/lib/home-gateway/dns.sh
usr/lib/home-gateway/doctor.sh
usr/lib/home-gateway/health.sh
usr/lib/home-gateway/incidents.uc
usr/lib/home-gateway/network.sh
usr/lib/home-gateway/notifications.uc
usr/lib/home-gateway/redmi.sh
usr/lib/home-gateway/selftest.sh
usr/lib/home-gateway/status.sh
usr/lib/home-gateway/tailscale.sh
usr/lib/home-gateway/telegram-poller.uc
usr/lib/home-gateway/telegram.sh
usr/lib/home-gateway/torrent.sh
usr/lib/home-gateway/vpn.sh
INVENTORY
        }
        awk -v expected="$(runtime_files)" '
        BEGIN {n=split(expected,p,"\n");for(i=1;i<=n;i++)wanted[p[i]]=1}
        {digest=substr($0,1,64);rel=substr($0,67);
         if(length(digest)!=64 || digest~/[^0-9a-f]/ || substr($0,65,2)!="  " || !wanted[rel] || seen[rel]++)bad=1}
        END {if(bad || NR!=n)exit 1}' "$TX/$manifest" || refuse
        for rel in $(runtime_files); do
            case "$rel" in etc/init.d/*|usr/bin/*) bits=755;; *) bits=644;; esac
            safe "$ROOT/$rel" file "$bits" 262144
        done
        (cd "$ROOT/" && sha256sum -c "$TX/$manifest" >/dev/null 2>&1) || refuse
        if [ "$lease" = 1 ]; then kill -0 "$pid" 2>/dev/null || refuse; fi
    else
        [ "$lease" = 0 ] || refuse
    fi
fi
printf 'MIGRATION_ADMISSION=ADMITTED\n'
