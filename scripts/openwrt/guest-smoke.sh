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
refused() { "$@"; [ "$?" -ne 0 ]; }
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
    # Optional fractional syntax is observed, never treated as a prerequisite.
    for arg in 0.1 .1; do
        sleep "$arg" >/dev/null 2>&1; plain=$?
        busybox sleep "$arg" >/dev/null 2>&1; direct=$?
        printf 'HGVM_SLEEP=%s:plain=%s:busybox=%s\n' "$arg" "$plain" "$direct"
    done
    check integer_sleep busybox sleep 1
    check vendor_prerequisites apk --repositories-file /opt/hg-vm-lab/packages/repositories --no-network add coreutils-base64=9.9-r2 coreutils-stat=9.9-r2 coreutils-timeout=9.9-r2
    cat /tmp/hg-vm-lab/check.out
    sha256sum /etc/config/network /etc/config/firewall /etc/config/dhcp > /tmp/hg-vm-lab/network-config.sha256
    ip route show > /tmp/hg-vm-lab/routes.before
    nft -s list ruleset > /tmp/hg-vm-lab/nft.before
    timeout -k 1 1 /bin/true >/tmp/hg-vm-lab/timeout-probe 2>&1
    printf 'HGVM_DIAG=timeout_k_rc:%s\n' "$?"
    check procd_pid1 sh -c '[ "$(cat /proc/1/comm)" = procd ]'
    check ubus_service ubus list service
    mkdir -m 700 /etc/home-gateway-deploy
    check unfenced_receiver_status sh /usr/libexec/home-gateway-deploy/engine.sh status
    check unfenced_legacy_status sh /opt/hg-vm-lab/legacy-engine.sh status
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

    main_fixture=$(mktemp -d /tmp/hg-main-fixture.XXXXXX)
    cp /etc/config/passwall2 "$main_fixture/fixture-passwall2"
    main_engine=/usr/lib/home-gateway/incidents.uc
    main_intent() {
        HG_NOTIFICATION_STATE_DIR="$main_fixture" HG_MAIN_CONFIG_FILE="$main_fixture/fixture-passwall2" ucode "$main_engine" /usr/bin/gateway "$@"
    }
    prepare_main_fixture() {
        printf '{"schema_version":1,"phase":"PREPARED","id":"0123456789abcdef0123456789abcdef","candidate":"trial_node","before_sha256":"%s"}\n' "${before%% *}" |
            main_intent transaction-intent
    }
    check prepare_main_fixture prepare_main_fixture
    check stage_main_fixture main_intent transaction-stage
    check main_stage_keeps_live_config test "$(sha256sum /etc/config/passwall2)" = "$before"
    check main_snapshot_matches_live cmp "$main_fixture/main-intent.passwall2" /etc/config/passwall2
    main_candidate_dir="$LAB/main-candidate-read"
    mkdir -m 700 "$main_candidate_dir"
    if cp "$main_fixture/main-intent.candidate" "$main_candidate_dir/passwall2"; then
        check main_candidate_node test "$(uci -q -c "$main_candidate_dir" get passwall2.socks_P8ART.node)" = trial_node
    else
        check main_candidate_node false
    fi

    main_round_trip() {
        local target="$main_candidate_dir/passwall2"
        main_intent transaction-state > /tmp/hg-vm-lab/main-state.json || return 1
        local candidate_hash
        candidate_hash="$(json_value /tmp/hg-vm-lab/main-state.json data.transaction.candidate_sha256)"
        local actual
        actual="$(sha256sum "$target")" || return 1
        [ "${actual%% *}" = "$candidate_hash" ] || return 1
        cp "$main_fixture/main-intent.passwall2" "$target.restore" &&
            mv "$target.restore" "$target" &&
            cmp "$target" /etc/config/passwall2 &&
            [ "$(uci -q -c "$main_candidate_dir" get passwall2.socks_P8ART.node)" = old_node ]
    }
    fixture_lan_timeout_rollback() {
        local result=0
        HG_MAIN_FIXTURE_UPTIME=100 main_intent transaction-fixture-apply || return 1
        cmp "$main_fixture/fixture-passwall2" "$main_fixture/main-intent.candidate" || return 1
        printf '%s' '{"socks":"OK"}' |
            HG_MAIN_FIXTURE_UPTIME=115 main_intent transaction-fixture-verify || result=$?
        [ "$result" -eq 75 ] || return 1
        cmp "$main_fixture/fixture-passwall2" "$main_fixture/main-intent.candidate" || return 1
        printf '%s' '{"socks":"OK"}' |
            HG_MAIN_FIXTURE_UPTIME=131 main_intent transaction-fixture-verify || return 1
        main_intent transaction-fixture-restore || return 1
        cmp "$main_fixture/fixture-passwall2" /etc/config/passwall2
    }
    check main_fixture_lan_timeout_rollback fixture_lan_timeout_rollback
    check main_snapshot_round_trip main_round_trip

    fresh_main_fixture() {
        main_fixture=$(mktemp -d /tmp/hg-main-fixture.XXXXXX) || return 1
        cp /etc/config/passwall2 "$main_fixture/fixture-passwall2" &&
            prepare_main_fixture &&
            main_intent transaction-stage
    }
    fixture_watchdog() {
        fresh_main_fixture || return 1
        HG_MAIN_FIXTURE_WINDOW=1 main_intent transaction-fixture-apply || return 1
        main_intent transaction-fixture-watch || return 1
        cmp "$main_fixture/fixture-passwall2" /etc/config/passwall2
    }
    fixture_confirm_once() {
        fresh_main_fixture || return 1
        HG_MAIN_FIXTURE_UPTIME=100 main_intent transaction-fixture-apply > /tmp/hg-vm-lab/main-applied.json || return 1
        local token receipt
        token=$(json_value /tmp/hg-vm-lab/main-applied.json data.transaction.token) || return 1
        receipt=$(printf '{"socks":"OK","receipt":{"schema_version":1,"token":"%s","checks":[{"Target":"https://www.google.com/generate_204","HTTP":"204","CurlExit":0,"Passed":true},{"Target":"https://cp.cloudflare.com/","HTTP":"204","CurlExit":0,"Passed":true}]}}' "$token")
        printf '%s' "$receipt" | HG_MAIN_FIXTURE_UPTIME=101 main_intent transaction-fixture-verify > /tmp/hg-vm-lab/main-confirmed.json || return 1
        [ "$(json_value /tmp/hg-vm-lab/main-confirmed.json data.transaction.phase)" = COMMITTED ] || return 1
        local replay=0
        printf '%s' "$receipt" | HG_MAIN_FIXTURE_UPTIME=102 main_intent transaction-fixture-verify || replay=$?
        [ "$replay" -eq 75 ] && cmp "$main_fixture/fixture-passwall2" "$main_fixture/main-intent.candidate"
    }
    check main_fixture_watchdog fixture_watchdog
    check main_fixture_confirm_once fixture_confirm_once

    fixture_interrupted_restore() {
        fresh_main_fixture || return 1
        main_intent transaction-fixture-apply >/dev/null || return 1
        ucode -e 'import * as fs from "fs"; let p=ARGV[0]; let d=json(fs.readfile(p)); d.phase="RESTORING"; fs.writefile(p, sprintf("%J",d));' "$main_fixture/main-intent.json" || return 1
        main_intent transaction-fixture-watch || return 1
        cmp "$main_fixture/fixture-passwall2" /etc/config/passwall2
    }
    check main_fixture_interrupted_restore fixture_interrupted_restore

    fixture_watchdog_pid() {
        ubus call service list '{"name":"main-watchdog-fixture"}' |
            ucode -e 'import * as fs from "fs"; let d=json(fs.stdin.read(8192)); for (let i in values(d["main-watchdog-fixture"]?.instances ?? {})) if (type(i.pid) == "int" && i.running) { print(i.pid); break; }'
    }

    fixture_supervision() {
        fresh_main_fixture || return 1
        HG_MAIN_FIXTURE_WINDOW=12 main_intent transaction-fixture-apply >/dev/null || return 1
        local service="$LAB/main-watchdog-fixture"
        cat > "$service" <<'SERVICE'
#!/bin/sh /etc/rc.common
USE_PROCD=1
start_service() {
    [ "$(cat /etc/hg-disposable-vm)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || return 1
    local state
    state=$(cat /etc/hg-vm-lab/main-watchdog-state) || return 1
    procd_open_instance
    procd_set_param command /usr/bin/ucode /usr/lib/home-gateway/incidents.uc /usr/bin/gateway transaction-fixture-watch
    procd_set_param env HG_NOTIFICATION_STATE_DIR="$state" HG_MAIN_CONFIG_FILE="$state/fixture-passwall2"
    procd_set_param respawn 60 1 2
    procd_close_instance
}
SERVICE
        chmod 700 "$service"
        printf '%s\n' "$main_fixture" > "$LAB/main-watchdog-state"
        "$service" start || return 1
        local first next phase result=1
        for attempt in 1 2 3 4; do
            first=$(fixture_watchdog_pid)
            [ -n "$first" ] && break
            sleep 1
        done
        case "$first" in ''|*[!0-9]*) "$service" stop; return 1 ;; esac
        if kill -TERM "$first"; then
            for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
                next=$(fixture_watchdog_pid)
                phase=$(json_value "$main_fixture/main-intent.json" data.phase)
                if [ -n "$next" ] && [ "$first" != "$next" ] &&
                    [ "$phase" = ROLLED_BACK ] && cmp "$main_fixture/fixture-passwall2" /etc/config/passwall2; then
                    result=0
                    break
                fi
                sleep 1
            done
        fi
        "$service" stop
        return "$result"
    }
    check main_fixture_supervised_watchdog fixture_supervision

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
    check fsync_reports_errors sh -c 'busybox fsync /tmp/hg-vm-lab/nonexistent-fsync-probe; [ "$?" = 1 ]'
    check flash_tmp_different_filesystems sh -c '[ "$(stat -c %d /etc)" != "$(stat -c %d /tmp)" ]'
    mkdir -m 700 /tmp/hg-native-batch.vmtest
    mkdir -m 700 /tmp/hg-native-batch.vmtest/crash /tmp/hg-native-batch.vmtest/crash/etc
    printf 'DISPOSABLE\n' > /tmp/hg-native-batch.vmtest/.hg-deploy-test-root
    : > /tmp/hg-native-batch.vmtest/crash/etc/home-gateway-migration.lock
    ln -s /etc /tmp/hg-native-batch.vmtest/foreign
    check native_inventory_readonly ucode /opt/hg-vm-lab/native-batch-inventory.uc /tmp/hg-native-batch.vmtest
    check native_inventory_preserves_tree sh -c '[ "$(cat /tmp/hg-native-batch.vmtest/.hg-deploy-test-root)" = DISPOSABLE ] && [ "$(stat -c %s /tmp/hg-native-batch.vmtest/crash/etc/home-gateway-migration.lock)" = 0 ] && [ "$(readlink /tmp/hg-native-batch.vmtest/foreign)" = /etc ]'
    check migration_durable_state ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; let s=open_state("", true, null); s.fence(); s.transition("PREPARED"); s.transition("APPLYING");'
    ucode -e 'import * as fs from "fs"; import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; let s=open_state("", false, null); let p=fs.popen("sleep 5", "r"); fs.writefile("/tmp/hg-vm-lab/migration-held", "HELD\n"); p.read("all");' &
    owned_coordinator=$!
    tries=0
    while [ ! -f /tmp/hg-vm-lab/migration-held ] && [ "$tries" -lt 5 ]; do sleep 1; tries=$((tries + 1)); done
    check migration_owner_held test -f /tmp/hg-vm-lab/migration-held
    check migration_exclusive_while_alive refused ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; open_state("", false, null);'
    kill -KILL "$owned_coordinator"
    wait "$owned_coordinator" 2>/dev/null || true
    check migration_sigkill_releases_kernel_lock ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; let s=open_state("", false, null); exit(s.phase() == "APPLYING" ? 0 : 1);'
    check fence_blocks_real_legacy sh -c '! sh /opt/hg-vm-lab/legacy-engine.sh status'
    check persistent_admission_blocks sh -c '! sh /usr/libexec/home-gateway-deploy/migration-admission.sh'
    check network_config_unchanged sha256sum -c /tmp/hg-vm-lab/network-config.sha256
    ip route show > /tmp/hg-vm-lab/routes.after
    nft -s list ruleset > /tmp/hg-vm-lab/nft.after
    check routes_unchanged cmp -s /tmp/hg-vm-lab/routes.before /tmp/hg-vm-lab/routes.after
    check nft_unchanged cmp -s /tmp/hg-vm-lab/nft.before /tmp/hg-vm-lab/nft.after
    cat /proc/sys/kernel/random/boot_id > "$LAB/old-boot"
    touch "$LAB/reboot-pending"
    sync
    printf 'HGVM_REBOOT=REQUESTED\n'
    reboot -f
    exit 1
