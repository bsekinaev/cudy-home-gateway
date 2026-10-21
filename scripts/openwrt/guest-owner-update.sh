#!/bin/sh
# Unmodified global-root installer, ONLY in marked networkless disposable VM.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/etc/hg-vm-lab/owner-update
mkdir -p "$LAB"
chmod 700 "$LAB"
: > "$LAB/checks"
check() {
 name=$1;shift
 printf 'HGVM_START=%s\n' "$name"
 if "$@" > "$LAB/output" 2>&1;then result=PASS;else result=FAIL;fi
 printf 'HGVM_CHECK=%s:%s\n' "$name" "$result" | tee -a "$LAB/checks"
 cat "$LAB/output"
}
refused() { "$@";[ "$?" -ne 0 ]; }
if [ ! -e "$LAB/reboot-pending" ]; then
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
# Exercise owner hardware predicates verbatim on real OpenWrt ucode; no
# production overrides are added and the VM profile remains x86-only.
printf 'function require(ok,why){if(!ok)die("RC_B_REFUSED_"+why);}' > "$LAB/hardware.uc"
sed -n '/^function verify_owner_hardware(/,/^\/\/ End hardware predicates./p' "$kit/rc-b.uc" >> "$LAB/hardware.uc"
cat >> "$LAB/hardware.uc" <<'UC'
let board={model:ARGV[0],release:{target:ARGV[1]}},mem='MemTotal: '+ARGV[2]+' kB\nMemAvailable: '+ARGV[3]+' kB\n';
verify_owner_hardware(board,mem);verify_available_memory(mem);print('PASS\n');
UC
check owner_memory_regression ucode "$LAB/hardware.uc" 'Cudy TR3000 256MB v1' mediatek/filogic 496724 253116
check unsupported_model_refused refused ucode "$LAB/hardware.uc" 'Cudy TR3000 v2' mediatek/filogic 496724 253116
check unsupported_platform_refused refused ucode "$LAB/hardware.uc" 'Cudy TR3000 256MB v1' x86/64 496724 253116
check wrong_ram_class_refused refused ucode "$LAB/hardware.uc" 'Cudy TR3000 256MB v1' mediatek/filogic 253116 200000
check insufficient_available_memory_refused refused ucode "$LAB/hardware.uc" 'Cudy TR3000 256MB v1' mediatek/filogic 496724 32767
check immutable_package "$kit/rc-b.sh" check "$pin"
check preflight "$kit/rc-b.sh" preflight "$pin"
check prepare "$kit/rc-b.sh" prepare "$pin"
cat "$LAB/output" > "$LAB/prepare"
nonce=$(sed -n 's/^RC_B_TRANSACTION=\([0-9a-f-]*\) SOURCE=.*$/\1/p' "$LAB/prepare")
check production_root_entrypoint sh -c '[ -f /etc/home-gateway-migration/delivery.json ] && [ ! -e /etc/hg-native-snapshot/etc/home-gateway-migration ]'
check prepared_no_auto_apply sh -c '[ "$(cat /etc/home-gateway-migration/phase)" = PREPARED ] && [ ! -L /etc/rc.d/S95home-gateway-telegram ] && [ -L /etc/rc.d/S08home-gateway-migration ]'
check apply "$kit/rc-b.sh" apply "$pin" "$nonce" "$source:$nonce"
check installed_verify "$kit/rc-b.sh" verify "$pin" "$nonce"
check committed sh -c '[ "$(cat /etc/home-gateway-migration/phase)" = COMMITTED ] && [ ! -e /tmp/home-gateway-deploy.lock ] && [ -L /etc/rc.d/S95home-gateway-telegram ]'

