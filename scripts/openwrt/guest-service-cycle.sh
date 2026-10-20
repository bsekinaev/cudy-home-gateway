#!/bin/sh
# Actual procd lifecycle under one parent FD8, confined to a synthetic namespace.
# Worker/init paths and env are namespace-adapted by run_vm.py; no production claim.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/tmp/hg-service-cycle
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
# Real kernel/nft output, isolated networkless VM only. No owner rule values.
check asata_fixture_table_absent refused nft list table inet passwall2
cat > "$LAB/asata.nft" <<'NFT'
table inet passwall2 {
 set psw2_vps { type ipv4_addr; }
 set psw2_wan { type ipv4_addr; }
 chain PSW2_RULE { }
 chain PSW2_MANGLE {
 ip daddr @psw2_vps counter return
 ct direction reply counter return
 ip daddr @psw2_wan counter return
NFT
printf '%s\n' 'ip protocol udp ether saddr 02:00:00:00:00:02 counter udp dport 53 return' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ether saddr 02:00:00:00:00:02 counter ip daddr 198.18.0.0/16 jump PSW2_RULE' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ether saddr 02:00:00:00:00:02 counter jump PSW2_RULE' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ether saddr 02:00:00:00:00:02 counter jump PSW2_RULE' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ether saddr 02:00:00:00:00:02 counter return' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ip saddr 192.0.2.228 counter udp dport 53 return' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ip saddr 192.0.2.228 counter ip daddr 198.18.0.0/16 jump PSW2_RULE' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ip saddr 192.0.2.228 counter jump PSW2_RULE' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ip saddr 192.0.2.228 counter jump PSW2_RULE' >> "$LAB/asata.nft"
printf '%s\n' 'ip protocol udp ip saddr 192.0.2.228 counter return' >> "$LAB/asata.nft"
cat >> "$LAB/asata.nft" <<'NFT'
 ip protocol udp udp dport 53 counter return
 ip saddr 192.168.1.140 meta l4proto udp counter return comment "ASATA-UDP-DIRECT"
 }
}
NFT
printf '0 58:04:4f:81:09:6b 192.168.1.140 fixture *\n' > "$LAB/asata.leases"
check asata_kernel_fixture nft -f "$LAB/asata.nft"
cat > "$LAB/asata-check.sh" <<'SH'
. /usr/lib/home-gateway/asata.sh
export HG_ASATA_LEASE_FILE=/tmp/hg-service-cycle/asata.leases
set -o pipefail
result=$(nft -a list chain inet passwall2 PSW2_MANGLE | hg_asata_keeper_plan /dev/stdin) || exit 1
[ "$result" = OK ]
SH
check asata_real_kernel_position_15 sh "$LAB/asata-check.sh"
check asata_real_kernel_doctor_ok env HG_ASATA_LEASE_FILE="$LAB/asata.leases" sh -c '. /usr/lib/home-gateway/common.sh; . /usr/lib/home-gateway/doctor.sh; hg_doctor_asata; [ "$HG_DOCTOR_OK" = 1 ] && [ "$HG_DOCTOR_FAIL" = 0 ]'
check asata_interceptor_insert nft insert rule inet passwall2 PSW2_MANGLE meta l4proto udp jump PSW2_RULE
check asata_real_kernel_interceptor_refused refused sh "$LAB/asata-check.sh"
check asata_real_kernel_doctor_refuses env HG_ASATA_LEASE_FILE="$LAB/asata.leases" sh -c '. /usr/lib/home-gateway/common.sh; . /usr/lib/home-gateway/doctor.sh; hg_doctor_asata; [ "$HG_DOCTOR_FAIL" = 1 ]'
check asata_fixture_removed nft delete table inet passwall2