fi

check reboot_preserves_durable_phase ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; let s=open_state("", false, null); exit(s.phase() == "APPLYING" ? 0 : 1);'
check reboot_drops_ram_fence sh -c '[ ! -e /tmp/home-gateway-deploy.lock ] && [ ! -L /tmp/home-gateway-deploy.lock ]'
check reboot_blocks_interrupted_apply sh -c '! sh /usr/libexec/home-gateway-deploy/migration-admission.sh'
check receiver_blocks_interrupted_migration sh -c 'sh /usr/libexec/home-gateway-deploy/engine.sh status; [ "$?" = 73 ]'
check telegram_blocks_interrupted_migration sh -c '! /etc/init.d/home-gateway-telegram start'
ubus call service list '{"name":"home-gateway-telegram","verbose":true}' > /tmp/hg-vm-lab/telegram-procd.json
check telegram_has_no_procd_instances ucode -e 'import * as fs from "fs"; let data=json(fs.readfile("/tmp/hg-vm-lab/telegram-procd.json")); exit(length(keys(data["home-gateway-telegram"]?.instances || {})) == 0 ? 0 : 1);'
chmod 644 /etc/home-gateway-migration/phase
check admission_wrong_mode sh -c '! sh /usr/libexec/home-gateway-deploy/migration-admission.sh'
chmod 600 /etc/home-gateway-migration/phase
chown 65534:65534 /etc/home-gateway-migration/phase
check admission_wrong_uid_gid sh -c '! sh /usr/libexec/home-gateway-deploy/migration-admission.sh'
chown 0:0 /etc/home-gateway-migration/phase
ln /etc/home-gateway-migration/phase /etc/home-gateway-migration/phase-hardlink
check admission_hardlink sh -c '! sh /usr/libexec/home-gateway-deploy/migration-admission.sh'
rm /etc/home-gateway-migration/phase-hardlink
check interrupted_apply_not_replayed refused ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; let s=open_state("", false, null); s.transition("APPLYING");'
check reboot_reacquires_fence ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; let s=open_state("", false, null); s.fence();'
check reboot_changed_boot sh -c '[ "$(cat /etc/hg-vm-lab/old-boot)" != "$(cat /proc/sys/kernel/random/boot_id)" ]'
check reboot_persisted_hg sh -c 'for area in config secrets state; do [ "$(cat /etc/home-gateway/$area/vm-proof)" = SYNTHETIC_VM_BACKUP_PROOF ] || exit 1; done'
check recovery_projects_pending action show
phase=$(json_value /etc/home-gateway/state/actions.json 'data.records[length(data.records)-1].phase')
check reboot_pending_expires test "$phase" = EXPIRED
check reboot_does_not_restart_fixture test ! -e /tmp/hg-vm-lab/service-starts
# Synthetic terminal migration receipt: exercise subsequent receiver/service
# admission, not a claim that this VM performed the complete 18-to-20 migration.
printf 'COMMITTED\n' > /etc/home-gateway-migration/phase
ucode -e 'import * as fs from "fs"; let nonce=split(trim(fs.readfile("/etc/home-gateway-migration/marker")), " " )[1]; fs.writefile("/etc/home-gateway-migration/admission", "HG_MIGRATION_ADMITTED_V2 COMMITTED " + nonce + " " + fs.lstat("/etc/home-gateway-migration.lock").inode + "\n");'
chmod 600 /etc/home-gateway-migration/phase /etc/home-gateway-migration/admission
# The durable-state extension may have reacquired its own RAM fence above.
if [ -L /tmp/home-gateway-deploy.lock ]; then
    [ "$(readlink /tmp/home-gateway-deploy.lock)" = /etc/home-gateway-migration/fence ] || exit 78
    rm /tmp/home-gateway-deploy.lock
