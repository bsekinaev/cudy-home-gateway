#!/bin/sh
# Trusted receiver. Only wrapper.sh is exposed as an SSH forced command.
set -eu
umask 077
ROOT=
if [ "${1:-}" = --test-root ]; then
    ROOT=$2
    [ "$ROOT" != / ] && [ -f "$ROOT/.hg-deploy-test-root" ] || exit 64
    shift 2
fi
BASE="$ROOT/etc/home-gateway-deploy"
LOCK="$ROOT/tmp/home-gateway-deploy.lock"
WORK=
TX=
ARMED=0
[ -n "$ROOT" ] || unset HG_TEST_BIN
PATH=${HG_TEST_BIN:+$HG_TEST_BIN:}/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset HG_LIBDIR ENV BASH_ENV
files() {
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
fail() { echo "DEPLOY_ERROR: $*" >&2; exit 1; }
hex() { [ "${#1}" -eq "$2" ] && ! printf '%s' "$1" | grep -q '[^0-9a-f]'; }
phase() { printf '%s\n' "$1" > "$TX/phase.new" || return 1; mv "$TX/phase.new" "$TX/phase" || return 1; sync; }
pointer() { printf '%s\n' "${TX##*/}" > "$BASE/$1.new" || return 1; mv "$BASE/$1.new" "$BASE/$1" || return 1; sync; }
load_tx() {
    id=$(cat "$BASE/$1") || return 1
    case "$id" in tx.*) ;; *) return 1;; esac
    case "$id" in *[!a-zA-Z0-9.]*|*..*) return 1;; esac
    TX="$BASE/$id"
    [ -d "$TX" ] && [ ! -L "$TX" ]
}
safe_live() {
    for rel in $(files); do
        part="$ROOT"
        oldifs=$IFS; IFS=/; set -- $rel; IFS=$oldifs
        for component do
            part="$part/$component"
            [ ! -L "$part" ] || fail "symlink: $rel"
        done
        [ -f "$ROOT/$rel" ] || fail "upgrade requires existing regular file: $rel"
        [ "$(stat -c %u "$ROOT/$rel")" = 0 ] || [ -n "$ROOT" ] || fail "non-root owner: $rel"
    done
}
service() { timeout 30 "$ROOT/etc/init.d/home-gateway-telegram" "$1"; }
wait_running() {
    tries=0
    while ! service running >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -lt 5 ] || return 1
        sleep 1
    done
    sleep 2
    service running >/dev/null 2>&1
}
checks() {
    for check in version selftest doctor health; do
        timeout 90 "$ROOT/usr/bin/gateway" "$check" >> "$1" 2>&1 || return 1
    done
}
replace() {
    # cp + rename on the target filesystem; no in-place truncation.
    src=$1; dst=$2
    tmp=$(mktemp "$dst.hg-deploy.XXXXXX") || return 1
    cp -p "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    sync
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}
restore() {
    # Explicit error checks: this function is also used from the EXIT trap.
    phase RESTORING || return 1
    (cd "$TX/backup" && sha256sum -c ../backup.sha256 >/dev/null) || return 1
    safe_live || return 1
    service stop >> "$TX/service.log" 2>&1 || return 1
    if service running >/dev/null 2>&1; then return 1; fi
    for rel in $(files); do
        replace "$TX/backup/$rel" "$ROOT/$rel" || return 1
        cmp -s "$TX/backup/$rel" "$ROOT/$rel" || return 1
        [ "$(stat -c '%a:%u:%g' "$TX/backup/$rel")" = "$(stat -c '%a:%u:%g' "$ROOT/$rel")" ] || return 1
    done
    sync
    phase RESTORED || return 1
    if [ "$(cat "$TX/was-running")" = 1 ]; then
        service start >> "$TX/service.log" 2>&1 || return 1
        wait_running || return 1
    fi
    # Restoration is byte/mode verified even when the network remains unhealthy.
    phase ROLLED_BACK || return 1
    rm -f "$BASE/active" || return 1
    sync
}
finish() {
    rc=$?
    trap - EXIT INT TERM
    if [ "$ARMED" = 1 ] && [ "$rc" != 0 ]; then
        if restore; then
            echo 'DEPLOY_RESULT=ROLLED_BACK' >&2
        else
            echo 'DEPLOY_RESULT=RECOVERY_REQUIRED (run recover over LAN)' >&2
        fi
    fi
    [ -z "$WORK" ] || rm -rf "$WORK"
    rm -rf "$LOCK"
    exit "$rc"
}
[ "$(id -u)" = 0 ] || [ -n "$ROOT" ] || fail 'root required'
[ -d "$BASE" ] && [ ! -L "$BASE" ] || fail 'bootstrap required'
command=${1:-}; shift || exit 64
case "$command" in plan|apply) [ "$#" -eq 2 ] && hex "$1" 40 && hex "$2" 64 || exit 64;;
    status|recover|rollback) [ "$#" -eq 0 ] || exit 64;; *) exit 64;; esac
