#!/bin/sh
# Read-only manual audit. No receiver execution, service/UCI/nft changes or writes.
set -eu
ROOT=
if [ "${1:-}" = --test-root ]; then
    ROOT=$2
    case "$ROOT" in /*) ;; *) exit 64;; esac
    [ "$ROOT" != / ] && [ -f "$ROOT/.hg-migration-lab" ] || exit 64
    shift 2
else
    unset HG_TEST_BIN
fi
PATH=${HG_TEST_BIN:+$HG_TEST_BIN:}/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$#" -eq 1 ] || exit 64
pin=$1
[ "${#pin}" -eq 64 ] && ! printf '%s' "$pin" | grep -q '[^0-9a-f]' || exit 64
fail() { echo 'LEGACY_PREFLIGHT=REFUSED' >&2; exit 70; }
[ "$pin" = 4b1f9ea568167a67f24470615b31efe4b9fd7a68374e666443ad31945e58922e ] || fail
oldfiles() {
    cat <<'EOF'
etc/init.d/home-gateway-telegram
usr/bin/gateway
usr/bin/home-gateway-ci-smoke
usr/lib/home-gateway/asata.sh
usr/lib/home-gateway/common.sh
usr/lib/home-gateway/dns.sh
usr/lib/home-gateway/doctor.sh
usr/lib/home-gateway/health.sh
usr/lib/home-gateway/incidents.uc
usr/lib/home-gateway/network.sh
usr/lib/home-gateway/redmi.sh
usr/lib/home-gateway/selftest.sh
usr/lib/home-gateway/status.sh
usr/lib/home-gateway/tailscale.sh
usr/lib/home-gateway/telegram-poller.uc
usr/lib/home-gateway/telegram.sh
usr/lib/home-gateway/torrent.sh
usr/lib/home-gateway/vpn.sh
EOF
}
owner=0
group=0
if [ -n "$ROOT" ]; then owner=$(id -u); group=$(id -g); fi
safe() {
    path=$1; want=$2
    component=$path
    while [ "$component" != / ] && [ -n "$component" ]; do
        [ ! -L "$component" ] || fail
        if [ "$component" != "$path" ]; then
            [ -d "$component" ] || fail
            parent_owner=$(stat -c %u "$component")
            [ "$parent_owner" = 0 ] || [ "$parent_owner" = "$owner" ] || fail
            parent_mode=$(stat -c %a "$component")
            [ "$((0$parent_mode & 022))" = 0 ] || [ "$((0$parent_mode & 01000))" != 0 ] || fail
        fi
        component=${component%/*}
    done
    [ -f "$path" ] && [ "$(stat -c '%u:%g' "$path")" = "$owner:$group" ] &&
    [ "$(stat -c %h "$path")" = 1 ] && [ "$(stat -c %a "$path")" = "$want" ] &&
    [ "$(stat -c %s "$path")" -le 262144 ] || fail
}
manifest() {
    safe "$1" 600
    [ "$(stat -c %s "$1")" -le 8192 ] || fail
    awk -v expected="$(oldfiles)" '
    BEGIN {n=split(expected,p,"\n");for(i=1;i<=n;i++)wanted[p[i]]=1}
    {digest=substr($0,1,64);rel=substr($0,67);
     if(length(digest)!=64 || digest~/[^0-9a-f]/ || substr($0,65,2)!="  " || !wanted[rel] || seen[rel]++)bad=1}
    END {if(bad || NR!=n)exit 1}' "$1" || fail
}
BASE="$ROOT/etc/home-gateway-deploy"
[ -d "$BASE" ] && [ ! -L "$BASE" ] && [ "$(stat -c '%u:%g:%a' "$BASE")" = "$owner:$group:700" ] || fail
for path in "$BASE/active" "$ROOT/tmp/home-gateway-deploy.lock"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail
done
safe "$BASE/latest" 600
[ "$(stat -c %s "$BASE/latest")" -le 40 ] || fail
grep -Eq '^tx\.[a-zA-Z0-9]{1,32}$' "$BASE/latest" || fail
[ "$(wc -l < "$BASE/latest")" -eq 1 ] || fail
id=$(cat "$BASE/latest")
[ "$(stat -c %s "$BASE/latest")" -eq "$((${#id} + 1))" ] || fail
TX="$BASE/$id"
[ -d "$TX" ] && [ ! -L "$TX" ] && [ "$(stat -c '%u:%g:%a' "$TX")" = "$owner:$group:700" ] || fail
[ ! -e "$TX/inventory-version" ] && [ ! -L "$TX/inventory-version" ] || fail
safe "$TX/phase" 600
[ "$(stat -c %s "$TX/phase")" -eq 10 ] && [ "$(cat "$TX/phase")" = COMMITTED ] || fail
safe "$TX/was-running" 600
[ "$(stat -c %s "$TX/was-running")" -eq 2 ] || fail
case "$(cat "$TX/was-running")" in 0|1) ;; *) fail;; esac
safe "$TX/commit" 600
[ "$(stat -c %s "$TX/commit")" -eq 41 ] && grep -Eq '^[0-9a-f]{40}$' "$TX/commit" || fail
manifest "$TX/backup.sha256"
manifest "$TX/new.sha256"
for rel in $(oldfiles); do
    case "$rel" in etc/init.d/*|usr/bin/*) permissions=755;; *) permissions=644;; esac
    safe "$ROOT/$rel" "$permissions"
    safe "$TX/backup/$rel" "$permissions"
done
(cd "$TX/backup" && sha256sum -c ../backup.sha256 >/dev/null 2>&1) || fail
(cd "$ROOT/" && sha256sum -c "$TX/new.sha256" >/dev/null 2>&1) || fail
for rel in actions.uc notifications.uc; do
    [ ! -e "$ROOT/usr/lib/home-gateway/$rel" ] && [ ! -L "$ROOT/usr/lib/home-gateway/$rel" ] || fail
done
for rel in engine.sh wrapper.sh; do safe "$ROOT/usr/libexec/home-gateway-deploy/$rel" 700; done
safe "$ROOT/etc/init.d/home-gateway-deploy-recover" 755
[ "$(sha256sum "$ROOT/usr/libexec/home-gateway-deploy/engine.sh" | cut -d ' ' -f1)" = "$pin" ] || fail
[ "$(sha256sum "$ROOT/usr/libexec/home-gateway-deploy/wrapper.sh" | cut -d ' ' -f1)" = d8694eb76c86f16dbae2599e8d68e20dfcf9d8334a488f0f407c84264099946f ] || fail
[ "$(sha256sum "$ROOT/etc/init.d/home-gateway-deploy-recover" | cut -d ' ' -f1)" = 5b747dff42649914e4b231de2d5ade0171eedad40d5fb53f43e4d869d08a2630 ] || fail
echo 'LEGACY_PREFLIGHT=VERIFIED INVENTORY=18 MUTATIONS=0 MIGRATION_ACCEPTED=false'