fi
mkdir -m 700 /etc/home-gateway-deploy/tx.vmgate /tmp/home-gateway-deploy.lock
printf '%s\n' "$$" > /tmp/home-gateway-deploy.lock/pid
printf 'tx.vmgate\n' > /etc/home-gateway-deploy/active
printf 'HGDEPLOY2\n' > /etc/home-gateway-deploy/tx.vmgate/inventory-version
sed 's@  /@  @' /opt/hg-vm-lab/runtime.sha256 > /etc/home-gateway-deploy/tx.vmgate/new.sha256
cp /etc/home-gateway-deploy/tx.vmgate/new.sha256 /etc/home-gateway-deploy/tx.vmgate/backup.sha256
printf 'CHECKING\n' > /etc/home-gateway-deploy/tx.vmgate/phase
chmod 600 /tmp/home-gateway-deploy.lock/pid /etc/home-gateway-deploy/active /etc/home-gateway-deploy/tx.vmgate/*
check terminal_telegram_checking sh /usr/libexec/home-gateway-deploy/migration-admission.sh --telegram-start
printf 'APPLYING\n' > /etc/home-gateway-deploy/tx.vmgate/phase
check terminal_telegram_blocks_mixed_apply sh -c '! sh /usr/libexec/home-gateway-deploy/migration-admission.sh --telegram-start'
printf 'RESTORED\n' > /etc/home-gateway-deploy/tx.vmgate/phase
check terminal_telegram_restored sh /usr/libexec/home-gateway-deploy/migration-admission.sh --telegram-start
# Keep the original inode only to restore this disposable fixture afterwards.
# The assertion is that missing-guard startup must not create ANY replacement.
mv /etc/home-gateway-migration.lock /etc/hg-vm-lab/saved-migration-guard
check terminal_missing_guard_start_refused refused /etc/init.d/home-gateway-telegram start
check terminal_missing_guard_not_recreated sh -c '[ ! -e /etc/home-gateway-migration.lock ] && [ ! -L /etc/home-gateway-migration.lock ]'
[ ! -e /etc/home-gateway-migration.lock ] && mv /etc/hg-vm-lab/saved-migration-guard /etc/home-gateway-migration.lock
# Observe the real procd ubus publication while rc.common still owns FD8.
mkdir -m 700 /tmp/hg-vm-lab/start-bin
HG_VM_REAL_UBUS=$(command -v ubus); export HG_VM_REAL_UBUS
cat > /tmp/hg-vm-lab/start-bin/ubus <<'SHIM'
#!/bin/sh
if [ "$1:$2:$3" = call:service:set ]; then
    ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; open_state("", false, null);' 2>/tmp/hg-vm-lab/start-guard-probe
    [ "$?" != 0 ] && grep -q BUSY /tmp/hg-vm-lab/start-guard-probe || exit 1
    touch /tmp/hg-vm-lab/start-guard-held
fi
exec "$HG_VM_REAL_UBUS" "$@"
SHIM
chmod 700 /tmp/hg-vm-lab/start-bin/ubus
check terminal_telegram_procd_start env PATH=/tmp/hg-vm-lab/start-bin:/usr/sbin:/usr/bin:/sbin:/bin /etc/init.d/home-gateway-telegram start
check terminal_startup_serialized test -f /tmp/hg-vm-lab/start-guard-held
check terminal_workers_do_not_inherit_guard ucode -e 'import { open_state } from "/opt/hg-vm-lab/migration-state.uc"; open_state("", false, null);'
ubus call service list '{"name":"home-gateway-telegram","verbose":true}' > /tmp/hg-vm-lab/telegram-terminal.json
check terminal_telegram_instances ucode -e 'import * as fs from "fs"; let d=json(fs.readfile("/tmp/hg-vm-lab/telegram-terminal.json")); exit(length(keys(d["home-gateway-telegram"]?.instances || {})) == 2 ? 0 : 1);'
check terminal_telegram_procd_stop /etc/init.d/home-gateway-telegram stop
rm /etc/home-gateway-deploy/active
printf '999999999\n' > /tmp/home-gateway-deploy.lock/pid
(set -C; : > /tmp/home-gateway-deploy.serial) || exit 78
chmod 600 /tmp/home-gateway-deploy.serial
exec 9< /tmp/home-gateway-deploy.serial
check terminal_receiver_serial_guard busybox flock -n 9
check terminal_concurrent_recover_refused sh -c '! sh /usr/libexec/home-gateway-deploy/engine.sh recover'
check terminal_stale_pid_preserved sh -c '[ "$(cat /tmp/home-gateway-deploy.lock/pid)" = 999999999 ]'
exec 9<&-
check terminal_receiver_stale_recovery sh /usr/libexec/home-gateway-deploy/engine.sh recover
check terminal_receiver_lease_removed test ! -e /tmp/home-gateway-deploy.lock
total=$(wc -l < "$LAB/checks.log")
failed=$(grep -c ':FAIL$' "$LAB/checks.log" || true)
[ "$failed" -eq 0 ] && status=PASS || status=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$status" "$total" "$failed"
sync
poweroff -f
