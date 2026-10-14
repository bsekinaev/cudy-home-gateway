#!/bin/sh
# Read-only ucode boundary; no Python, cleanup, services, UCI or nft changes.
set -eu
UCODE=/usr/bin/ucode
# Explicit disposable fixtures only; production has no executable override.
if [ "${1:-}" = --test-root ]; then
    UCODE=${HG_TEST_UCODE_BIN:-$(command -v ucode)}
    HG_TEST_BUSYBOX=$(command -v "${HG_TEST_BUSYBOX:-busybox}")
    export HG_TEST_BUSYBOX
fi
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec "$UCODE" -e "$(cat <<'UCODE'
import * as fs from 'fs';
function require(ok) { if (!ok) { warn('MIGRATION_ADMISSION=BLOCKED\n'); exit(73); } }
function quote(s) { return "'" + replace(s, "'", "'\\''") + "'"; }
function command(args) {
    let p=fs.popen(join(' ', map(args, quote)) + ' >/dev/null 2>&1', 'r');
    require(p != null); return p.close();
}
let args=[ ...ARGV ], root='', owner=0, group=0;
if (args[0] == '--test-root') {
    shift(args); root=shift(args);
    require(type(root) == 'string' && root != '/' && match(root, /^\/[A-Za-z0-9_.\/-]+$/) && !match(root, /(^|\/)\.\.?($|\/)/));
    let marker=fs.lstat(root + '/.hg-deploy-test-root'), top=fs.lstat(root);
    require(top?.type == 'directory' && marker?.type == 'file' && marker.nlink == 1 && marker.size <= 128 && marker.uid == top.uid && marker.gid == top.gid);
    owner=top.uid; group=top.gid;
}
let scope='default';
if (args[0] == '--receiver-recover') { scope='recover'; shift(args); }
else if (args[0] == '--telegram-start') { scope='telegram'; shift(args); }
let borrowed=scope == 'telegram' && args[0] == '--held-telegram-guard';
if (borrowed) shift(args);
require(length(args) == 0);
const BASE=root + '/etc/home-gateway-migration', FENCE=root + '/tmp/home-gateway-deploy.lock';
function checked(path, kind, mode, limit) {
    let parts=split(path, '/'), prefix='';
    for (let i=1; i<length(parts)-1; i++) {
        prefix += '/' + parts[i]; let s=fs.lstat(prefix);
        require(s?.type == 'directory' && (s.uid == 0 || s.uid == owner) && (!(s.mode & 022) || s.perm.sticky));
    }
    let s=fs.lstat(path);
    require(s?.type == kind && s.uid == owner && s.gid == group && s.mode == mode);
    if (kind == 'file') require(s.nlink == 1 && s.size <= limit);
    return s;
}
function read(path, limit) {
    let s=checked(path, 'file', 0600, limit), f=fs.open(path, 're'); require(f != null);
    let held=fs.stat('/proc/self/fd/' + f.fileno());
    require(held?.inode == s.inode && held.dev.major == s.dev.major && held.dev.minor == s.dev.minor);
    let raw=f.read(limit+1), closed=f.close(), after=fs.lstat(path);
    require(closed != null && type(raw) == 'string' && length(raw) == s.size && after?.inode == s.inode && after.size == s.size && after.mtime == s.mtime && after.type == s.type && after.dev.major == s.dev.major && after.dev.minor == s.dev.minor && after.uid == s.uid && after.gid == s.gid && after.mode == s.mode && after.nlink == s.nlink);
    return raw;
}
const LOCK=root + '/etc/home-gateway-migration.lock';
let guard=null, identity=null;
if (fs.lstat(BASE) != null || fs.lstat(LOCK) != null || borrowed) {
    let st=checked(LOCK, 'file', 0600, 0), held;
    if (borrowed) {
        held=fs.stat('/proc/self/fd/8');
        require(held?.inode == st.inode && held.dev.major == st.dev.major && held.dev.minor == st.dev.minor &&
            held.uid == owner && held.gid == group && held.mode == 0600 && held.nlink == 1 && held.size == 0);
        // FD8 belongs to rc.common's parent startup handshake. This child shares
        // its open file description; it must not unlock or close the parent FD.
        let bb=root == '' ? '/bin/busybox' : getenv('HG_TEST_BUSYBOX');
        require(type(bb) == 'string' && length(bb) > 0 && command([ bb, 'flock', '-n', '8' ]) == 0);
    } else {
        guard=fs.open(LOCK, 're'); require(guard != null);
        held=fs.stat('/proc/self/fd/' + guard.fileno());
        require(held?.inode == st.inode && held.dev.major == st.dev.major && held.dev.minor == st.dev.minor && guard.lock('xn') != null);
    }
    require(fs.lstat(LOCK)?.inode == held.inode);
    identity=st;
}
if (fs.lstat(BASE) == null) { require(fs.lstat(FENCE) == null); exit(0); }
let base_stat=checked(BASE, 'directory', 0700, 0);
require(identity.dev.major == base_stat.dev.major && identity.dev.minor == base_stat.dev.minor);
let marker=read(BASE + '/marker', 128);
require(match(marker, /^HG_MIGRATION_STATE_V1 [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\n$/) != null);
require(fs.lstat(BASE + '/phase.new') == null && fs.lstat(BASE + '/admission.new') == null);
let raw=read(BASE + '/phase', 32), phase=trim(raw);
require((phase == 'COMMITTED' || phase == 'ROLLED_BACK') && raw == phase + '\n');
require(read(BASE + '/admission', 128) == 'HG_MIGRATION_ADMITTED_V2 ' + phase + ' ' + trim(substr(marker, length('HG_MIGRATION_STATE_V1 '))) + ' ' + identity.inode + '\n');
let pid=null;
if (fs.lstat(FENCE) != null) {
    require(scope != 'default'); checked(FENCE, 'directory', 0700, 0);
    raw=read(FENCE + '/pid', 16); pid=trim(raw);
    require(match(pid, /^[1-9][0-9]{0,9}$/) && raw == pid + '\n');
    // The receiver owns liveness checking and stale lease cleanup. A symlink
    // migration fence cannot pass this regular directory/regular file check.
}
const PATHS=["etc/init.d/home-gateway-telegram", "usr/bin/gateway", "usr/bin/home-gateway-ci-smoke", "usr/lib/home-gateway/actions.uc", "usr/lib/home-gateway/asata.sh", "usr/lib/home-gateway/common.sh", "usr/lib/home-gateway/dns.sh", "usr/lib/home-gateway/doctor.sh", "usr/lib/home-gateway/health.sh", "usr/lib/home-gateway/incidents.uc", "usr/lib/home-gateway/network.sh", "usr/lib/home-gateway/notifications.uc", "usr/lib/home-gateway/redmi.sh", "usr/lib/home-gateway/selftest.sh", "usr/lib/home-gateway/status.sh", "usr/lib/home-gateway/tailscale.sh", "usr/lib/home-gateway/telegram-poller.uc", "usr/lib/home-gateway/telegram.sh", "usr/lib/home-gateway/torrent.sh", "usr/lib/home-gateway/vpn.sh"];
if (scope == 'telegram') {
    const DEPLOY=root + '/etc/home-gateway-deploy';
    if (fs.lstat(DEPLOY + '/active') != null) {
        checked(DEPLOY, 'directory', 0700, 0);
        raw=read(DEPLOY + '/active', 40); let id=trim(raw);
        require(match(id, /^tx\.[a-zA-Z0-9]{1,32}$/) && raw == id + '\n');
        let tx=DEPLOY + '/' + id; checked(tx, 'directory', 0700, 0);
        raw=read(tx + '/phase', 16); let stage=trim(raw);
        require(raw == stage + '\n' && index([ 'CHECKING', 'COMMITTED', 'RESTORED' ], stage) >= 0);
        require(read(tx + '/inventory-version', 10) == 'HGDEPLOY2\n');
        let manifest=tx + (stage == 'RESTORED' ? '/backup.sha256' : '/new.sha256');
        let bytes=read(manifest, 8192), rows=split(bytes, '\n');
        require(pop(rows) == '' && length(rows) == 20);
        let seen={};
        for (let row in rows) {
            let digest=substr(row, 0, 64), rel=substr(row, 66);
            require(match(digest, /^[0-9a-f]{64}$/) && substr(row, 64, 2) == '  ' && index(PATHS, rel) >= 0 && !seen[rel]); seen[rel]=true;
        }
        for (let path in PATHS) checked(root + '/' + path, 'file', index(PATHS, path) < 3 ? 0755 : 0644, 262144);
        // One bounded checksum process; avoid hundreds of stat subprocesses
        // within rc.common's startup budget on the actual target.
        let hash=fs.popen('cd ' + quote(root || '/') + ' && timeout -k 2 10 sha256sum -c ' + quote(manifest) + ' >/dev/null 2>&1', 'r');
        require(hash != null && hash.close() == 0);
        if (pid != null) require(command([ '/bin/kill', '-0', pid ]) == 0);
    } else require(pid == null);
}
print('MIGRATION_ADMISSION=ADMITTED\n');
UCODE
)" -- "$@"
