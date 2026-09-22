#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$ROOT"

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

pass() {
    printf '[PASS] %s\n' "$*"
}

printf 'CUDY Home Gateway — CI checks\n\n'

# Tracked secret/private deployment files must never enter Git.
tracked_forbidden="$(
    git ls-files |
        grep -E '(^|/)(secrets?|state|cache|local)(/|$)|(^|/)\.env$|\.(key|pem|token|state)$' || true
)"

if [ -n "$tracked_forbidden" ]; then
    printf '%s\n' "$tracked_forbidden" >&2
    fail 'forbidden secret/runtime paths are tracked'
fi
pass 'tracked-file secret policy'

# Catch obvious private-key / Telegram-token material in tracked text files.
secret_hits="$(
    git grep -n -I -E \
        -- '-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|[0-9]{8,12}:[A-Za-z0-9_-]{30,}' \
        -- . ':!docs/CI_CD.md' 2>/dev/null || true
)"

if [ -n "$secret_hits" ]; then
    printf '%s\n' "$secret_hits" >&2
    fail 'possible secret material found'
fi
pass 'content secret scan'

# Runtime scripts must remain LF-only.
cr="$(printf '\r')"
crlf_hits="$(
    grep -RIl "$cr" src scripts .github 2>/dev/null || true
)"

if [ -n "$crlf_hits" ]; then
    printf '%s\n' "$crlf_hits" >&2
    fail 'CRLF found in runtime/CI files'
fi
pass 'LF line endings'

# Executable deployment entrypoints.
[ -x src/usr/bin/gateway ] || fail 'src/usr/bin/gateway is not executable'
[ -x src/etc/init.d/home-gateway-telegram ] || fail 'Telegram init script is not executable'
[ -x scripts/router-preflight.sh ] || fail 'router-preflight.sh is not executable'
[ -x scripts/ci/check.sh ] || fail 'scripts/ci/check.sh is not executable'
pass 'executable modes'

# BusyBox/POSIX shell syntax.
for file in \
    scripts/router-preflight.sh \
    scripts/ci/check.sh \
    src/usr/bin/gateway \
    src/etc/init.d/home-gateway-telegram \
    src/usr/lib/home-gateway/*.sh
do
    sh -n "$file" || fail "shell syntax: $file"
done
pass 'shell syntax'

command -v ucode >/dev/null 2>&1 || fail 'ucode is unavailable in CI'

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

for file in src/usr/lib/home-gateway/*.uc; do
    out="$tmp_dir/$(basename "$file").compiled"
    ucode -c -o "$out" "$file" || fail "ucode syntax: $file"
done
pass 'ucode syntax'

# Deterministic state-machine contract that does not require OpenWrt runtime.
ucode \
    src/usr/lib/home-gateway/incidents.uc \
    src/usr/bin/gateway \
    selftest |
    grep -q '^incidents-selftest: PASS$' ||
    fail 'Incident Engine deterministic selftest'
pass 'Incident Engine deterministic selftest'

# Ensure public runtime never contains universal remote shell primitives.
if git grep -n -I -E \
    -- '/exec|gateway[[:space:]]+exec|shell-console|arbitrary[[:space:]]+uci' \
    -- src >/dev/null 2>&1
then
    fail 'forbidden universal remote-control surface found'
fi
pass 'remote-control safety contract'

printf '\nCI_RESULT=PASS\n'
