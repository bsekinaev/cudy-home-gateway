#!/bin/sh
# Only an explicitly marked networkless disposable x86 guest; never CUDY.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/tmp/hg-rc-acceptance
mkdir -m 700 "$LAB"
: > "$LAB/checks"
check() {
    name=$1; shift
    if "$@" >"$LAB/output" 2>&1; then outcome=PASS; else outcome=FAIL; fi
    printf 'HGVM_CHECK=%s:%s\n' "$name" "$outcome" | tee -a "$LAB/checks"
    cat "$LAB/output"
}
refused() { "$@"; [ "$?" -ne 0 ]; }
check openwrt_release grep -q "DISTRIB_RELEASE='25.12.5'" /etc/openwrt_release
check procd_pid1 sh -c '[ "$(cat /proc/1/comm)" = procd ]'
check vendor_prerequisites apk --repositories-file /opt/hg-vm-lab/packages/repositories --no-network add coreutils-base64=9.9-r2 coreutils-stat=9.9-r2 coreutils-timeout=9.9-r2
sha256sum /etc/config/network /etc/config/firewall /etc/config/dhcp > "$LAB/network.sha256"
ip route show > "$LAB/routes"
nft -s list ruleset > "$LAB/nft"
KIT="$LAB/kit"
mkdir -m 700 "$KIT"
check package_extract tar -xzpf /opt/hg-vm-lab/rc-a.tar.gz -C "$KIT"
check package_identity ucode "$KIT/rc-a.uc" "$KIT" check /bin/busybox
# Public synthetic legacy only, in this marked disposable guest's real root.
cp -Rp "$KIT/fixture/." /
rm /usr/lib/home-gateway/actions.uc /usr/lib/home-gateway/notifications.uc
mkdir -m 700 /etc/home-gateway-deploy
pin=$(sha256sum "$KIT/legacy.wire"); pin=${pin%% *}
check guest_legacy_seed sh /usr/libexec/home-gateway-deploy/engine.sh apply bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$pin" < "$KIT/legacy.wire"
find /etc/home-gateway-deploy /usr/lib/home-gateway /usr/libexec/home-gateway-deploy -type f -exec sha256sum '{}' ';' > "$LAB/legacy.sha256"
sha256sum /etc/init.d/home-gateway-telegram /etc/init.d/home-gateway-deploy-recover /usr/bin/gateway /usr/bin/home-gateway-ci-smoke >> "$LAB/legacy.sha256"
check production_preflight_readonly sh "$KIT/rc-a.sh" preflight
check isolated_prepare sh "$KIT/rc-a.sh" prepare
root=$(sed -n 's/^RC_LAB=//p' "$LAB/output")
case "$root" in /tmp/hgdeploy2-rc-a.??????) ;; *) root=/invalid-root;; esac
check isolated_apply sh "$KIT/rc-a.sh" apply "$root"
check isolated_verify sh "$KIT/rc-a.sh" verify "$root"
check isolated_reapply_refused refused sh "$KIT/rc-a.sh" apply "$root"
check isolated_rollback sh "$KIT/rc-a.sh" rollback "$root"
check isolated_repeat_rollback sh "$KIT/rc-a.sh" rollback "$root"
check production_apply_unavailable refused sh "$KIT/rc-a.sh" production-apply
check production_root_refused refused sh "$KIT/rc-a.sh" apply /
check network_configs_unchanged sha256sum -c "$LAB/network.sha256"
ip route show > "$LAB/routes.after"
nft -s list ruleset > "$LAB/nft.after"
check routes_unchanged cmp "$LAB/routes" "$LAB/routes.after"
check firewall_unchanged cmp "$LAB/nft" "$LAB/nft.after"
check installed_legacy_unchanged sha256sum -c "$LAB/legacy.sha256"
printf 'RC_A_SERVICE_LIFECYCLE=NOT_TESTED PRODUCTION_APPLY=BLOCKED\n'
total=$(wc -l < "$LAB/checks");failed=$(grep -c ':FAIL$' "$LAB/checks")
result=PASS; [ "$failed" = 0 ] || result=FAIL
printf 'HGVM_RESULT=%s TOTAL=%s FAILED=%s SCOPE=ISOLATED_X86_NOT_CUDY\n' "$result" "$total" "$failed"
sync
poweroff -f