update=/etc/hg-vm-lab/update-kit
mkdir -m 700 "$update"
tar -xzpf /opt/hg-vm-lab/owner-update.tar.gz -C "$update"
pin=$(sha256sum "$update/manifest.json" | cut -d ' ' -f1)
printf '%s\n' "$pin" > "$LAB/update-pin"
check update_preflight sh "$update/update.sh" preflight "$pin"
check unknown_file_refused sh -c 'touch /usr/lib/home-gateway/foreign.uc; sh "$1/update.sh" preflight "$2"; rc=$?; rm /usr/lib/home-gateway/foreign.uc; test "$rc" != 0' -- "$update" "$pin"
check drift_refused sh -c 'cp -p /usr/lib/home-gateway/telegram-poller.uc /tmp/poller.save; printf "// drift\n" >> /usr/lib/home-gateway/telegram-poller.uc; sh "$1/update.sh" preflight "$2"; rc=$?; cp -p /tmp/poller.save /usr/lib/home-gateway/telegram-poller.uc; test "$rc" != 0' -- "$update" "$pin"
check foreign_lock_refused sh -c 'mkdir -m 700 /tmp/home-gateway-deploy.lock; sh "$1/update.sh" preflight "$2"; rc=$?; rmdir /tmp/home-gateway-deploy.lock; test "$rc" != 0' -- "$update" "$pin"
check update_apply sh "$update/update.sh" apply "$pin"
check update_verify sh "$update/update.sh" verify "$pin"
check repeated_update_refused refused sh "$update/update.sh" apply "$pin"
check update_rollback sh "$update/update.sh" rollback "$pin"
check baseline_admission sh /usr/libexec/home-gateway-deploy/migration-admission.sh --telegram-start
check baseline_runtime sh -c 'cd / && sha256sum -c "$1/baseline.sha256"' -- "$update"
# Preserve every synthetic test receipt; create a fresh slot for each crash.
archive_update() {
 id=$(cat /etc/home-gateway-owner-update/new-id)
 mv /etc/home-gateway-owner-update "$LAB/receipt-$1"
 mv "/etc/home-gateway-deploy/$id" "$LAB/transaction-$1"
}
archive_update successful
crash_case() {
 point=$1
 HG_OWNER_VM_KILL_AT=$point sh "$update/update.sh" apply "$pin" > "$LAB/kill-$point.log" 2>&1
 rc=$?
 outcome=0
 [ "$rc" = 137 ] && sh "$update/update.sh" recover "$pin" > "$LAB/recover-$point.log" 2>&1 && sh /usr/libexec/home-gateway-deploy/migration-admission.sh --telegram-start || outcome=1
 cat "$LAB/recover-$point.log" 2>/dev/null
 archive_update "$point"
 return "$outcome"
}
check crash_after_quarantine crash_case after-quarantine
check crash_before_publication crash_case before-publication
check crash_after_publication crash_case after-publication
check crash_after_checking crash_case after-checking
check crash_after_latest crash_case after-latest
HG_OWNER_VM_KILL_AT=after-publication sh "$update/update.sh" apply "$pin" > "$LAB/reboot-kill.log" 2>&1
check reboot_interrupted sh -c '[ "$(cat /etc/home-gateway-owner-update/phase)" = APPLYING ] && [ ! -e /etc/rc.d/S94home-gateway-deploy-recover ] && [ ! -e /etc/rc.d/S95home-gateway-telegram ]'
cat /proc/sys/kernel/random/boot_id > "$LAB/boot-before"
touch "$LAB/reboot-pending"
sync
printf 'HGVM_REBOOT=REQUESTED\n'
reboot -f
exit 0
fi
update=/etc/hg-vm-lab/update-kit
pin=$(cat "$LAB/update-pin")
check actual_reboot sh -c 'test "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$1/boot-before")"' -- "$LAB"
check reboot_no_replay sh -c '[ "$(cat /etc/home-gateway-owner-update/phase)" = APPLYING ] && [ "$(cat /etc/home-gateway-deploy/$(cat /etc/home-gateway-deploy/active)/phase)" = APPLYING ] && ! /etc/init.d/home-gateway-telegram running'
check reboot_explicit_recovery sh "$update/update.sh" recover "$pin"
check reboot_recovered_admission sh /usr/libexec/home-gateway-deploy/migration-admission.sh --telegram-start
check reboot_baseline_runtime sh -c 'cd / && sha256sum -c "$1/baseline.sha256"' -- "$update"
check historical_evidence sh /usr/bin/ucode "$update/inspect.uc" "$update" "$pin" journal
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