root=/etc/hg-native-snapshot
# Production OpenWrt can report backing-file st_dev different from overlay
# directories. Exercise the actual rc.common/procd + FD8 handshake in that
# configuration too, rather than only the terminal admission primitive.
mkdir -m 700 /tmp/hg-service-overlay-upper /tmp/hg-service-overlay-work
chmod 700 "$root"
mount -t overlay overlay -o "lowerdir=$root,upperdir=/tmp/hg-service-overlay-upper,workdir=/tmp/hg-service-overlay-work,xino=off" "$root" || exit 1
check service_overlay_mounted grep -q '^overlay /etc/hg-native-snapshot overlay ' /proc/mounts
mkdir -m 700 "$root/tmp" "$root/etc/home-gateway-deploy"
mkdir -m 755 "$root/etc/rc.d"
chmod 700 "$root"
ln -s ../init.d/home-gateway-telegram "$root/etc/rc.d/S95home-gateway-telegram"
cp -p /usr/bin/ucode "$root/usr/bin/ucode"
printf '#!/bin/sh\nexec ubus "$@"\n' > "$root/usr/bin/ubus"
chmod 700 "$root/usr/bin/ubus"
mkdir -m 700 "$root/etc/home-gateway" "$root/etc/home-gateway/secrets" "$root/etc/home-gateway/state" "$root/tmp/home-gateway"
printf 'public-fixture\n' > "$root/etc/home-gateway/secrets/telegram.token"
printf '111\n' > "$root/etc/home-gateway/secrets/telegram.user_id"
printf '222\n' > "$root/etc/home-gateway/secrets/telegram.chat_id"
chmod 600 "$root/etc/home-gateway/secrets/"*
sha256sum "$root/etc/home-gateway/secrets/"* > "$LAB/private.sha256"
cp -Rp /opt/hg-vm-lab/control-input /tmp/hg-service-control-input
find /opt/hg-vm-lab/native-candidate /tmp/hg-service-control-input -type d -exec chmod 700 '{}' ';'
check legacy_journal sh /opt/hg-vm-lab/legacy-engine.sh --test-root "$root" apply bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$(cat /opt/hg-vm-lab/legacy-fixture.sha256)" < /opt/hg-vm-lab/legacy-fixture.wire
check legacy_start "$root/etc/init.d/home-gateway-telegram" start
sleep 1
cat > "$LAB/stage.uc" <<'UC'
import * as fs from 'fs';
import {open_state} from '/opt/hg-vm-lab/migration-state.uc';
import {prepare_legacy_snapshot} from '/opt/hg-vm-lab/migration-snapshot.uc';
import {prepare_candidate_snapshot} from '/opt/hg-vm-lab/migration-candidate.uc';
import {apply_controls} from '/opt/hg-vm-lab/migration-controls.uc';
import {prepare_service_coordinator,apply_service_coordinator,commit_service_coordinator,rollback_service_coordinator,complete_service_rollback} from '/opt/hg-vm-lab/migration-terminal.uc';
import {inspect_telegram} from '/opt/hg-vm-lab/migration-service.uc';
let root='/etc/hg-native-snapshot',bb='/bin/busybox',op=ARGV[0],s=open_state(root,op=='prepare',bb,null,null,op=='prepare'?null:true);
if(op=='prepare') {
 prepare_legacy_snapshot(root,s,bb);
 prepare_candidate_snapshot(root,s,bb,'/opt/hg-vm-lab/native-candidate',trim(fs.readfile('/opt/hg-vm-lab/candidate.pin')));
 prepare_service_coordinator(root,s,bb,'/tmp/hg-service-control-input',trim(fs.readfile('/opt/hg-vm-lab/control.pin')),'cccccccccccccccccccccccccccccccccccccccc');
 apply_controls(root,s,bb);
} else if(op=='apply')apply_service_coordinator(root,s,bb);
else if(op=='commit')commit_service_coordinator(root,s,bb);
else if(op=='rollback')rollback_service_coordinator(root,s,bb);
else if(op=='complete')complete_service_rollback(root,s,bb);
else if(op=='legacy' || op=='candidate' || op=='stopped')inspect_telegram(root,s,op);
else die('UNKNOWN');
s.close();
UC
check running_service_prepare ucode "$LAB/stage.uc" prepare
exec 8< "$root/etc/home-gateway-migration.lock"
check parent_guard busybox flock -n 8
check legacy_process_verified ucode "$LAB/stage.uc" legacy
# Synthetic public lab only; kept in the private host diagnostic, never artifact.
ubus -S call service list '{"name":"home-gateway-telegram","verbose":true}' > "$LAB/procd-public-fixture.json"
cat "$LAB/procd-public-fixture.json"
check running_service_apply ucode "$LAB/stage.uc" apply
check old_service_stopped ucode "$LAB/stage.uc" stopped
check apply_boot_quarantined sh -c '[ ! -L /etc/hg-native-snapshot/etc/rc.d/S95home-gateway-telegram ]'
check private_unchanged_before_start sha256sum -c "$LAB/private.sha256"
check service_guard_directory_devices_differ ucode -e 'import * as fs from "fs";let a=fs.lstat("/etc/hg-native-snapshot/etc/home-gateway-migration.lock"),b=fs.lstat("/etc/hg-native-snapshot/etc/home-gateway-migration");exit(a.dev.major!=b.dev.major || a.dev.minor!=b.dev.minor?0:1);'
check candidate_provisional_start env HG_MIGRATION_SERVICE_HANDOFF=1 "$root/etc/init.d/home-gateway-telegram" start
sleep 1
check candidate_processes_verified ucode "$LAB/stage.uc" candidate
check running_service_commit ucode "$LAB/stage.uc" commit
check committed_and_released sh -c '[ "$(cat /etc/hg-native-snapshot/etc/home-gateway-migration/phase)" = COMMITTED ] && [ ! -e /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ]'
check committed_boot_enablement_restored test -L "$root/etc/rc.d/S95home-gateway-telegram"
check committed_reapply_refused refused ucode "$LAB/stage.uc" apply
check running_service_rollback ucode "$LAB/stage.uc" rollback
check candidate_service_stopped ucode "$LAB/stage.uc" stopped
check restoring_boot_quarantined sh -c '[ ! -L /etc/hg-native-snapshot/etc/rc.d/S95home-gateway-telegram ]'
check legacy_restart "$root/etc/init.d/home-gateway-telegram" start
sleep 1
check restored_legacy_process_verified ucode "$LAB/stage.uc" legacy
check running_service_complete_rollback ucode "$LAB/stage.uc" complete
check complete_rollback_repeat ucode "$LAB/stage.uc" complete
check rolled_back_and_released sh -c '[ "$(cat /etc/hg-native-snapshot/etc/home-gateway-migration/phase)" = ROLLED_BACK ] && [ ! -e /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ]'
check rollback_boot_enablement_restored test -L "$root/etc/rc.d/S95home-gateway-telegram"
check private_unchanged_after_rollback sha256sum -c "$LAB/private.sha256"
# Explicit synthetic delivery metadata for the namespace primitive. The real
# root/owner package entrypoint is tested separately by retirement-reboot.
cat > "$LAB/retire.uc" <<'UC'
import * as fs from 'fs';
import {retire_rolled_back} from '/opt/hg-vm-lab/migration-retirement.uc';
let root='/etc/hg-native-snapshot',base=root+'/etc/home-gateway-migration';
if(ARGV[0]=='retire') {
 let marker=fs.readfile(base+'/marker'),nonce=trim(substr(marker,22)),lock=fs.lstat(root+'/etc/home-gateway-migration.lock');
 fs.writefile(base+'/delivery.json',sprintf('%J\n',{format:'HG_DELIVERY_B_RECORD_V1',source:'cccccccccccccccccccccccccccccccccccccccc',manifest_sha256:'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',marker,guard_inode:lock.inode,profile:'B_VM_ACCEPTANCE',boot_id:trim(fs.readfile('/proc/sys/kernel/random/boot_id'))}));fs.chmod(base+'/delivery.json',0600);
 fs.writefile('/tmp/hg-service-cycle/retirement-nonce',nonce);fs.chmod('/tmp/hg-service-cycle/retirement-nonce',0600);
 let p=fs.popen('busybox fsync '+base+'/delivery.json '+base,'r');if(p.close()!=0)die('FSYNC');
}
let nonce=fs.readfile('/tmp/hg-service-cycle/retirement-nonce');
print(retire_rolled_back(root,'/bin/busybox',nonce,'cccccccccccccccccccccccccccccccccccccccc','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',ARGV[0]=='retire'));
UC
check nonuniform_overlay_retirement ucode "$LAB/retire.uc" retire
check nonuniform_overlay_retirement_verified ucode "$LAB/retire.uc" verify
check network_config_unchanged sha256sum -c "$LAB/network"
ip route show > "$LAB/routes.after"
nft -s list ruleset > "$LAB/nft.after"
check routes_unchanged cmp "$LAB/routes" "$LAB/routes.after"
check nft_unchanged cmp "$LAB/nft" "$LAB/nft.after"
exec 8<&-
"$root/etc/init.d/home-gateway-telegram" stop
count=$(wc -l < "$LAB/checks");failed=$(grep -c ':FAIL$' "$LAB/checks" || true)
result=PASS;[ "$failed" = 0 ] || result=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$result" "$count" "$failed"
sync
poweroff -f
