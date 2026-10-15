#!/bin/sh
# Dedicated disposable official OpenWrt candidate staging scenario; no production access.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/etc/hg-vm-lab
mkdir -p "$LAB" /tmp/hg-vm-lab
chmod 700 "$LAB" /tmp/hg-vm-lab
check() {
    name=$1; shift
    if "$@" >/tmp/hg-vm-lab/check.out 2>&1; then outcome=PASS; else outcome=FAIL; fi
    printf 'HGVM_CHECK=%s:%s\n' "$name" "$outcome" | tee -a "$LAB/checks.log"
}
refused() { "$@"; [ "$?" -ne 0 ]; }

ROOT=/etc/hg-native-snapshot
mkdir -m 700 /tmp/hg-crash-ram
kill_operation() {
    action=$1
    rm -f /tmp/hg-vm-lab/runtime-crash-ready
    cat > /tmp/hg-vm-lab/runtime-fsync-shim <<'SHIM'
#!/bin/sh
case "$*" in *"/runtime-pending/usr_bin_home-gateway-ci-smoke"*) touch /tmp/hg-vm-lab/runtime-crash-ready; sleep 10;; esac
exec /bin/busybox "$@"
SHIM
    chmod 700 /tmp/hg-vm-lab/runtime-fsync-shim
    ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { apply_coordinator,rollback_coordinator } from "/opt/hg-vm-lab/migration-coordinator.uc"; let s=open_state("/etc/hg-native-snapshot",false,"/tmp/hg-vm-lab/runtime-fsync-shim"); if(ARGV[0]=="apply")apply_coordinator("/etc/hg-native-snapshot",s,"/tmp/hg-vm-lab/runtime-fsync-shim");else rollback_coordinator("/etc/hg-native-snapshot",s,"/tmp/hg-vm-lab/runtime-fsync-shim");' "$action" &
    owned=$!
    tries=0
    while [ ! -f /tmp/hg-vm-lab/runtime-crash-ready ] && kill -0 "$owned" 2>/dev/null && [ "$tries" -lt 15 ]; do sleep 1; tries=$((tries+1)); done
    if [ ! -f /tmp/hg-vm-lab/runtime-crash-ready ]; then wait "$owned" 2>/dev/null || true; return 1; fi
    kill -KILL "$owned" || return 1
    wait "$owned" 2>/dev/null
    rc=$?
    [ "$rc" -eq 137 ]
}
request_reboot() {
    cat /proc/sys/kernel/random/boot_id > "$LAB/boot.before"
    sync
    printf 'HGVM_REBOOT=REQUESTED\n'
    reboot
    exit 0
}
if [ ! -f "$LAB/reboot-stage" ]; then
    : > "$LAB/checks.log"
