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
mkdir -m 700 "$LAB/a"
# HGVM_OBSERVER_BEGIN
mkdir -m 700 "$LAB/b"
# HGVM_OBSERVER_END
tar -xzpf /opt/hg-vm-lab/series-a.tar.gz -C "$LAB/a"
# HGVM_OBSERVER_BEGIN
tar -xzpf /opt/hg-vm-lab/series-b.tar.gz -C "$LAB/b"
# HGVM_OBSERVER_END
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
# HGVM_MONITOR_BEGIN
mkdir -m 700 "$LAB/baseline"
tar -xzpf /opt/hg-vm-lab/series-baseline.tar.gz -C "$LAB/baseline"
new_id;printf '%s\n' "$op" > "$LAB/baseline-operation"
check installed62_preflight stage "$LAB/baseline" preflight "$op"
check installed62_apply stage "$LAB/baseline" apply "$op"
check installed62_verify stage "$LAB/baseline" verify "$op"
check monitor_format ucode -e 'import * as fs from "fs";let m=json(fs.readfile(ARGV[0]));exit(m.format=="HG_OWNER_MONITOR_V3" && m.baseline_commit=="62b5c4a9f25bc657fa1456eeacdfdc9039648cae" && m.parent.format=="HG_OWNER_UPDATE_V2"?0:1);' -- "$LAB/a/manifest.json"
setsid_refusal() {
 mode=$1
 tool=$(command -v setsid) || return 1
 find /etc/home-gateway-owner-series /etc/home-gateway-migration /etc/home-gateway-deploy -type f -exec sha256sum '{}' ';' | sort > "$LAB/refusal-before"
 sha256sum /usr/bin/gateway /usr/lib/home-gateway/* >> "$LAB/refusal-before"
 mv "$tool" "$tool.hg-vm-saved" || return 1
 if [ "$mode" = broken ];then printf '#!/bin/sh\nexit 1\n' > "$tool";chmod 755 "$tool";fi
 new_id
 stage "$LAB/a" preflight "$op";result=$?
 rm -f "$tool";mv "$tool.hg-vm-saved" "$tool"
 [ "$result" -ne 0 ] && grep -q MONITOR_SETSID_REQUIRED "$LAB/stage-output" || return 1
 find /etc/home-gateway-owner-series /etc/home-gateway-migration /etc/home-gateway-deploy -type f -exec sha256sum '{}' ';' | sort > "$LAB/refusal-after"
 sha256sum /usr/bin/gateway /usr/lib/home-gateway/* >> "$LAB/refusal-after"
 cmp "$LAB/refusal-before" "$LAB/refusal-after"
}
check monitor_missing_setsid_before_writes setsid_refusal missing
check monitor_broken_setsid_before_writes setsid_refusal broken
# HGVM_MONITOR_END
# HGVM_WAN_BEGIN
mkdir -m 700 "$LAB/previous" "$LAB/baseline"
tar -xzpf /opt/hg-vm-lab/series-previous.tar.gz -C "$LAB/previous"
tar -xzpf /opt/hg-vm-lab/series-baseline.tar.gz -C "$LAB/baseline"
new_id
check wan_installed62_preflight stage "$LAB/previous" preflight "$op"
check wan_installed62_apply stage "$LAB/previous" apply "$op"
check wan_installed62_verify stage "$LAB/previous" verify "$op"
new_id
check wan_installed1fc_preflight stage "$LAB/baseline" preflight "$op"
check wan_installed1fc_apply stage "$LAB/baseline" apply "$op"
check wan_installed1fc_verify stage "$LAB/baseline" verify "$op"
check wan_format ucode -e 'import * as fs from "fs";let m=json(fs.readfile(ARGV[0]));exit(m.format=="HG_OWNER_WAN_V4" && m.baseline_commit=="1fc822c3bddc1021a1d641c7d7cce71fab7332b8" && m.parent.format=="HG_OWNER_MONITOR_V3" && m.profile=="VM_ONLY"?0:1);' -- "$LAB/a/manifest.json"
# HGVM_WAN_END
new_id; a1=$op
check unused_recovery_refused refused stage "$LAB/a" recover "$a1"
check series_preflight stage "$LAB/a" preflight "$a1"
check series_apply_a stage "$LAB/a" apply "$a1"
check series_verify_a stage "$LAB/a" verify "$a1"
check apply_not_replayed refused stage "$LAB/a" apply "$a1"
find "/etc/home-gateway-owner-series/generations/$a1" "/etc/home-gateway-deploy/$a1" -type f -exec sha256sum '{}' ';' | sort > "$LAB/a-history"
# HGVM_OBSERVER_BEGIN
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
# HGVM_OBSERVER_END
# HGVM_MONITOR_BEGIN
new_id
check monitor_rollback_to_installed62 stage "$LAB/a" rollback "$op"
check monitor_rollback_verified stage "$LAB/a" verify "$op"
check monitor_original_receipt_immutable sha256sum -c "$LAB/a-history"
check monitor_v1_history_immutable sha256sum -c "$LAB/v1-history"
# HGVM_MONITOR_END
# HGVM_WAN_BEGIN
new_id
check wan_rollback_to_installed1fc stage "$LAB/a" rollback "$op"
check wan_rollback_verified stage "$LAB/a" verify "$op"
check wan_original_receipt_immutable sha256sum -c "$LAB/a-history"
check wan_v1_history_immutable sha256sum -c "$LAB/v1-history"
# HGVM_WAN_END

guardian_admission_case() {
 # Reuse the interrupted operation: only the disposable VM's lease is edited.
 # A live unrelated PID must never authenticate a stale process start time.
 sleep 180 & unrelated=$!
 boot=$(cat /proc/sys/kernel/random/boot_id)
 born=$(/usr/bin/ucode -e 'import * as fs from "fs";let s=fs.readfile("/proc/"+ARGV[0]+"/stat");print(split(trim(substr(s,rindex(s,") ")+2)),/\s+/)[19]);' -- "$unrelated")
 lease=/tmp/home-gateway-deploy.lock
 printf 'HG_OWNER_PROCESS_V1 %s %s %s\n' "$boot" "$unrelated" "$born" > "$lease/owner-process.new"
 chmod 600 "$lease/owner-process.new";mv "$lease/owner-process.new" "$lease/owner-process"
 printf '%s\n' "$unrelated" > "$lease/owner-pid"
 printf '%s\n' "$unrelated" > "$lease/pid"
 guard=$(mktemp -d /tmp/home-gateway-series-guard.XXXXXX)
 /usr/bin/ucode "$LAB/a/watch.uc" "$LAB/a" "$pin" "$interrupted" "HG_OWNER_PROCESS_V1 $boot $unrelated $born" "$guard" > "$guard.log" 2>&1 &
 watcher=$!;tries=0
 until [ -f "$guard/ready" ];do tries=$((tries+1));[ "$tries" -le 30 ] || return 1;sleep 1;done
 mkdir -p "$LAB/delayed-init"
 cat > "$LAB/delayed-init/home-gateway-telegram" <<'DELAYED_INIT'
. /etc/init.d/home-gateway-telegram
hg_runtime_admitted() {
 /bin/sh /usr/libexec/home-gateway-deploy/migration-admission.sh --telegram-start --held-telegram-guard || return 1
 touch /etc/hg-vm-lab/owner-series/manual-admitted
 while [ ! -e /etc/hg-vm-lab/owner-series/manual-release ];do sleep 1;done
}
DELAYED_INIT
 timeout -k 2 90 /bin/sh /etc/rc.common "$LAB/delayed-init/home-gateway-telegram" start > "$LAB/manual-start.log" 2>&1 &
 manual=$!;tries=0
 until [ -e "$LAB/manual-admitted" ];do tries=$((tries+1));[ "$tries" -le 25 ] || return 1;sleep 1;done
 printf 'HG_OWNER_PROCESS_V1 %s %s %s\n' "$boot" "$unrelated" "$((born-1))" > "$lease/owner-process.new"
 chmod 600 "$lease/owner-process.new";mv "$lease/owner-process.new" "$lease/owner-process"
 sleep 3
 # The already admitted start still owns FD8; guardian must drain it first.
 [ -f "$lease/pid" ] && [ ! -e "$guard/done" ] || return 1
 touch "$LAB/manual-release";wait "$manual" || return 1
 tries=0
 until [ -e "$guard/done" ];do tries=$((tries+1));[ "$tries" -le 30 ] || return 1;sleep 1;done
 wait "$watcher" || return 1
 kill -0 "$unrelated" && [ ! -e "$lease/pid" ] &&
 ! /etc/init.d/home-gateway-telegram running && refused /etc/init.d/home-gateway-telegram start || return 1
 kill "$unrelated"
}
crash_case() {
 point=$1;new_id; interrupted=$op
 pin=$(sha256sum "$LAB/a/manifest.json" | cut -d ' ' -f1)
 HG_SERIES_VM_KILL_AT="$point" /usr/bin/ucode "$LAB/a/engine.uc" apply "$LAB/a" "$pin" "$interrupted" > "$LAB/crash-output" 2>&1
 killed=$?;cat "$LAB/crash-output";[ "$killed" -ne 0 ] || return 1
 if [ "$point" = candidate_started ];then guardian_admission_case || return 1;fi
 if [ "$point" = preparing ];then
   head -c 32 "/etc/home-gateway-owner-series/generations/$interrupted/history.json" > "$LAB/history-prefix"
   cp "$LAB/history-prefix" "/etc/home-gateway-owner-series/generations/$interrupted/history.json"
   chmod 600 "/etc/home-gateway-owner-series/generations/$interrupted/history.json"
 fi
 if [ "$point" = after_publication ];then
   touch "/etc/home-gateway-deploy/$interrupted/backup/unexpected"
   chmod 600 "/etc/home-gateway-deploy/$interrupted/backup/unexpected"
   refused stage "$LAB/a" recover "$interrupted" || return 1
   (cd / && sha256sum -c "$LAB/a/candidate.sha256") || return 1
   rm "/etc/home-gateway-deploy/$interrupted/backup/unexpected"
   HG_SERIES_VM_KILL_AT=recovery_partial_owner /usr/bin/ucode "$LAB/a/engine.uc" recover "$LAB/a" "$pin" "$interrupted" > "$LAB/handoff-output" 2>&1
   [ "$?" -ne 0 ] || return 1
 fi
 stage "$LAB/a" recover "$interrupted" || return 1
 stage "$LAB/a" verify "$interrupted" || return 1
 # A terminal cleanup cut preserves the accepted candidate; returning it to V1
 # requires a distinct explicit rollback operation, never replaying Apply.
 if [ "$(cat /etc/home-gateway-owner-series/current 2>/dev/null)" = "$interrupted" ];then
   new_id;stage "$LAB/a" rollback "$op" || return 1
 fi
# HGVM_OBSERVER_BEGIN
 /usr/bin/ucode "$update/inspect.uc" "$update" "$(cat "$LAB/update-pin")" journal || return 1
# HGVM_OBSERVER_END
# HGVM_BASELINED_BEGIN
 # Verify the latest receipt, whose history includes all completed operations.
 # The original baseline receipt predates later sealed generations and cannot
 # authenticate the current history inventory. Check baseline bytes separately.
 stage "$LAB/a" verify "$(cat /etc/home-gateway-owner-series/latest)" || return 1
 (cd / && sha256sum -c "$LAB/baseline/candidate.sha256") || return 1
# HGVM_BASELINED_END
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
check cut_partial_runtime crash_case partial_runtime
check cut_after_publication crash_case after_publication
check cut_partial_phase crash_case partial_phase
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
 /usr/bin/ucode "$kit/engine.uc" "$mode" "$kit" "$pin" "$operation" > "$LAB/stage-output" 2>&1
 result=$?;cat "$LAB/stage-output";[ "$result" = 0 ] || return "$result"
 source=$(/usr/bin/ucode -e 'import * as fs from "fs";print(json(fs.readfile(ARGV[0])).source_commit);' -- "$kit/manifest.json")
 grep -qx "OWNER_SERIES_STAGE=$mode RESULT=PASS SOURCE=$source OPERATION=$operation" "$LAB/stage-output"
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
