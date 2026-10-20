#!/bin/sh
# SIGKILL during explicit retirement, reboot, then a fresh install/rollback.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/etc/hg-vm-lab/retirement
mkdir -p "$LAB"
chmod 700 "$LAB"
check() {
 name=$1;shift
 printf 'HGVM_START=%s\n' "$name"
 if "$@" > /tmp/hg-retirement-output 2>&1;then result=PASS;else result=FAIL;fi
 printf 'HGVM_CHECK=%s:%s\n' "$name" "$result" | tee -a "$LAB/checks"
 cat /tmp/hg-retirement-output
}
refused() { "$@";[ "$?" -ne 0 ]; }
if [ ! -e "$LAB/stage" ];then
: > "$LAB/checks"
check procd_pid1 sh -c '[ "$(cat /proc/1/comm)" = procd ]'
check prerequisites apk --repositories-file /opt/hg-vm-lab/packages/repositories --no-network add coreutils-base64=9.9-r2 coreutils-stat=9.9-r2 coreutils-timeout=9.9-r2
sha256sum /etc/config/network /etc/config/firewall /etc/config/dhcp > "$LAB/network"
ip route show > "$LAB/routes"
nft -s list ruleset > "$LAB/nft"
# Verify source injection before replacing it with the public HG1 fixture.
check injected_runtime_verified sha256sum -c /opt/hg-vm-lab/runtime.sha256
cp -Rp /etc/hg-native-snapshot/usr/* /usr/
cp -Rp /etc/hg-native-snapshot/etc/init.d/* /etc/init.d/
rm /usr/lib/home-gateway/actions.uc /usr/lib/home-gateway/notifications.uc /usr/libexec/home-gateway-deploy/migration-admission.sh
mkdir -m 700 /etc/home-gateway-deploy /etc/home-gateway /etc/home-gateway/secrets /etc/home-gateway/state /tmp/home-gateway
printf 'public-fixture\n' > /etc/home-gateway/secrets/telegram.token
printf '111\n' > /etc/home-gateway/secrets/telegram.user_id
printf '222\n' > /etc/home-gateway/secrets/telegram.chat_id
chmod 600 /etc/home-gateway/secrets/*
ln -s ../init.d/home-gateway-telegram /etc/rc.d/S95home-gateway-telegram
ln -s ../init.d/home-gateway-deploy-recover /etc/rc.d/S94home-gateway-deploy-recover
check legacy_journal sh /usr/libexec/home-gateway-deploy/engine.sh apply bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$(cat /opt/hg-vm-lab/legacy-fixture.sha256)" < /opt/hg-vm-lab/legacy-fixture.wire
sha256sum /etc/home-gateway/secrets/* > "$LAB/private.sha256"
cat /etc/home-gateway-deploy/latest > "$LAB/latest"
latest=$(cat "$LAB/latest")
find "/etc/home-gateway-deploy/$latest" -type f -exec sha256sum '{}' ';' | sort > "$LAB/legacy-journal.sha256"
check legacy_start /etc/init.d/home-gateway-telegram start
sleep 1
kit=/tmp/hg-rc-b-kit
mkdir -m 700 "$kit"
tar -xzf /opt/hg-vm-lab/rc-b.tar.gz -C "$kit"
pin=$(sha256sum "$kit/manifest.json" | cut -d ' ' -f 1)
source=$(ucode -e 'import * as fs from "fs";print(json(fs.readfile(ARGV[0])).source_commit);' -- "$kit/manifest.json")
check immutable_package "$kit/rc-b.sh" check "$pin"
check preflight "$kit/rc-b.sh" preflight "$pin"
check prepare "$kit/rc-b.sh" prepare "$pin"
cat /tmp/hg-retirement-output > "$LAB/prepare"
nonce=$(sed -n 's/^RC_B_TRANSACTION=\([0-9a-f-]*\) SOURCE=.*$/\1/p' "$LAB/prepare")
check production_root_entrypoint sh -c '[ -f /etc/home-gateway-migration/delivery.json ] && [ ! -e /etc/hg-native-snapshot/etc/home-gateway-migration ]'
check prepared_no_auto_apply sh -c '[ "$(cat /etc/home-gateway-migration/phase)" = PREPARED ] && [ ! -L /etc/rc.d/S95home-gateway-telegram ] && [ -L /etc/rc.d/S08home-gateway-migration ]'
check committed_before_crash "$kit/rc-b.sh" apply "$pin" "$nonce" "$source:$nonce"
check rollback_before_retirement "$kit/rc-b.sh" rollback "$pin" "$nonce"
check verify_before_retirement "$kit/rc-b.sh" verify "$pin" "$nonce"
check retirement_check "$kit/rc-b.sh" retire-check "$pin" "$nonce"
stat -c %i /etc/home-gateway-migration.lock > "$LAB/guard.before"
sha256sum /etc/home-gateway-migration/snapshot.json | cut -d ' ' -f 1 > "$LAB/snapshot.before"
printf '%s\n' "$pin" > "$LAB/pin"
printf '%s\n' "$source" > "$LAB/source"
printf '%s\n' "$nonce" > "$LAB/nonce"
cat /proc/sys/kernel/random/boot_id > "$LAB/boot.before"
/opt/hg-vm-lab/fault-runtime /etc/home-gateway-migration "$LAB/pid" "$LAB/fired" "$LAB/watcher-ready" &
watch=$!
for attempt in 1 2 3 4 5;do [ ! -e "$LAB/watcher-ready" ] || break;sleep 1;done
check watcher_ready test -f "$LAB/watcher-ready"
/bin/busybox setsid "$kit/rc-b.sh" retire "$pin" "$nonce" "retire:$source:$nonce" > "$LAB/interrupted-output" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$LAB/pid"
wait "$pid" || true
kill "$watch" 2>/dev/null || true
wait "$watch" 2>/dev/null || true
check sigkill_observed grep -qx SIGKILL "$LAB/fired"
check retirement_interrupted_archive sh -c '[ ! -e /etc/home-gateway-migration ] && [ -d /etc/home-gateway-migration.retired.'"$nonce"' ] && [ ! -e /etc/home-gateway-migration.retired.'"$nonce"'/retirement.complete ] && [ -L /tmp/home-gateway-deploy.lock ]'
check old_apply_refused refused "$kit/rc-b.sh" apply "$pin" "$nonce" "$source:$nonce"
check pending_retirement_preflight_refused refused "$kit/rc-b.sh" preflight "$pin"
printf 'REBOOT\n' > "$LAB/stage"
sync
printf 'HGVM_REBOOT=REQUESTED\n'
reboot -f
exit 0
fi
pin=$(cat "$LAB/pin");source=$(cat "$LAB/source");nonce=$(cat "$LAB/nonce")
archive=/etc/home-gateway-migration.retired.$nonce
check reboot_changed_boot_id refused cmp "$LAB/boot.before" /proc/sys/kernel/random/boot_id
check archive_survives_reboot test -d "$archive"
check no_boot_replay sh -c '[ ! -e /etc/home-gateway-migration ]'
check guard_inode_preserved sh -c '[ "$(stat -c %i /etc/home-gateway-migration.lock)" = "$(cat /etc/hg-vm-lab/retirement/guard.before)" ]'
kit=/tmp/hg-rc-b-kit
mkdir -m 700 "$kit"
tar -xzf /opt/hg-vm-lab/rc-b.tar.gz -C "$kit"
check immutable_recovery_package "$kit/rc-b.sh" check "$pin"
check incomplete_archive_preflight_refused refused "$kit/rc-b.sh" preflight "$pin"
check resumed_retirement_check "$kit/rc-b.sh" retire-check "$pin" "$nonce"
check explicit_retirement_resume "$kit/rc-b.sh" retire "$pin" "$nonce" "retire:$source:$nonce"
check repeated_retirement "$kit/rc-b.sh" retire "$pin" "$nonce" "retire:$source:$nonce"
check old_apply_after_retirement_refused refused "$kit/rc-b.sh" apply "$pin" "$nonce" "$source:$nonce"
check fresh_preflight "$kit/rc-b.sh" preflight "$pin"
check fresh_prepare "$kit/rc-b.sh" prepare "$pin"
cat /tmp/hg-retirement-output > "$LAB/second-prepare"
newnonce=$(sed -n 's/^RC_B_TRANSACTION=\([0-9a-f-]*\) SOURCE=.*$/\1/p' "$LAB/second-prepare")
check fresh_transaction sh -c '[ "$1" != "$2" ] && [ "${#1}" = 36 ]' sh "$newnonce" "$nonce"
check fresh_apply "$kit/rc-b.sh" apply "$pin" "$newnonce" "$source:$newnonce"
check fresh_installed_verify "$kit/rc-b.sh" verify "$pin" "$newnonce"
check old_retirement_cannot_touch_new_transaction refused "$kit/rc-b.sh" retire "$pin" "$nonce" "retire:$source:$nonce"
check fresh_rollback "$kit/rc-b.sh" rollback "$pin" "$newnonce"
check fresh_rollback_verify "$kit/rc-b.sh" verify "$pin" "$newnonce"
check archived_snapshot_unchanged sh -c '[ "$(sha256sum "$1/snapshot.json" | cut -d " " -f 1)" = "$(cat /etc/hg-vm-lab/retirement/snapshot.before)" ]' sh "$archive"
check restored_latest cmp "$LAB/latest" /etc/home-gateway-deploy/latest
check restored_legacy_journal sha256sum -c "$LAB/legacy-journal.sha256"
check private_state_preserved sha256sum -c "$LAB/private.sha256"
check network_config_unchanged sha256sum -c "$LAB/network"
ip route show > "$LAB/routes.after"
nft -s list ruleset > "$LAB/nft.after"
check routes_unchanged cmp "$LAB/routes" "$LAB/routes.after"
check nft_unchanged cmp "$LAB/nft" "$LAB/nft.after"
/etc/init.d/home-gateway-telegram stop
count=$(wc -l < "$LAB/checks");failed=$(grep -c ':FAIL$' "$LAB/checks" || true)
result=PASS;[ "$failed" = 0 ] || result=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$result" "$count" "$failed"
sync
poweroff -f
