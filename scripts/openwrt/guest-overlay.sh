#!/bin/sh
# Disposable official x86 OpenWrt ONLY. Synthetic overlay identity, not migration.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/etc/hg-overlay-lab
ROOT=/etc/hg-overlay-identity
mkdir -p "$LAB" /tmp/hg-vm-lab "$ROOT"
chmod 700 "$LAB" /tmp/hg-vm-lab "$ROOT"
check() {
    name=$1; shift
    if "$@" >/tmp/hg-vm-lab/check.out 2>&1; then outcome=PASS; else outcome=FAIL; fi
    printf 'HGVM_CHECK=%s:%s\n' "$name" "$outcome" | tee -a "$LAB/checks.log"
}
first=0
if [ ! -f "$LAB/reboot-pending" ]; then
    first=1
    : > "$LAB/checks.log"
    mkdir -p "$LAB/lower/etc" "$LAB/lower/tmp" "$LAB/upper" "$LAB/work"
    chmod 700 "$LAB/lower" "$LAB/lower/etc" "$LAB/lower/tmp" "$LAB/upper" "$LAB/work"
    printf 'DISPOSABLE\n' > "$LAB/lower/.hg-deploy-test-root"
    check procd_pid1 sh -c '[ "$(cat /proc/1/comm)" = procd ]'
    check vendor_prerequisites apk --repositories-file /opt/hg-vm-lab/packages/repositories --no-network add coreutils-stat=9.9-r2 coreutils-timeout=9.9-r2
fi
# Exercise non-unified overlay stat identities explicitly, not ext4-only behavior.
mount -t overlay overlay -o "lowerdir=$LAB/lower,upperdir=$LAB/upper,workdir=$LAB/work,xino=off" "$ROOT"
mkdir -m 700 /tmp/hg-overlay-ram
mount --bind /tmp/hg-overlay-ram "$ROOT/tmp"
if [ "$first" = 1 ]; then
    check overlay_mounted grep -q '^overlay /etc/hg-overlay-identity overlay ' /proc/mounts
    check overlay_initial_state ucode -e 'import * as fs from "fs"; import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; let r="/etc/hg-overlay-identity", s=open_state(r,true,"/bin/busybox"); s.fence(); s.transition("PREPARED"); s.transition("APPLYING"); s.transition("COMMITTED"); let b=r+"/etc/home-gateway-migration", nonce=split(trim(fs.readfile(b+"/marker"))," ")[1]; fs.writefile(b+"/admission","HG_MIGRATION_ADMITTED_V2 COMMITTED "+nonce+" "+fs.lstat(r+"/etc/home-gateway-migration.lock").inode+"\n"); fs.chmod(b+"/admission",0600); let p=fs.popen("/bin/busybox fsync "+b+"/admission "+b,"r"); if(p.close()!=0)exit(1); s.release();'
    cat /tmp/hg-vm-lab/check.out
    check overlay_initial_admission sh /usr/libexec/home-gateway-deploy/migration-admission.sh --test-root "$ROOT"
    cat /tmp/hg-vm-lab/check.out
    stat -c %i "$ROOT/etc/home-gateway-migration.lock" > "$LAB/guard-inode.before"
    cat /proc/sys/kernel/random/boot_id > "$LAB/boot.before"
    : > "$LAB/reboot-pending"
    sync
    umount "$ROOT/tmp"
    umount "$ROOT"
    printf 'HGVM_REBOOT=REQUESTED\n'
    reboot
    exit 0
fi
check overlay_remounted grep -q '^overlay /etc/hg-overlay-identity overlay ' /proc/mounts
check overlay_reboot_changed sh -c '[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat /etc/hg-overlay-lab/boot.before)" ]'
check overlay_guard_inode_stable sh -c '[ "$(stat -c %i /etc/hg-overlay-identity/etc/home-gateway-migration.lock)" = "$(cat /etc/hg-overlay-lab/guard-inode.before)" ]'
check overlay_reopen_after_reboot ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; let s=open_state("/etc/hg-overlay-identity",false,"/bin/busybox"); exit(s.phase()=="COMMITTED"?0:1);'
check overlay_admission_after_reboot sh /usr/libexec/home-gateway-deploy/migration-admission.sh --test-root "$ROOT"
cat /tmp/hg-vm-lab/check.out
total=$(wc -l < "$LAB/checks.log")
failed=$(grep -c ':FAIL$' "$LAB/checks.log" || true)
[ "$failed" -eq 0 ] && status=PASS || status=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$status" "$total" "$failed"
sync
poweroff -f
