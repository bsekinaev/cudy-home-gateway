#!/bin/sh
# Unmodified global-root installer, ONLY in marked networkless disposable VM.
set -u
umask 077
[ "$(uname -m)" = x86_64 ] && [ "$(cat /etc/hg-disposable-vm 2>/dev/null)" = HG_NETWORKLESS_OPENWRT_VM_V1 ] || exit 77
LAB=/tmp/hg-rc-b-acceptance
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
check repeated_apply_refused refused "$kit/rc-b.sh" apply "$pin" "$nonce" "$source:$nonce"
check private_unchanged_after_install sha256sum -c "$LAB/private.sha256"
check rollback "$kit/rc-b.sh" rollback "$pin" "$nonce"
check rollback_verified "$kit/rc-b.sh" verify "$pin" "$nonce"
check repeated_rollback "$kit/rc-b.sh" rollback "$pin" "$nonce"
check restored_latest cmp "$LAB/latest" /etc/home-gateway-deploy/latest
check restored_legacy_journal sha256sum -c "$LAB/legacy-journal.sha256"
check rolled_back sh -c '[ "$(cat /etc/home-gateway-migration/phase)" = ROLLED_BACK ] && [ ! -e /tmp/home-gateway-deploy.lock ] && [ -L /etc/rc.d/S95home-gateway-telegram ] && [ ! -e /usr/lib/home-gateway/actions.uc ] && [ ! -e /usr/lib/home-gateway/notifications.uc ]'
check private_unchanged_after_rollback sha256sum -c "$LAB/private.sha256"
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
