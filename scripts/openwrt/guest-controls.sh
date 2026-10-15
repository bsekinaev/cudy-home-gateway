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
find /opt/hg-vm-lab/native-candidate /opt/hg-vm-lab/control-input -type d -exec chmod 700 '{}' ';'
check legacy_journal sh /opt/hg-vm-lab/legacy-engine.sh --test-root "$root" apply bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$(cat /opt/hg-vm-lab/legacy-fixture.sha256)" < /opt/hg-vm-lab/legacy-fixture.wire
cat > "$LAB/stage.uc" <<'UC'
import * as fs from 'fs';
import { open_state } from '/opt/hg-vm-lab/migration-state.uc';
import { prepare_legacy_snapshot } from '/opt/hg-vm-lab/migration-snapshot.uc';
import { prepare_candidate_snapshot } from '/opt/hg-vm-lab/migration-candidate.uc';
import { prepare_coordinator,apply_coordinator,rollback_coordinator } from '/opt/hg-vm-lab/migration-coordinator.uc';
import { prepare_controls,apply_controls,restore_controls,verify_controls } from '/opt/hg-vm-lab/migration-controls.uc';
let root='/etc/hg-native-snapshot',bb='/bin/busybox',op=ARGV[0],s=open_state(root,op=='prepare',bb,null,null,op=='borrow'?true:null);
if(op=='prepare') {
 prepare_legacy_snapshot(root,s,bb);
 prepare_candidate_snapshot(root,s,bb,'/opt/hg-vm-lab/native-candidate',trim(fs.readfile('/opt/hg-vm-lab/candidate.pin')));
 prepare_controls(root,s,bb,'/opt/hg-vm-lab/control-input',trim(fs.readfile('/opt/hg-vm-lab/control.pin')));
 prepare_coordinator(root,s,bb,'cccccccccccccccccccccccccccccccccccccccc',0);
} else if(op=='controls')apply_controls(root,s,bb);
else if(op=='verify')verify_controls(root,s,bb);
else if(op=='apply')apply_coordinator(root,s,bb);
else if(op=='rollback')rollback_coordinator(root,s,bb);
else if(op=='restore')restore_controls(root,s,bb);
else if(op=='guard')s.assert_root(root);
else if(op=='borrow') { s.fence();let p=fs.popen('test ! -e /proc/self/fd/8','r');if(p.close()!=0)die('FD_LEAK');s.close(); }
else die('UNKNOWN');
UC
check control_prepare ucode "$LAB/stage.uc" prepare
check shared_guard_handoff sh -c 'exec 8< /etc/hg-native-snapshot/etc/home-gateway-migration.lock; busybox flock -n 8 && ucode /tmp/hg-controls-vm/stage.uc borrow && ! ucode /tmp/hg-controls-vm/stage.uc guard'
check control_apply ucode "$LAB/stage.uc" controls
check control_verify ucode "$LAB/stage.uc" verify
check runtime_apply ucode "$LAB/stage.uc" apply
check mixed_control_restore_refused refused ucode "$LAB/stage.uc" restore
check runtime_rollback ucode "$LAB/stage.uc" rollback
check control_restore ucode "$LAB/stage.uc" restore
check control_restore_repeat ucode "$LAB/stage.uc" restore
check boot_link_removed sh -c '[ ! -e /etc/hg-native-snapshot/etc/rc.d/S08home-gateway-migration ] && [ ! -L /etc/hg-native-snapshot/etc/rc.d/S08home-gateway-migration ]'
check no_unverified_admission sh -c '[ ! -e /etc/hg-native-snapshot/etc/home-gateway-migration/admission ] && [ -L /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ]'
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
