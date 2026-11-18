#!/bin/sh
# Unmodified global-root installer, ONLY in marked networkless disposable VM.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/etc/hg-vm-lab/owner-series
mkdir -p "$LAB"
chmod 700 "$LAB"
check() {
 name=$1;shift
 printf 'HGVM_START=%s\n' "$name"
 if "$@" > "$LAB/output" 2>&1;then result=PASS;else result=FAIL;fi
 printf 'HGVM_CHECK=%s:%s\n' "$name" "$result" | tee -a "$LAB/checks"
 cat "$LAB/output"
}
refused() { "$@";[ "$?" -ne 0 ]; }
if [ ! -e "$LAB/reboot-pending" ]; then
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
check v1_preflight sh "$update/update.sh" preflight "$pin"
check v1_apply sh "$update/update.sh" apply "$pin"
check v1_verify sh "$update/update.sh" verify "$pin"
mkdir -m 700 "$LAB/a" "$LAB/b"
tar -xzpf /opt/hg-vm-lab/series-a.tar.gz -C "$LAB/a"
tar -xzpf /opt/hg-vm-lab/series-b.tar.gz -C "$LAB/b"
printf '0\n' > "$LAB/counter"
printf 'retained-client-cursor\n' > /etc/home-gateway/state/series-cursor-proof
printf 'retained-client-queue\n' > /etc/home-gateway/state/series-queue-proof
chmod 600 /etc/home-gateway/state/series-*-proof
sha256sum /etc/home-gateway/state/series-*-proof > "$LAB/client-state"
find /etc/home-gateway-owner-update /etc/home-gateway-migration "/etc/home-gateway-deploy/$(cat /etc/home-gateway-deploy/latest)" -type f -exec sha256sum '{}' ';' | sort > "$LAB/v1-history"
new_id() { n=$(cat "$LAB/counter");n=$((n+1));printf '%s\n' "$n" > "$LAB/counter"; op=$(printf 'tx.%032x' "$n"); }
stage() {
 kit=$1; mode=$2; operation=$3
 pin=$(sha256sum "$kit/manifest.json" | cut -d ' ' -f1)
 /usr/bin/ucode "$kit/engine.uc" "$mode" "$kit" "$pin" "$operation" > "$LAB/stage-output" 2>&1
 result=$?;cat "$LAB/stage-output";[ "$result" = 0 ] || return "$result"
 source=$(/usr/bin/ucode -e 'import * as fs from "fs";print(json(fs.readfile(ARGV[0])).source_commit);' -- "$kit/manifest.json")
 grep -qx "OWNER_SERIES_STAGE=$mode RESULT=PASS SOURCE=$source OPERATION=$operation" "$LAB/stage-output"
}
new_id; a1=$op
check series_preflight stage "$LAB/a" preflight "$a1"
check series_apply_a stage "$LAB/a" apply "$a1"
check series_verify_a stage "$LAB/a" verify "$a1"
check apply_not_replayed refused stage "$LAB/a" apply "$a1"
find "/etc/home-gateway-owner-series/generations/$a1" "/etc/home-gateway-deploy/$a1" -type f -exec sha256sum '{}' ';' | sort > "$LAB/a-history"
new_id; b1=$op
check series_apply_b stage "$LAB/b" apply "$b1"
check series_verify_b stage "$LAB/b" verify "$b1"
new_id; rb1=$op
check rollback_b_to_a stage "$LAB/b" rollback "$rb1"
check rollback_b_verified stage "$LAB/b" verify "$rb1"
check a_receipt_immutable sha256sum -c "$LAB/a-history"
new_id; b2=$op
check reapply_b_new_id stage "$LAB/b" apply "$b2"
new_id
check rollback_reapplied_b stage "$LAB/b" rollback "$op"
new_id
check rollback_a_to_v1 stage "$LAB/a" rollback "$op"
check v1_history_immutable sha256sum -c "$LAB/v1-history"
new_id; a2=$op
check apply_after_full_rollback_chain stage "$LAB/a" apply "$a2"
new_id
check restore_v1_for_crash_matrix stage "$LAB/a" rollback "$op"
crash_case() {
 point=$1;new_id; interrupted=$op
 pin=$(sha256sum "$LAB/a/manifest.json" | cut -d ' ' -f1)
 HG_SERIES_VM_KILL_AT="$point" /usr/bin/ucode "$LAB/a/engine.uc" apply "$LAB/a" "$pin" "$interrupted" > "$LAB/crash-output" 2>&1
 killed=$?;cat "$LAB/crash-output";[ "$killed" -ne 0 ] || return 1
 stage "$LAB/a" recover "$interrupted" || return 1
 stage "$LAB/a" verify "$interrupted" || return 1
 # A terminal cleanup cut preserves the accepted candidate; returning it to V1
 # requires a distinct explicit rollback operation, never replaying Apply.
 if [ "$(cat /etc/home-gateway-owner-series/current 2>/dev/null)" = "$interrupted" ];then
   new_id;stage "$LAB/a" rollback "$op" || return 1
 fi
 /usr/bin/ucode "$update/inspect.uc" "$update" "$(cat "$LAB/update-pin")" journal || return 1
 sha256sum -c "$LAB/v1-history" && sha256sum -c "$LAB/client-state"
}
check cut_lease_published crash_case lease_published
check cut_preparing crash_case preparing
check cut_backup_file crash_case backup_file
check cut_prepared crash_case prepared
check cut_guard_installed crash_case guard_installed
check cut_active_published crash_case active_published
check cut_quarantined crash_case quarantined
check cut_before_publication crash_case before_publication
check cut_staged_runtime crash_case staged_runtime
check cut_after_publication crash_case after_publication
check cut_postflight crash_case postflight
check cut_guard_ready crash_case guard_ready
check cut_candidate_started crash_case candidate_started
check cut_raw_committed crash_case raw_committed
check cut_committed crash_case committed
check cut_sealed crash_case sealed
check cut_lease_retired crash_case lease_retired
new_id;printf '%s\n' "$op" > "$LAB/reboot-operation"
pin=$(sha256sum "$LAB/a/manifest.json" | cut -d ' ' -f1)
HG_SERIES_VM_KILL_AT=after_publication /usr/bin/ucode "$LAB/a/engine.uc" apply "$LAB/a" "$pin" "$op" > "$LAB/reboot-output" 2>&1
check reboot_cut_seen sh -c 'test "$1" -ne 0' -- "$?"
cat /proc/sys/kernel/random/boot_id > "$LAB/boot-before"
touch "$LAB/reboot-pending"
sync
printf 'HGVM_REBOOT=REQUESTED\n'
reboot -f
exit 0
fi
update=/etc/hg-vm-lab/update-kit
op=$(cat "$LAB/reboot-operation")
stage() {
 kit=$1;mode=$2;operation=$3;pin=$(sha256sum "$kit/manifest.json" | cut -d ' ' -f1)
 /usr/bin/ucode "$kit/engine.uc" "$mode" "$kit" "$pin" "$operation"
}
check actual_series_reboot sh -c 'test "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$1/boot-before")"' -- "$LAB"
check reboot_no_replay sh -c '[ -e /etc/home-gateway-owner-series/active ] && [ ! -e /tmp/home-gateway-deploy.lock/pid ] && ! /etc/init.d/home-gateway-telegram running'
check reboot_receiver_fenced refused sh /usr/libexec/home-gateway-deploy/engine.sh recover
check explicit_series_recovery stage "$LAB/a" recover "$op"
check recovered_series_verify stage "$LAB/a" verify "$op"
check original_v1_history_preserved sha256sum -c "$LAB/v1-history"
check client_state_not_rewound sha256sum -c "$LAB/client-state"
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