check openwrt_release grep -q "DISTRIB_RELEASE='25.12.5'" /etc/openwrt_release
check busybox_version sh -c 'ash --help 2>&1 | grep -q "BusyBox v1.37.0"'
check procd_pid1 sh -c '[ "$(cat /proc/1/comm)" = procd ]'
check vendor_prerequisites apk --repositories-file /opt/hg-vm-lab/packages/repositories --no-network add coreutils-base64=9.9-r2 coreutils-stat=9.9-r2 coreutils-timeout=9.9-r2
cat /tmp/hg-vm-lab/check.out
sha256sum /etc/config/network /etc/config/firewall /etc/config/dhcp > /etc/hg-vm-lab/network-config.sha256
ip route show > /etc/hg-vm-lab/routes.before
nft -s list ruleset > /etc/hg-vm-lab/nft.before
check fsync_reports_errors sh -c 'busybox fsync /tmp/hg-vm-lab/nonexistent-fsync-probe; [ "$?" = 1 ]'
check flash_tmp_different_filesystems sh -c '[ "$(stat -c %d /etc)" != "$(stat -c %d /tmp)" ]'
    native=/etc/hg-native-snapshot
    mkdir -m 700 "$native/tmp" "$native/etc/home-gateway-deploy"
    chmod 700 "$native"
    mount --bind /tmp/hg-crash-ram "$native/tmp"
    check native_legacy_fixture_apply sh /opt/hg-vm-lab/legacy-engine.sh --test-root "$native" apply bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$(cat /opt/hg-vm-lab/legacy-fixture.sha256)" < /opt/hg-vm-lab/legacy-fixture.wire
    cat /tmp/hg-vm-lab/check.out
    check native_legacy_snapshot_prepare ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { prepare_legacy_snapshot } from "/opt/hg-vm-lab/migration-snapshot.uc"; let s=open_state("/etc/hg-native-snapshot", true, "/bin/busybox"); prepare_legacy_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox");'
    cat /tmp/hg-vm-lab/check.out
    check native_legacy_snapshot_verify ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { verify_legacy_snapshot } from "/opt/hg-vm-lab/migration-snapshot.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); verify_legacy_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox");'
    cat /tmp/hg-vm-lab/check.out
    check native_snapshot_no_auto_prepare refused ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { prepare_legacy_snapshot } from "/opt/hg-vm-lab/migration-snapshot.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); prepare_legacy_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox");'
    check native_snapshot_preserves_legacy sh -c 'cd /etc/hg-native-snapshot && latest=$(cat etc/home-gateway-deploy/latest) && sha256sum -c "etc/home-gateway-deploy/$latest/new.sha256" && [ ! -e "etc/home-gateway-deploy/$latest/inventory-version" ] && [ ! -e etc/home-gateway-deploy/active ] && [ ! -e etc/home-gateway-migration/admission ]'
    saved="$native/etc/home-gateway-migration/old/runtime/usr/libexec/home-gateway-deploy/engine.sh"
    printf '# corrupt\n' >> "$saved"
    check native_snapshot_corruption_refused refused ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { verify_legacy_snapshot } from "/opt/hg-vm-lab/migration-snapshot.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); verify_legacy_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox");'
    cp /opt/hg-vm-lab/legacy-engine.sh "$saved"
    chown 65534:65534 "$saved"
    check native_snapshot_wrong_uid_gid_refused refused ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { verify_legacy_snapshot } from "/opt/hg-vm-lab/migration-snapshot.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); verify_legacy_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox");'
    chown 0:0 "$saved"
    chmod 700 "$saved"
    check native_snapshot_repeat_verify ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { verify_legacy_snapshot } from "/opt/hg-vm-lab/migration-snapshot.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); verify_legacy_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox");'
# Only the immutable public candidate is copied into this disposable tmpfs.
cp -rp /opt/hg-vm-lab/native-candidate /tmp/hg-candidate-input
find /tmp/hg-candidate-input -type d -exec chmod 700 '{}' ';'
check candidate_pin_mismatch_refused refused ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { prepare_candidate_snapshot } from "/opt/hg-vm-lab/migration-candidate.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); prepare_candidate_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox", "/tmp/hg-candidate-input", "0000000000000000000000000000000000000000000000000000000000000000");'
check candidate_snapshot_prepare ucode -e 'import * as fs from "fs"; import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { prepare_candidate_snapshot } from "/opt/hg-vm-lab/migration-candidate.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); prepare_candidate_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox", "/tmp/hg-candidate-input", trim(fs.readfile("/opt/hg-vm-lab/candidate.pin")));'
cat /tmp/hg-vm-lab/check.out
check candidate_snapshot_verify ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { verify_candidate_snapshot } from "/opt/hg-vm-lab/migration-candidate.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); verify_candidate_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox");'
cat /tmp/hg-vm-lab/check.out
check candidate_copy_crosses_filesystems sh -c '[ -f /tmp/hg-candidate-input/migration.sha256 ] && [ -f /etc/hg-native-snapshot/etc/home-gateway-migration/candidate/migration.sha256 ] && a=$(stat -c %d /tmp/hg-candidate-input/migration.sha256) && b=$(stat -c %d /etc/hg-native-snapshot/etc/home-gateway-migration/candidate/migration.sha256) && [ "$a" != "$b" ]'
check candidate_does_not_admit_apply sh -c '[ "$(cat /etc/hg-native-snapshot/etc/home-gateway-migration/phase)" = PREPARING ] && [ ! -e /etc/hg-native-snapshot/etc/home-gateway-migration/admission ] && [ ! -e /etc/hg-native-snapshot/usr/lib/home-gateway/actions.uc ]'

    check crash_coordinator_prepare ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { prepare_coordinator } from "/opt/hg-vm-lab/migration-coordinator.uc"; let s=open_state("/etc/hg-native-snapshot",false,"/bin/busybox");prepare_coordinator("/etc/hg-native-snapshot",s,"/bin/busybox","cccccccccccccccccccccccccccccccccccccccc",0);'
    cat /tmp/hg-vm-lab/check.out

    check crash_complete_apply ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { apply_coordinator } from "/opt/hg-vm-lab/migration-coordinator.uc"; let s=open_state("/etc/hg-native-snapshot",false,"/bin/busybox");apply_coordinator("/etc/hg-native-snapshot",s,"/bin/busybox");'
    cat /tmp/hg-vm-lab/check.out
    check crash_restore_sigkill kill_operation restore
    check crash_partial_restore_published cmp /etc/hg-native-snapshot/usr/bin/gateway /etc/hg-native-snapshot/etc/home-gateway-migration/old/runtime/usr/bin/gateway
    check crash_restore_keeps_candidate_remainder test -f /etc/hg-native-snapshot/usr/lib/home-gateway/actions.uc
    check crash_restore_keeps_guarded_init cmp /etc/hg-native-snapshot/etc/init.d/home-gateway-telegram /etc/hg-native-snapshot/etc/home-gateway-migration/candidate/etc/init.d/home-gateway-telegram
    check crash_restore_phase sh -c '[ "$(cat /etc/hg-native-snapshot/etc/home-gateway-migration/phase)" = RESTORING ]'
    printf 'RESTORING\n' > "$LAB/reboot-stage"
    request_reboot
