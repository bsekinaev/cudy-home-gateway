#!/bin/sh
# Owner-executed stages only. Download/check never starts Apply.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
trap 'echo RC_B_INTERRUPTED=EXPLICIT_ROLLBACK_REQUIRED >&2; exit 75' HUP INT TERM
KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
op=${1:-};pin=${2:-};nonce=${3:-};confirm=${4:-}
case "$op" in preflight|prepare|apply|verify|rollback|check|retire|retire-check) ;; *) echo RC_B_REFUSED_STAGE >&2;exit 64;; esac
for tool in ucode timeout sha256sum stat ubus;do command -v "$tool" >/dev/null 2>&1 || { echo "RC_B_PREFLIGHT_REFUSED=MISSING_$tool" >&2;exit 69; };done
/bin/busybox fsync --help >/dev/null 2>&1
/bin/busybox flock --help >/dev/null 2>&1
report=$(/usr/bin/env -i PATH="$PATH" /usr/bin/ucode "$KIT/rc-b.uc" "$KIT" check "$pin")
printf '%s\n' "$report"
profile=$(printf '%s\n' "$report" | sed -n 's/^RC_B_PACKAGE=VERIFIED SOURCE=[0-9a-f]\{40\} PROFILE=\([A-Z_]*\)$/\1/p')
source=$(printf '%s\n' "$report" | sed -n 's/^RC_B_PACKAGE=VERIFIED SOURCE=\([0-9a-f]\{40\}\) PROFILE=.*$/\1/p')
[ "${#source}" = 40 ] || exit 73
[ "$op" != check ] || exit 0
if [ "$op" = preflight ];then
 archived=0
 for path in /etc/home-gateway-migration.retired.*;do if [ -e "$path" ] || [ -L "$path" ];then archived=1;fi;done
 if [ "$archived" = 0 ];then exec /usr/bin/env -i PATH="$PATH" /usr/bin/ucode "$KIT/rc-b.uc" "$KIT" preflight "$pin";fi
fi
if [ "$op" = prepare ];then
 /bin/sh "$KIT/rc-b.sh" preflight "$pin"
 guard=/etc/home-gateway-migration.lock
 if [ ! -e "$guard" ] && [ ! -L "$guard" ];then
  (set -C;: > "$guard") || exit 73
  /bin/busybox fsync "$guard" /etc
 fi
fi
guard=/etc/home-gateway-migration.lock
[ -f "$guard" ] && [ ! -L "$guard" ] && [ "$(stat -c '%u:%g:%a:%h:%s' "$guard")" = 0:0:600:1:0 ] || { echo RC_B_REFUSED_GUARD >&2;exit 73; }
before=$(stat -c '%d:%i' "$guard")
exec 8< "$guard"
[ "$(stat -Lc '%d:%i' /proc/self/fd/8)" = "$before" ] && /bin/busybox flock -n 8 && [ "$(stat -c '%d:%i' "$guard")" = "$before" ] || { echo RC_B_BUSY >&2;exit 73; }
if [ "$op" = preflight ];then exec /usr/bin/env -i PATH="$PATH" /usr/bin/ucode "$KIT/rc-b.uc" "$KIT" preflight "$pin";fi
native() { /usr/bin/env -i PATH="$PATH" /usr/bin/ucode "$KIT/rc-b.uc" "$KIT" "$1" "$pin" "$nonce"; }
if [ "$op" = prepare ];then
 /usr/bin/env -i PATH="$PATH" /usr/bin/ucode "$KIT/rc-b.uc" "$KIT" prepare "$pin"
 exit 0
fi
case "$nonce" in ''|*[!0-9a-f-]*) echo RC_B_REFUSED_TRANSACTION >&2;exit 64;; esac
[ "${#nonce}" = 36 ] || exit 64
if [ "$op" = verify ];then native verify;exit 0;fi
if [ "$op" = retire-check ];then native retire-check;exit 0;fi
if [ "$op" = retire ];then
 [ "$confirm" = "retire:$source:$nonce" ] || { echo RC_B_REFUSED_RETIRE_CONFIRMATION >&2;exit 73; }
 native retire
 exit 0
fi
if [ "$op" = apply ];then
 [ "$confirm" = "$source:$nonce" ] || { echo RC_B_REFUSED_EXPLICIT_CONFIRMATION >&2;exit 73; }
 report=$(native apply)
else
 report=$(native rollback)
fi
printf '%s\n' "$report"
start=$(printf '%s\n' "$report" | sed -n 's/^RC_B_STAGE=.* SERVICE_START=\([A-Z]*\) FINISH=.*$/\1/p')
finish=$(printf '%s\n' "$report" | sed -n 's/^RC_B_STAGE=.* FINISH=\([A-Z]*\)$/\1/p')
case "$start" in
 CANDIDATE) /usr/bin/env -i PATH="$PATH" HG_MIGRATION_SERVICE_HANDOFF=1 timeout -k 2 30 /etc/init.d/home-gateway-telegram start ;;
 LEGACY) /usr/bin/env -i PATH="$PATH" timeout -k 2 30 /etc/init.d/home-gateway-telegram start ;;
 NONE) :;;
 *) echo RC_B_REFUSED_SERVICE_RESULT >&2;exit 73;;
esac
if [ "$start" != NONE ];then
 ready=0
 for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15;do
  if native service >/dev/null 2>&1;then ready=1;break;fi
  sleep 1
 done
 [ "$ready" = 1 ] || { echo RC_B_SERVICE_FAILED_EXPLICIT_ROLLBACK_REQUIRED >&2;exit 73; }
fi
# Actual Gateway selftest is required after candidate publication. VM legacy CLI
# is explicitly synthetic; doctor remains an owner-target check, never a VM PASS.
if [ "$finish" = COMMIT ] || [ "$finish" = ROLLBACK ];then
 /usr/bin/env -i PATH="$PATH" timeout -k 2 90 /usr/bin/gateway selftest
 if [ "$profile" = B_OWNER_MANUAL ];then /usr/bin/env -i PATH="$PATH" timeout -k 2 90 /usr/bin/gateway doctor;fi
fi
case "$finish" in
 COMMIT) native commit;;
 ROLLBACK) native complete-rollback;;
 ABORT) native complete-abort;;
 NONE) :;;
 *) echo RC_B_REFUSED_FINISH >&2;exit 73;;
esac
native verify
