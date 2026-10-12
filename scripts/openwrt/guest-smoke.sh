#!/bin/sh
# Disposable networkless x86 VM ONLY. Never install this script on CUDY.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] &&
    [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/etc/hg-vm-lab
mkdir -p "$LAB" /tmp/hg-vm-lab
chmod 700 "$LAB" /tmp/hg-vm-lab
check() {
    name=$1; shift
    if "$@" >/tmp/hg-vm-lab/check.out 2>&1; then outcome=PASS; else outcome=FAIL; fi
    printf 'HGVM_CHECK=%s:%s\n' "$name" "$outcome" | tee -a "$LAB/checks.log"
}
action() { ucode /usr/lib/home-gateway/actions.uc "$@"; }
json_value() {
    ucode -e "import * as fs from 'fs'; let data=json(fs.readfile('$1')); print($2);"
}
export HG_ACTION_STATE_DIR=/etc/home-gateway/state
export HG_ACTION_RUNTIME_DIR=/tmp/hg-vm-actions
export HG_ACTION_SECRETS_DIR=/etc/home-gateway/secrets
export HG_ACTION_INIT_DIR=/opt/hg-vm-lab/init
export HG_ACTION_EXECUTION_ENABLED=1

if [ ! -f "$LAB/reboot-pending" ]; then
    : > "$LAB/checks.log"
    check openwrt_release grep -q "DISTRIB_RELEASE='25.12.5'" /etc/openwrt_release
    check busybox_version sh -c 'ash --help 2>&1 | grep -q "BusyBox v1.37.0"'
    check vendor_prerequisites apk --repositories-file /opt/hg-vm-lab/packages/repositories --no-network add coreutils-stat=9.9-r2 coreutils-timeout=9.9-r2
    cat /tmp/hg-vm-lab/check.out
    timeout -k 1 1 /bin/true >/tmp/hg-vm-lab/timeout-probe 2>&1
    printf 'HGVM_DIAG=timeout_k_rc:%s\n' "$?"
    check procd_pid1 sh -c '[ "$(cat /proc/1/comm)" = procd ]'
    check ubus_service ubus list service
    check runtime_inventory sha256sum -c /opt/hg-vm-lab/runtime.sha256
    check runtime_shell_compile sh -c 'for p in /usr/bin/gateway /usr/lib/home-gateway/*.sh; do ash -n "$p" || exit; done'
    check runtime_ucode_compile sh -c 'for p in /usr/lib/home-gateway/*.uc; do ucode -c -o /tmp/hg-vm-lab/check.uc "$p" || exit; done'
    check incident_selftest sh -c 'ucode /usr/lib/home-gateway/incidents.uc /usr/bin/gateway selftest | grep -q "^incidents-selftest: PASS$"'
    check notification_selftest sh -c 'ucode /usr/lib/home-gateway/notifications.uc /usr/bin/gateway selftest | grep -q "^notifications-selftest: PASS$"'
    cat > /etc/config/passwall2 <<'EOF'
config global 'global'
    option enabled '1'
config rulenode 'rulenode'
    option default_node 'socks_P8ART'
config socks 'socks_P8ART'
    option enabled '1'
    option port '1082'
    option node 'old_node'
    option enable_autoswitch '0'
config nodes 'old_node'
    option type 'Xray'
config nodes 'trial_node'
    option type 'Xray'
EOF
    chmod 600 /etc/config/passwall2
    before=$(sha256sum /etc/config/passwall2)
    gateway main-transaction plan trial_node > /tmp/hg-vm-lab/plan.json 2>/dev/null
    rc=$?
    check planner_blocks_apply test "$rc" -eq 70
    check planner_real_uci grep -q 'PREFLIGHT_ADAPTER_REQUIRED' /tmp/hg-vm-lab/plan.json
    printf 'HGVM_DIAG=planner_status:%s\n' "$(json_value /tmp/hg-vm-lab/plan.json data.status)"
    check planner_preserves_uci test "$(sha256sum /etc/config/passwall2)" = "$before"

    mkdir -p /etc/home-gateway/config /etc/home-gateway/secrets /etc/home-gateway/state
    chmod 700 /etc/home-gateway /etc/home-gateway/config /etc/home-gateway/secrets /etc/home-gateway/state
    printf '111\n' > /etc/home-gateway/secrets/telegram.user_id
    printf '222\n' > /etc/home-gateway/secrets/telegram.chat_id
    for area in config secrets state; do printf 'SYNTHETIC_VM_BACKUP_PROOF\n' > "/etc/home-gateway/$area/vm-proof"; done
    chmod 600 /etc/home-gateway/secrets/telegram.* /etc/home-gateway/*/vm-proof
    printf '/etc/home-gateway/\n' >> /etc/sysupgrade.conf
    check sysupgrade_hg_inventory sh -c 'sysupgrade -l >/tmp/hg-vm-lab/inventory; for area in config secrets state; do grep -Fx "/etc/home-gateway/$area/vm-proof" /tmp/hg-vm-lab/inventory || exit 1; done'
    check native_sysupgrade_backup sysupgrade -b /tmp/hg-vm-lab/backup.tar.gz
    for area in config secrets state; do rm -f "/etc/home-gateway/$area/vm-proof"; done
    check native_sysupgrade_restore sysupgrade -r /tmp/hg-vm-lab/backup.tar.gz
    check native_roundtrip_contents sh -c 'for area in config secrets state; do [ "$(cat /etc/home-gateway/$area/vm-proof)" = SYNTHETIC_VM_BACKUP_PROOF ] || exit 1; [ "$(stat -c %a /etc/home-gateway/$area/vm-proof)" = 600 ] || exit 1; done'
    for area in config secrets state; do printf 'HGVM_DIAG=restore_mode_%s:%s\n' "$area" "$(stat -c %a "/etc/home-gateway/$area/vm-proof")"; done
    # Test actual rc.common/procd against a synthetic service, never Tailscale.
    check fixture_procd_start /opt/hg-vm-lab/init/tailscale start
    sleep 1
    starts=$(wc -l < /tmp/hg-vm-lab/service-starts)
    action prepare restart-tailscale 111 222 900 > /tmp/hg-vm-lab/prepare.json 2>/dev/null
    rc=$?
    check action_prepare test "$rc" -eq 0
    check prepare_has_no_restart test "$(wc -l < /tmp/hg-vm-lab/service-starts)" = "$starts"
    token=$(json_value /tmp/hg-vm-lab/prepare.json data.token)
    action confirm "$token" 111 222 900 > /tmp/hg-vm-lab/confirm.json 2>/dev/null
    rc=$?
    check action_rc_common_confirm test "$rc" -eq 0
    printf 'HGVM_DIAG=action_status:%s\n' "$(json_value /tmp/hg-vm-lab/confirm.json data.status)"
    sleep 1
    check exact_one_restart test "$(wc -l < /tmp/hg-vm-lab/service-starts)" -eq "$((starts + 1))"
    action confirm "$token" 111 222 900 >/tmp/hg-vm-lab/replay.json 2>/dev/null
    check action_replay_refused test "$?" -eq 75
    action prepare restart-uhttpd 111 222 901 > /tmp/hg-vm-lab/reboot-prepare.json 2>/dev/null
    check pending_before_reboot test "$?" -eq 0
    # Persistent fail-closed admission must survive loss of the RAM fence.
    mkdir -m 700 /etc/home-gateway-migration
    printf 'APPLYING\n' > /etc/home-gateway-migration/phase
    chmod 600 /etc/home-gateway-migration/phase
    mkdir /etc/home-gateway-migration/fence
    ln -s /etc/home-gateway-migration/fence /tmp/home-gateway-deploy.lock
    check persistent_admission_blocks sh -c '! sh /usr/libexec/home-gateway-deploy/migration-admission.sh'
    cat /proc/sys/kernel/random/boot_id > "$LAB/old-boot"
    touch "$LAB/reboot-pending"
    sync
    printf 'HGVM_REBOOT=REQUESTED\n'
    reboot -f
    exit 1
fi

check reboot_drops_ram_fence sh -c '[ ! -e /tmp/home-gateway-deploy.lock ] && [ ! -L /tmp/home-gateway-deploy.lock ]'
check reboot_blocks_interrupted_apply sh -c '! sh /usr/libexec/home-gateway-deploy/migration-admission.sh'
check receiver_blocks_interrupted_migration sh -c '! sh /usr/libexec/home-gateway-deploy/engine.sh status'
check telegram_blocks_interrupted_migration sh -c '! /etc/init.d/home-gateway-telegram start'
ubus call service list '{"name":"home-gateway-telegram","verbose":true}' > /tmp/hg-vm-lab/telegram-procd.json
check telegram_has_no_procd_instances ucode -e 'import * as fs from "fs"; let data=json(fs.readfile("/tmp/hg-vm-lab/telegram-procd.json")); exit(length(keys(data["home-gateway-telegram"]?.instances || {})) == 0 ? 0 : 1);'
check reboot_changed_boot sh -c '[ "$(cat /etc/hg-vm-lab/old-boot)" != "$(cat /proc/sys/kernel/random/boot_id)" ]'
check reboot_persisted_hg sh -c 'for area in config secrets state; do [ "$(cat /etc/home-gateway/$area/vm-proof)" = SYNTHETIC_VM_BACKUP_PROOF ] || exit 1; done'
check recovery_projects_pending action show
phase=$(json_value /etc/home-gateway/state/actions.json 'data.records[length(data.records)-1].phase')
check reboot_pending_expires test "$phase" = EXPIRED
check reboot_does_not_restart_fixture test ! -e /tmp/hg-vm-lab/service-starts
total=$(wc -l < "$LAB/checks.log")
failed=$(grep -c ':FAIL$' "$LAB/checks.log" || true)
[ "$failed" -eq 0 ] && status=PASS || status=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$status" "$total" "$failed"
sync
poweroff -f