if ! mkdir "$LOCK" 2>/dev/null; then
    owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    case "$owner" in ''|*[!0-9]*) fail 'lock incomplete; inspect locally';; esac
    if kill -0 "$owner" 2>/dev/null; then fail 'another deployment is running'; fi
    [ "$command" = recover ] || fail 'stale lock; run recover'
    rm -rf "$LOCK"
    mkdir "$LOCK" || fail 'lock race'
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Finish/rollback if SSH disconnects after the request is fully received.
trap '' HUP PIPE
case "$command" in
    status)
        if [ -f "$BASE/active" ]; then load_tx active; echo "ACTIVE=${TX##*/} PHASE=$(cat "$TX/phase")";
        elif [ -f "$BASE/latest" ]; then load_tx latest; echo "LATEST=${TX##*/} PHASE=$(cat "$TX/phase")";
        else echo 'DEPLOY_STATUS=NO_DEPLOYMENTS'; fi
        exit 0;;
    recover)
        if [ -f "$BASE/active" ]; then
            load_tx active
            if [ "$(cat "$TX/phase")" = COMMITTED ]; then
                pointer latest; rm -f "$BASE/active"; sync
            else restore || fail 'recovery failed'; fi
            echo RECOVERY_OK;
        else echo RECOVERY_NOT_NEEDED; fi
        exit 0;;
    rollback)
        [ ! -f "$BASE/active" ] || fail 'recover interrupted transaction first'
        load_tx latest || fail 'no successful deployment to roll back'
        [ "$(cat "$TX/phase")" = COMMITTED ] || fail 'latest deployment already rolled back'
        safe_live
        (cd "$ROOT/" && sha256sum -c "$TX/new.sha256" >/dev/null) || fail 'live drift; refusing rollback'
        for rel in $(files); do
            case "$rel" in etc/init.d/*|usr/bin/*) expected_mode=755;; *) expected_mode=644;; esac
            [ "$(stat -c %a "$ROOT/$rel")" = "$expected_mode" ] || fail 'mode drift; refusing rollback'
        done
        pointer active
        restore || fail 'rollback failed; recover required'
        echo DEPLOY_RESULT=ROLLED_BACK
        exit 0;;
esac
[ ! -f "$BASE/active" ] || fail 'recover interrupted transaction first'
commit=$1; request_hash=$2
WORK=$(mktemp -d "$ROOT/tmp/hg-deploy.XXXXXX")
# Hard transfer timeout and byte limit; no remote archive extraction.
timeout 60 head -c 1048577 > "$WORK/request"
[ "$(wc -c < "$WORK/request")" -le 1048576 ] || fail 'request too large'
[ "$(sha256sum "$WORK/request" | cut -d ' ' -f1)" = "$request_hash" ] || fail 'request checksum mismatch'
exec 3< "$WORK/request"
IFS= read -r header <&3 || fail 'missing header'
[ "$header" = "HGDEPLOY1 $commit" ] || fail 'bad header'
for rel in $(files); do
    IFS=' ' read -r mode size digest extra <&3 || fail 'truncated metadata'
    [ -z "$extra" ] && hex "$digest" 64 || fail 'bad metadata'
    case "$size" in ''|*[!0-9]*) fail 'bad size';; esac
    [ "${#size}" -le 6 ] && [ "$size" -le 262144 ] || fail 'file too large'
    case "$rel" in etc/init.d/*|usr/bin/*) [ "$mode" = 0755 ] || fail 'entrypoint mode';;
        *) [ "$mode" = 0644 ] || fail 'library mode';; esac
    IFS= read -r encoded <&3 || fail 'truncated data'
    mkdir -p "$WORK/payload/${rel%/*}"
    printf '%s' "$encoded" | base64 -d > "$WORK/payload/$rel" || fail 'bad base64'
    [ "$(wc -c < "$WORK/payload/$rel")" -eq "$size" ] || fail 'file size mismatch'
    [ "$(sha256sum "$WORK/payload/$rel" | cut -d ' ' -f1)" = "$digest" ] || fail 'file checksum mismatch'
    chmod "$mode" "$WORK/payload/$rel"
    case "$rel" in *.uc) ucode -c -o "$WORK/check.uc" "$WORK/payload/$rel";;
        *) sh -n "$WORK/payload/$rel";; esac
    printf '%s  %s\n' "$digest" "$rel" >> "$WORK/new.sha256"
done
IFS= read -r end <&3 || fail 'missing end marker'
[ "$end" = END ] || fail 'bad end marker'
if IFS= read -r extra <&3 || [ -n "$extra" ]; then fail 'trailing data'; fi
exec 3<&-
safe_live
changed=0
for rel in $(files); do
    if cmp -s "$WORK/payload/$rel" "$ROOT/$rel" &&
       [ "$(stat -c '%a:%u:%g' "$WORK/payload/$rel")" = "$(stat -c '%a:%u:%g' "$ROOT/$rel")" ]; then
        echo "SAME $rel"
    else echo "UPDATE $rel"; changed=$((changed + 1)); fi
done
echo "PLAN_COMMIT=$commit CHANGED=$changed"
[ "$command" != plan ] || exit 0
[ "$changed" != 0 ] || { echo DEPLOY_RESULT=NO_CHANGE; exit 0; }
# Require space for staging + backup + rollback renames with a generous reserve.
need=$(( $(du -sk "$WORK/payload" | cut -f1) * 3 + 4096 ))
avail=$(df -Pk "$BASE" | awk 'END {print $4}')
[ "$avail" -ge "$need" ] || fail 'insufficient persistent space'
checks "$WORK/preflight.log" || fail 'current gateway preflight failed'
TX=$(mktemp -d "$BASE/tx.XXXXXXXX")
printf '%s\n' "$commit" > "$TX/commit"
cp "$WORK/new.sha256" "$TX/new.sha256"
cp "$WORK/preflight.log" "$TX/preflight.log"
if service running >/dev/null 2>&1; then echo 1 > "$TX/was-running"; else echo 0 > "$TX/was-running"; fi
for rel in $(files); do
    mkdir -p "$TX/backup/${rel%/*}"
    cp -p "$ROOT/$rel" "$TX/backup/$rel"
done
(cd "$TX/backup"; for rel in $(files); do sha256sum "$rel"; done) > "$TX/backup.sha256"
(cd "$TX/backup" && sha256sum -c ../backup.sha256 >/dev/null)
phase PREPARED
pointer active
ARMED=1
phase APPLYING
service stop >> "$TX/service.log" 2>&1
if service running >/dev/null 2>&1; then fail 'Telegram did not stop'; fi
for rel in $(files); do replace "$WORK/payload/$rel" "$ROOT/$rel"; done
sync
phase CHECKING
(cd "$ROOT/" && sha256sum -c "$TX/new.sha256" >/dev/null)
checks "$TX/postflight.log" || fail 'post-deploy checks failed'
if [ "$(cat "$TX/was-running")" = 1 ]; then
    service start >> "$TX/service.log" 2>&1
    wait_running || fail 'Telegram did not remain running'
fi
phase COMMITTED
pointer latest
rm -f "$BASE/active"
sync
ARMED=0
echo "DEPLOY_RESULT=PASS COMMIT=$commit TRANSACTION=${TX##*/}"
