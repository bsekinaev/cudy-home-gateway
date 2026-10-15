#!/bin/sh
# Host regression against upstream BusyBox 1.37.0; never install on a router.
set -eu
[ "$#" -eq 0 ] || exit 64
cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
archive="$work/busybox-1.37.0.tar.bz2"
curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 \
    https://busybox.net/downloads/busybox-1.37.0.tar.bz2 -o "$archive"
printf '%s  %s\n' 3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4 "$archive" | sha256sum -c -
# Extraction is permitted only after the exact source archive SHA is pinned.
tar -xjf "$archive" -C "$work"
make -C "$work/busybox-1.37.0" defconfig > "$work/config.log" 2>&1
# tc's obsolete CBQ structures are absent in current host headers. It is not
# exercised or installed; preserve all shell/filesystem/process applets.
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' "$work/busybox-1.37.0/.config"
if ! make -C "$work/busybox-1.37.0" -j2 > "$work/build.log" 2>&1; then
    tail -60 "$work/build.log" >&2
    exit 1
fi
mkdir "$work/bin"
ln -s "$work/busybox-1.37.0/busybox" "$work/bin/busybox"
PATH="$work/bin:$PATH"
export PATH
busybox ash -c 'echo BUSYBOX_1_37_ASH_READY'
busybox --list | grep -Fx fsync
busybox --list | grep -Fx flock
./scripts/ci/check.sh
HG_TEST_SHELL='busybox ash' HG_TEST_BUSYBOX=busybox \
    python3 -m unittest discover -s scripts/deploy -p 'test_*.py' -v

HG_TEST_BUSYBOX_PATH="$work/bin/busybox" HG_TEST_BIN="$work/bin" \
    python3 -m unittest discover -s scripts/migration_rc -p 'test_*.py' -v
