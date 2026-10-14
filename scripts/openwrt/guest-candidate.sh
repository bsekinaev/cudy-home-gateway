#!/bin/sh
# Dedicated disposable official OpenWrt candidate staging scenario; no production access.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/etc/hg-vm-lab
mkdir -p "$LAB" /tmp/hg-vm-lab
chmod 700 "$LAB" /tmp/hg-vm-lab
: > "$LAB/checks.log"
check() {
    name=$1; shift
    if "$@" >/tmp/hg-vm-lab/check.out 2>&1; then outcome=PASS; else outcome=FAIL; fi
    printf 'HGVM_CHECK=%s:%s\n' "$name" "$outcome" | tee -a "$LAB/checks.log"
}
refused() { "$@"; [ "$?" -ne 0 ]; }
check openwrt_release grep -q "DISTRIB_RELEASE='25.12.5'" /etc/openwrt_release
check busybox_version sh -c 'ash --help 2>&1 | grep -q "BusyBox v1.37.0"'
check procd_pid1 sh -c '[ "$(cat /proc/1/comm)" = procd ]'
check vendor_prerequisites apk --repositories-file /opt/hg-vm-lab/packages/repositories --no-network add coreutils-base64=9.9-r2 coreutils-stat=9.9-r2 coreutils-timeout=9.9-r2
cat /tmp/hg-vm-lab/check.out
sha256sum /etc/config/network /etc/config/firewall /etc/config/dhcp > /tmp/hg-vm-lab/network-config.sha256
ip route show > /tmp/hg-vm-lab/routes.before
nft -s list ruleset > /tmp/hg-vm-lab/nft.before
check fsync_reports_errors sh -c 'busybox fsync /tmp/hg-vm-lab/nonexistent-fsync-probe; [ "$?" = 1 ]'
check flash_tmp_different_filesystems sh -c '[ "$(stat -c %d /etc)" != "$(stat -c %d /tmp)" ]'
    native=/etc/hg-native-snapshot
    mkdir -m 700 "$native/tmp" "$native/etc/home-gateway-deploy"
    chmod 700 "$native"
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
[ -f /etc/hg-native-snapshot/etc/home-gateway-migration/candidate.json ] && printf '# corrupt\n' >> /etc/hg-native-snapshot/etc/home-gateway-migration/candidate/usr/bin/gateway
check candidate_corruption_refused refused ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; import { verify_candidate_snapshot } from "/opt/hg-vm-lab/migration-candidate.uc"; let s=open_state("/etc/hg-native-snapshot", false, "/bin/busybox"); verify_candidate_snapshot("/etc/hg-native-snapshot", s, "/bin/busybox");'
check network_config_unchanged sha256sum -c /tmp/hg-vm-lab/network-config.sha256
ip route show > /tmp/hg-vm-lab/routes.after
nft -s list ruleset > /tmp/hg-vm-lab/nft.after
check routes_unchanged cmp -s /tmp/hg-vm-lab/routes.before /tmp/hg-vm-lab/routes.after
check nft_unchanged cmp -s /tmp/hg-vm-lab/nft.before /tmp/hg-vm-lab/nft.after
total=$(wc -l < "$LAB/checks.log")
failed=$(grep -c ':FAIL$' "$LAB/checks.log" || true)
[ "$failed" -eq 0 ] && status=PASS || status=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$status" "$total" "$failed"
sync
poweroff -f