fi
mount --bind /tmp/hg-crash-ram "$ROOT/tmp"
check crash_restore_changed_boot sh -c '[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat /etc/hg-vm-lab/boot.before)" ]'
check crash_restore_ram_fence_lost sh -c '[ ! -e /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ] && [ ! -L /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ]'
check crash_restore_not_replayed refused ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { apply_coordinator } from "/opt/hg-vm-lab/migration-coordinator.uc"; let s=open_state("/etc/hg-native-snapshot",false,"/bin/busybox");apply_coordinator("/etc/hg-native-snapshot",s,"/bin/busybox");'
check crash_explicit_restore ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { rollback_coordinator } from "/opt/hg-vm-lab/migration-coordinator.uc"; let s=open_state("/etc/hg-native-snapshot",false,"/bin/busybox");rollback_coordinator("/etc/hg-native-snapshot",s,"/bin/busybox");'
cat /tmp/hg-vm-lab/check.out
check crash_verified_legacy18_receiver3 ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { verify_runtime } from "/opt/hg-vm-lab/migration-runtime.uc"; let s=open_state("/etc/hg-native-snapshot",false,"/bin/busybox");verify_runtime("/etc/hg-native-snapshot",s,"/bin/busybox",false);'
check crash_original_latest cmp /etc/hg-native-snapshot/etc/home-gateway-deploy/latest /etc/hg-native-snapshot/etc/home-gateway-migration/old/latest
check crash_retains_fence_no_admission sh -c '[ -L /etc/hg-native-snapshot/tmp/home-gateway-deploy.lock ] && [ ! -e /etc/hg-native-snapshot/etc/home-gateway-migration/admission ]'
check network_config_unchanged sha256sum -c /etc/hg-vm-lab/network-config.sha256
ip route show > /tmp/hg-vm-lab/routes.after
nft -s list ruleset > /tmp/hg-vm-lab/nft.after
check routes_unchanged cmp -s /etc/hg-vm-lab/routes.before /tmp/hg-vm-lab/routes.after
check nft_unchanged cmp -s /etc/hg-vm-lab/nft.before /tmp/hg-vm-lab/nft.after
total=$(wc -l < "$LAB/checks.log")
failed=$(grep -c ':FAIL$' "$LAB/checks.log" || true)
[ "$failed" -eq 0 ] && status=PASS || status=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$status" "$total" "$failed"
sync
poweroff -f
