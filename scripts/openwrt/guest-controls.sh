#!/bin/sh
# Native control gate, confined to synthetic root on a disposable official VM.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/tmp/hg-controls-vm
mkdir -m 700 "$LAB"
: > "$LAB/checks"
check() {
 name=$1;shift
 printf 'HGVM_START=%s\n' "$name"
 if "$@" > "$LAB/output" 2>&1;then result=PASS;else result=FAIL;fi
 printf 'HGVM_CHECK=%s:%s\n' "$name" "$result" | tee -a "$LAB/checks"
 cat "$LAB/output"
}
refused() { "$@";[ "$?" -ne 0 ]; }
check procd_pid1 sh -c '[ "$(cat /proc/1/comm)" = procd ]'
check prerequisites apk --repositories-file /opt/hg-vm-lab/packages/repositories --no-network add coreutils-base64=9.9-r2 coreutils-stat=9.9-r2 coreutils-timeout=9.9-r2
sha256sum /etc/config/network /etc/config/firewall /etc/config/dhcp > "$LAB/network"
ip route show > "$LAB/routes"
nft -s list ruleset > "$LAB/nft"
root=/etc/hg-native-snapshot
mkdir -m 700 "$root/tmp" "$root/etc/home-gateway-deploy"
mkdir -m 755 "$root/etc/rc.d"
chmod 700 "$root"
cp -Rp /opt/hg-vm-lab/control-input /tmp/hg-control-input
find /opt/hg-vm-lab/native-candidate /tmp/hg-control-input -type d -exec chmod 700 '{}' ';'
check legacy_journal sh /opt/hg-vm-lab/legacy-engine.sh --test-root "$root" apply bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$(cat /opt/hg-vm-lab/legacy-fixture.sha256)" < /opt/hg-vm-lab/legacy-fixture.wire
cat > "$LAB/stage.uc" <<'UC'
import * as fs from 'fs';
import { open_state } from '/opt/hg-vm-lab/migration-state.uc';
import { prepare_legacy_snapshot } from '/opt/hg-vm-lab/migration-snapshot.uc';
import { prepare_candidate_snapshot } from '/opt/hg-vm-lab/migration-candidate.uc';
import { prepare_coordinator,apply_coordinator,rollback_coordinator } from '/opt/hg-vm-lab/migration-coordinator.uc';
import { commit_migration,complete_rollback } from '/opt/hg-vm-lab/migration-terminal.uc';
import { prepare_controls,apply_controls,restore_controls,verify_controls } from '/opt/hg-vm-lab/migration-controls.uc';
let root='/etc/hg-native-snapshot',bb='/bin/busybox',op=ARGV[0],s=open_state(root,op=='prepare',bb,null,null,op=='borrow'?true:null);
if(op=='prepare') {
 prepare_legacy_snapshot(root,s,bb);
 prepare_candidate_snapshot(root,s,bb,'/opt/hg-vm-lab/native-candidate',trim(fs.readfile('/opt/hg-vm-lab/candidate.pin')));
 prepare_controls(root,s,bb,'/tmp/hg-control-input',trim(fs.readfile('/opt/hg-vm-lab/control.pin')));
 prepare_coordinator(root,s,bb,'cccccccccccccccccccccccccccccccccccccccc',0);
} else if(op=='controls')apply_controls(root,s,bb);
else if(op=='verify')verify_controls(root,s,bb);
else if(op=='apply')apply_coordinator(root,s,bb);
else if(op=='rollback')rollback_coordinator(root,s,bb);
else if(op=='restore')restore_controls(root,s,bb,true);
else if(op=='restoring') { s.fence();s.transition('RESTORING'); }
else if(op=='commit')commit_migration(root,s,bb);
else if(op=='complete-rollback')complete_rollback(root,s,bb,true);
else if(op=='guard')s.assert_root(root);
else if(op=='borrow') { s.fence();let p=fs.popen('test ! -e /proc/self/fd/8','r');if(p.close()!=0)die('FD_LEAK');s.close(); }
else die('UNKNOWN');
UC
printf '#!/bin/sh\nexec ubus "$@"\n' > "$root/usr/bin/ubus"
chmod 700 "$root/usr/bin/ubus"
check control_source_cross_filesystems sh -c '[ "$(stat -c %d /tmp/hg-control-input)" != "$(stat -c %d /etc/hg-native-snapshot)" ]'
check control_prepare ucode "$LAB/stage.uc" prepare
check shared_guard_handoff sh -c 'exec 8< /etc/hg-native-snapshot/etc/home-gateway-migration.lock; busybox flock -n 8 && ucode /tmp/hg-controls-vm/stage.uc borrow && ! ucode /tmp/hg-controls-vm/stage.uc guard'
check control_apply ucode "$LAB/stage.uc" controls
check control_verify ucode "$LAB/stage.uc" verify
check runtime_apply ucode "$LAB/stage.uc" apply
check no_premature_admission sh -c '[ ! -e /etc/hg-native-snapshot/etc/home-gateway-migration/admission ] && [ -L /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ]'
check stopped_service_terminal_commit ucode "$LAB/stage.uc" commit
check committed_phase_durable sh -c '[ "$(cat /etc/hg-native-snapshot/etc/home-gateway-migration/phase)" = COMMITTED ] && [ ! -L /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ]'
check mixed_control_restore_refused refused ucode "$LAB/stage.uc" restore
check interrupt_enter_restoring ucode "$LAB/stage.uc" restoring
check restoring_mixed_controls_refused refused ucode "$LAB/stage.uc" restore
check restoring_boot_protection_retained test -L /etc/hg-native-snapshot/etc/rc.d/S08home-gateway-migration
check runtime_rollback ucode "$LAB/stage.uc" rollback
check control_restore ucode "$LAB/stage.uc" restore
check control_restore_repeat ucode "$LAB/stage.uc" restore
check recovery_boot_guard_retained sh -c '[ -L /etc/hg-native-snapshot/etc/rc.d/S08home-gateway-migration ] && [ -f /etc/hg-native-snapshot/usr/libexec/home-gateway-deploy/migration-state.uc ]'
check stopped_service_terminal_rollback ucode "$LAB/stage.uc" complete-rollback
check terminal_rollback_repeat ucode "$LAB/stage.uc" complete-rollback
check rolled_back_phase_durable sh -c '[ "$(cat /etc/hg-native-snapshot/etc/home-gateway-migration/phase)" = ROLLED_BACK ] && [ ! -L /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ]'
check retained_boot_admission ucode -e 'import {restore_boot_fence} from "/etc/hg-native-snapshot/usr/libexec/home-gateway-deploy/migration-state.uc"; if(restore_boot_fence("/etc/hg-native-snapshot","/bin/busybox")!="ROLLED_BACK")die("BOOT_PHASE");'
# Observe real legacy and new procd workers with only public synthetic IDs.
# No network device exists; there is no Telegram delivery claim.
mkdir -p /etc/home-gateway/secrets
chmod 700 /etc/home-gateway /etc/home-gateway/secrets
printf '111\n' > /etc/home-gateway/secrets/telegram.user_id
printf '222\n' > /etc/home-gateway/secrets/telegram.chat_id
chmod 600 /etc/home-gateway/secrets/telegram.*
cp -p /etc/init.d/home-gateway-telegram "$LAB/candidate-telegram.init"
cat > "$LAB/observe.uc" <<'UC'
import * as fs from 'fs';
import { inspect_telegram,quiesce_telegram } from '/opt/hg-vm-lab/migration-service.uc';
let path='/etc/home-gateway-migration.lock';
let guard=fs.open(path,'re');if(guard==null || guard.lock('xn')==null)die('GUARD');
let original=fs.stat('/proc/self/fd/'+guard.fileno());
let s={assert_root:function(root) {let live=fs.lstat(path);if(root!='' || live?.inode!=original.inode || live.nlink!=1 || live.mode!=0600 || live.uid!=0)die('GUARD');}};
print(sprintf('%J\n',ARGV[0]=='quiesce'?quiesce_telegram('',s,null):inspect_telegram('',s,ARGV[0])));
UC
check candidate_telegram_start /etc/init.d/home-gateway-telegram start
sleep 1
check candidate_real_procd_certified ucode "$LAB/observe.uc" candidate
check candidate_procd_stop_certified ucode "$LAB/observe.uc" quiesce
check stopped_real_procd_certified ucode "$LAB/observe.uc" stopped
cp -p /opt/hg-vm-lab/legacy-telegram.init /etc/init.d/home-gateway-telegram
check legacy_telegram_start /etc/init.d/home-gateway-telegram start
sleep 1
check legacy_real_procd_certified ucode "$LAB/observe.uc" legacy
check legacy_procd_stop_certified ucode "$LAB/observe.uc" quiesce
check legacy_stopped_certified ucode "$LAB/observe.uc" stopped
cp -p "$LAB/candidate-telegram.init" /etc/init.d/home-gateway-telegram
printf 'SERVICE_SCOPE=OBSERVER_ONLY RUNNING_SERVICE_MIGRATION=NOT_INTEGRATED\n'
check production_runtime_unchanged sha256sum -c /opt/hg-vm-lab/runtime.sha256
check network_config_unchanged sha256sum -c "$LAB/network"
ip route show > "$LAB/routes.after"
nft -s list ruleset > "$LAB/nft.after"
check routes_unchanged cmp "$LAB/routes" "$LAB/routes.after"
check nft_unchanged cmp "$LAB/nft" "$LAB/nft.after"
count=$(wc -l < "$LAB/checks");failed=$(grep -c ':FAIL$' "$LAB/checks" || true)
result=PASS;[ "$failed" = 0 ] || result=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$result" "$count" "$failed"
sync
poweroff -f
