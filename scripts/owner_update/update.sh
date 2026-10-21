#!/bin/sh
# VM-only prototype. Never use the migration installer to update COMMITTED HG2.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset ENV BASH_ENV HG_LIBDIR HG_MIGRATION_SERVICE_HANDOFF
[ "$#" -eq 2 ] || exit 64
operation=$1; pin=$2
case "$operation" in preflight|apply|verify|rollback|recover) ;; *) exit 64;; esac
KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
J=/etc/home-gateway-owner-update
D=/etc/home-gateway-deploy
LOCK=/tmp/home-gateway-deploy.lock
DELTA=usr/lib/home-gateway/telegram-poller.uc
inspect() { /usr/bin/ucode "$KIT/inspect.uc" "$KIT" "$pin" "$1"; }
inspect kit
PROFILE=$(/usr/bin/ucode -e 'import * as fs from "fs";print(json(fs.readfile(ARGV[0])).profile);' -- "$KIT/manifest.json")
if [ "$PROFILE" = OWNER_MANUAL ]; then unset HG_OWNER_VM_KILL_AT HG_OWNER_VM_TORN_RECORD HG_OWNER_VM_PARTIAL_POLLER HG_OWNER_VM_REQUIRE_DOCTOR HG_OWNER_VM_POST_DOCTOR; fi
fail() { echo "OWNER_UPDATE_ERROR=$1" >&2; exit 1; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
regular() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%g:%a:%h' "$1")" = "0:0:$2:1" ]; }
admit() { /bin/sh /usr/libexec/home-gateway-deploy/migration-admission.sh "$@"; }
service() { timeout -k 2 30 /etc/init.d/home-gateway-telegram "$1"; }
running() { service running >/dev/null 2>&1; }
wait_running() { n=0; while ! running; do n=$((n+1)); [ "$n" -lt 6 ] || return 1; sleep 1; done; sleep 2; running; inspect workers; }
write() {
    absent "$1.new" || fail PENDING_FILE
    if [ "${HG_OWNER_VM_TORN_RECORD:-}" = "$1:$2" ]; then
        printf '%s' "$2" | cut -c1 | tr -d '\n' > "$1.new"; sync; kill -KILL "$$"
    fi
    printf '%s\n' "$2" > "$1.new"; sync; mv "$1.new" "$1"; sync
}
phase() { write "$J/phase" "$1"; }
check_link() { [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; }
boot_check() {
    check_link /etc/rc.d/S94home-gateway-deploy-recover ../init.d/home-gateway-deploy-recover &&
    check_link /etc/rc.d/S95home-gateway-telegram ../init.d/home-gateway-telegram
}
quarantine() {
    # Persist intent first; after either unlink, both possible boot paths remain
    # recoverable by an explicit owner command. Runtime is still baseline here.
    phase QUARANTINING
    rm /etc/rc.d/S94home-gateway-deploy-recover
    sync
    rm /etc/rc.d/S95home-gateway-telegram
    sync
    phase QUARANTINED
}
install_guard() {
    if absent /etc/init.d/home-gateway-owner-update; then
        absent /etc/init.d/home-gateway-owner-update.new || fail PENDING_BOOT_CONTROL
        cp -p "$KIT/boot.init" /etc/init.d/home-gateway-owner-update.new
        sync; hook boot-staged
        mv /etc/init.d/home-gateway-owner-update.new /etc/init.d/home-gateway-owner-update
        sync; hook boot-published
    fi
    if absent /etc/rc.d/S07home-gateway-owner-update; then
        ln -s ../init.d/home-gateway-owner-update /etc/rc.d/S07home-gateway-owner-update
        sync
    fi
}
restore_boot() {
    for item in home-gateway-deploy-recover home-gateway-telegram; do
        case "$item" in home-gateway-deploy-recover) start=94;; *) start=95;; esac
        path=/etc/rc.d/S$start$item
        if absent "$path"; then ln -s ../init.d/$item "$path"; sync;
        else check_link "$path" ../init.d/$item || fail FOREIGN_BOOT_LINK; fi
    done
}
checks() {
    timeout -k 2 90 /usr/bin/gateway selftest
    if [ "$PROFILE" = OWNER_MANUAL ] || [ "${HG_OWNER_VM_REQUIRE_DOCTOR:-0}" = 1 ] ||
       { [ "${HG_OWNER_VM_POST_DOCTOR:-0}" = 1 ] && [ "$(cat "$J/phase" 2>/dev/null)" = CHECKING ]; }; then timeout -k 2 90 /usr/bin/gateway doctor;
    else echo OWNER_UPDATE_DOCTOR=NOT_TESTED_VM; fi
}
acquire() {
    # Serialize with the trusted receiver using its inode-checked serial flock.
    serial=/tmp/home-gateway-deploy.serial
    if absent "$serial"; then (set -C; : > "$serial") 2>/dev/null || fail SERIAL_RACE; fi
    regular "$serial" 600 || fail SERIAL_METADATA
    before=$(stat -c '%d:%i' "$serial")
    exec 9< "$serial"
    [ "$(stat -Lc '%d:%i' /proc/self/fd/9)" = "$before" ] && busybox flock -n 9 || fail SERIAL_BUSY
    if ! absent "$LOCK"; then
        [ "$operation" = recover ] || fail FOREIGN_OR_STALE_LOCK
        [ -d "$LOCK" ] && [ ! -L "$LOCK" ] && [ "$(stat -c '%u:%g:%a' "$LOCK")" = '0:0:700' ] || fail FOREIGN_LOCK_METADATA
        regular "$LOCK/owner-update" 600 &&
        [ "$(cat "$LOCK/owner-update")" = "$pin" ] || fail FOREIGN_OR_STALE_LOCK
        if ! absent "$LOCK/owner-pid"; then
            regular "$LOCK/owner-pid" 600 || fail UNKNOWN_LEASE_PID
            stale_pid=$(cat "$LOCK/owner-pid")
            printf '%s' "$stale_pid" | grep -Eq '^[1-9][0-9]{0,9}$' &&
            [ "$(stat -c %s "$LOCK/owner-pid")" = "$((${#stale_pid}+1))" ] || fail UNKNOWN_LEASE_PID
            ! kill -0 "$stale_pid" 2>/dev/null || fail LIVE_WRITER
            if ! absent "$LOCK/pid"; then
                regular "$LOCK/pid" 600 && cmp -s "$LOCK/pid" "$LOCK/owner-pid" || fail UNKNOWN_RECEIVER_PID
                [ "$(ls -A "$LOCK" | sort | tr '\n' ':')" = 'owner-pid:owner-update:pid:' ] || fail UNKNOWN_LEASE_CONTENT
                rm "$LOCK/pid"
            else [ "$(ls -A "$LOCK" | sort | tr '\n' ':')" = 'owner-pid:owner-update:' ] || fail UNKNOWN_LEASE_CONTENT; fi
            rm "$LOCK/owner-pid"
        else [ "$(ls -A "$LOCK")" = owner-update ] || fail UNKNOWN_LEASE_CONTENT; fi
        rm "$LOCK/owner-update"; rmdir "$LOCK"
    fi
    mkdir -m 700 "$LOCK"
    printf '%s\n' "$$" > "$LOCK/pid"
    printf '%s\n' "$$" > "$LOCK/owner-pid"
    printf '%s\n' "$pin" > "$LOCK/owner-update"
    lease=$(stat -c '%d:%i' "$LOCK")
    # Hold serial exclusion through terminal checks. procd starts workers via
    # ubus, without inheriting this shell's descriptors. No foreign receiver
    # may consume even a stale owner lease while this operation is alive.
}
release() {
    regular "$LOCK/pid" 600 && [ "$(cat "$LOCK/pid")" = "$$" ] &&
    regular "$LOCK/owner-pid" 600 && cmp -s "$LOCK/pid" "$LOCK/owner-pid" &&
    [ "$(stat -c '%d:%i' "$LOCK")" = "$lease" ] || fail LEASE_IDENTITY
    regular "$LOCK/owner-update" 600 && [ "$(cat "$LOCK/owner-update")" = "$pin" ] || fail LEASE_MARKER
    rm "$LOCK/pid" "$LOCK/owner-pid" "$LOCK/owner-update"; rmdir "$LOCK"; sync
}
replace_poller() {
    source=$1
    target=/$DELTA
    absent "$target.hg-owner-new" || fail PENDING_RUNTIME
    if [ "${HG_OWNER_VM_PARTIAL_POLLER:-0}" = 1 ]; then
        amount=$(( $(wc -c < "$source") / 2 ))
        head -c "$amount" "$source" > "$target.hg-owner-new"; sync; kill -KILL "$$"
    fi
    cp -p "$source" "$target.hg-owner-new"; sync
    hook staged-poller
    mv "$target.hg-owner-new" "$target"; sync
}
preflight() {
    absent "$J" || fail EXISTING_UPDATE
    absent /etc/init.d/home-gateway-owner-update && absent /etc/rc.d/S07home-gateway-owner-update || fail EXISTING_OWNER_GUARD
    absent "$D/active" && absent "$D/active.new" && absent "$D/latest.new" && absent "$LOCK" || fail ACTIVE_OR_FOREIGN
    inspect baseline
    admit --telegram-start
    boot_check || fail BOOT_LINKS
    regular "$D/latest" 600 || fail LATEST_METADATA
    old=$(cat "$D/latest")
    case "$old" in tx.m????????????????????????) ;; *) fail NOT_NATIVE_ANCHOR;; esac
    regular "$D/$old/commit" 600 && [ "$(cat "$D/$old/commit")" = 62592457237e7f026786c086d1ca6fdd4b6c095d ] || fail BASELINE_IDENTITY
    running || fail TELEGRAM_NOT_RUNNING
    inspect workers
    need=$(( $(du -sk "$KIT/baseline" | cut -f1) * 3 + 4096 ))
    available=$(df -Pk /etc | awk 'END {print $4}')
    [ "$available" -ge "$need" ] || fail PERSISTENT_SPACE
    checks
}
hook() {
    # Package-level VM-only gate was verified before this test-only hook.
    if [ "${HG_OWNER_VM_KILL_AT:-}" = "$1" ]; then sync; kill -KILL "$$"; fi
}
validate_pointers() {
    for pointer in active latest; do
        if ! absent "$D/$pointer"; then
            regular "$D/$pointer" 600 || fail POINTER_METADATA
            value=$(cat "$D/$pointer")
            [ "$value" = "$id" ] || { [ "$pointer" = latest ] && [ "$value" = "$old" ]; } || fail FOREIGN_POINTER
        fi
        if [ "$operation" != recover ]; then absent "$D/$pointer.new" || fail PARTIAL_POINTER; fi
    done
}
load_journal() {
    if [ "$operation" = recover ]; then inspect recovery; else inspect journal; fi
    old=$(cat "$J/old-latest"); id=$(cat "$J/new-id"); TX=$D/$id
    validate_pointers
}
archive_slot() {
    source_path=$1; label=$2; count=1
    while [ "$count" -le 8 ]; do
        save="$TX/$label.$count"
        if absent "$save"; then mv "$source_path" "$save"; sync; return 0; fi
        count=$((count+1))
    done
    fail RECOVERY_EVIDENCE_LIMIT
}
archive_pending() {
    # The native recovery inspector certified every pending byte as a bounded
    # prefix of this transaction's own record before any preservation rename.
    for label in owner-phase tx-phase active latest; do
        case "$label" in owner-phase) record_path=$J/phase.new;; tx-phase) record_path=$TX/phase.new;; *) record_path=$D/$label.new;; esac
        if ! absent "$record_path"; then archive_slot "$record_path" interrupted-record-$label; fi
    done
    if ! absent /etc/init.d/home-gateway-owner-update.new; then archive_slot /etc/init.d/home-gateway-owner-update.new interrupted-boot; fi
    if absent "$TX/phase"; then write "$TX/phase" PREPARED; fi
}
restore() {
    load_journal
    inspect mixed
    acquire
    trap 'release' EXIT
    # Lease ownership is the exact package marker in the receiver exclusion;
    # immutable initial lease evidence is never rewritten during recovery.
    # Recovery rechecks everything after acquiring receiver exclusion.
    if [ "$operation" = recover ]; then inspect recovery; else inspect journal; fi
    inspect mixed; validate_pointers
    archive_pending
    install_guard
    for entry in S94home-gateway-deploy-recover S95home-gateway-telegram; do
        path=/etc/rc.d/$entry
        if ! absent "$path"; then
            check_link "$path" ../init.d/$(printf '%s' "$entry" | cut -c4-) || fail FOREIGN_BOOT_LINK
            rm "$path"; sync
        fi
    done
    phase RESTORING
    service stop; ! running || fail TELEGRAM_STILL_RUNNING
    if ! absent "/$DELTA.hg-owner-new"; then
        inspect pending
        archive_slot "/$DELTA.hg-owner-new" interrupted-poller
    fi
    write "$D/active" "$id"
    hook before-rollback
    replace_poller "$TX/backup/$DELTA"
    hook after-rollback
    inspect baseline
    # The original native anchor and all its historical evidence stay intact.
    write "$D/latest" "$old"
    rm "$D/active"; sync
    service start; wait_running
    checks
    release; trap - EXIT
    admit --telegram-start
    hook before-restore-boot
    restore_boot
    phase ROLLED_BACK
    echo OWNER_UPDATE_ROLLBACK=PASS IDENTITY=HGDEPLOY2_BASELINE
}
case "$operation" in
 preflight) preflight; echo OWNER_UPDATE_PREFLIGHT=PASS; exit 0;;
 verify)
    load_journal
    regular "$J/phase" 600 && [ "$(cat "$J/phase")" = COMMITTED ] || fail NOT_COMMITTED
    inspect candidate; admit --telegram-start; boot_check; running; inspect workers; checks
    echo OWNER_UPDATE_VERIFY=PASS; exit 0;;
 rollback|recover)
    load_journal
    current=$(cat "$J/phase" 2>/dev/null || printf PREPARED)
    if [ "$operation" = rollback ]; then [ "$current" = COMMITTED ] || fail NOT_COMMITTED;
    else [ "$current" != ROLLED_BACK ] || fail TERMINAL_USE_VERIFY_OR_ROLLBACK; fi
    restore; exit 0;;
esac
preflight
acquire
trap 'release' EXIT
# Repeat under receiver exclusion; admission permits this receiver-owned lease.
inspect baseline; admit --receiver-recover; boot_check; running
mkdir -m 700 "$J"
printf '%s\n' "$pin" > "$J/kit-pin"
printf '%s\n' "$old" > "$J/old-latest"
source=$(/usr/bin/ucode -e 'import * as fs from "fs";print(json(fs.readfile(ARGV[0])).source_commit);' -- "$KIT/manifest.json")
id=tx.u$(printf '%s' "$source" | cut -c1-24)
printf '%s\n' "$id" > "$J/new-id"
printf '%s\n' "$$:$lease:$(cat /proc/sys/kernel/random/boot_id)" > "$J/lease"
TX=$D/$id
absent "$TX" || fail EXISTING_TRANSACTION
mkdir -m 700 "$TX"
printf '%s\n' "$source" > "$TX/commit"
printf 'HGDEPLOY2\n' > "$TX/inventory-version"
printf '1\n' > "$TX/was-running"
cp "$KIT/baseline.sha256" "$TX/backup.sha256"
cp "$KIT/candidate.sha256" "$TX/new.sha256"
while read -r digest rel; do
    mkdir -p "$TX/backup/${rel%/*}"
    cp -p "/$rel" "$TX/backup/$rel"
done < "$KIT/baseline.sha256"
: > "$TX/preflight.log"; : > "$TX/postflight.log"; : > "$TX/service.log"
find /etc/home-gateway-migration -type f -exec sha256sum '{}' ';' | sort > "$J/migration.sha256"
find "$D/$old" -type f -exec sha256sum '{}' ';' | sort > "$J/anchor.sha256"
write "$TX/phase" PREPARED
phase PREPARED
inspect journal
install_guard
quarantine
hook after-quarantine
write "$D/active" "$id"
phase APPLYING; write "$TX/phase" APPLYING
service stop; ! running || fail TELEGRAM_STILL_RUNNING
hook before-publication
replace_poller "$KIT/candidate/$DELTA"
hook after-publication
inspect candidate
phase CHECKING; write "$TX/phase" CHECKING
hook after-checking
checks > "$TX/postflight.log" 2>&1
service start >> "$TX/service.log" 2>&1; wait_running
write "$TX/phase" COMMITTED
write "$D/latest" "$id"
hook after-latest
rm "$D/active"; sync
phase COMMITTED
release; trap - EXIT
admit --telegram-start
restore_boot
inspect journal
echo OWNER_UPDATE_RESULT=PASS SOURCE="$source" PROFILE="$PROFILE"
