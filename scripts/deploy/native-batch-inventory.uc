// OWNER-EXECUTED read-only diagnostic. Never signals processes or mutates files.
import * as fs from 'fs';
function refuse(code) { die('NATIVE_BATCH_INVENTORY_REFUSED=' + code + '\n'); }
let lab = ARGV[0] == '--test-root';
let root = ARGV[lab ? 1 : 0];
if (length(ARGV) != (lab ? 2 : 1) || !match(root, /^\/tmp\/hg-native-batch\.[A-Za-z0-9_-]+$/)) refuse('ROOT');
let parent = fs.lstat('/tmp'), base = fs.lstat(root);
if (parent?.type != 'directory' || parent.uid != 0 || !parent.perm.sticky ||
    base?.type != 'directory' || base.mode != 0700) refuse('ROOT_METADATA');
function same(a, b) {
    return a?.inode == b?.inode && a.type == b.type && a.dev.major == b.dev.major &&
        a.dev.minor == b.dev.minor && a.uid == b.uid && a.gid == b.gid &&
        a.mode == b.mode && a.nlink == b.nlink && a.size == b.size;
}
let rootfd = fs.open(root, 're');
if (rootfd == null || !same(base, fs.stat('/proc/self/fd/' + rootfd.fileno()))) refuse('ROOT_CHANGED');
let anchored = '/proc/self/fd/' + rootfd.fileno() + '/.';
let owner = 0, group = 0;
if (lab) {
    let path = anchored + '/.hg-deploy-test-root', marker = fs.lstat(path);
    if (marker?.type != 'file' || marker.nlink != 1 || marker.mode != 0600 ||
        marker.uid != base.uid || marker.gid != base.gid || marker.size != 11) refuse('LAB_MARKER');
    let f = fs.open(path, 're');
    if (f == null || !same(marker, fs.stat('/proc/self/fd/' + f.fileno()))) refuse('LAB_MARKER');
    let raw = f.read(12), closed = f.close();
    if (closed == null || raw != 'DISPOSABLE\n' || !same(marker, fs.lstat(path))) refuse('LAB_MARKER');
    owner = base.uid; group = base.gid;
}
if (base.uid != owner || base.gid != group) refuse('ROOT_METADATA');
let records = [], guards = [], count = 0;
function walk(path, relative, depth) {
    if (++count > 128 || depth > 8) refuse('BOUND');
    let st = fs.lstat(path);
    if (st == null || st.dev.major != base.dev.major || st.dev.minor != base.dev.minor) refuse('CHANGED_OR_DEVICE');
    let record = { path: relative, type: st.type, uid: st.uid, gid: st.gid,
        mode: sprintf('%o', st.mode), nlink: st.nlink, size: st.size, inode: st.inode };
    if (st.type == 'link') record.target = fs.readlink(path);
    push(records, record);
    if (st.type == 'file' && match(relative, /(^|\/)home-gateway-migration\.lock$/))
        push(guards, { path: relative, key: sprintf('%02x:%02x:%d', st.dev.major, st.dev.minor, st.inode) });
    if (st.type == 'directory') {
        // Opening may race a substitution. Never enumerate until the held
        // descriptor matches lstat; all subsequent child lookups use that OFD.
        let dir = fs.open(path, 're');
        if (dir == null || !same(st, fs.stat('/proc/self/fd/' + dir.fileno()))) refuse('DIRECTORY_CHANGED');
        let anchor = '/proc/self/fd/' + dir.fileno() + '/.';
        let entries = fs.lsdir(anchor);
        if (entries == null || length(entries) + count > 128) refuse('DIRECTORY_BOUND');
        for (let name in sort(entries)) {
            if (name == '.' || name == '..' || index(name, '/') >= 0) refuse('DIRECTORY_ENTRY');
            walk(anchor + '/' + name, relative + '/' + name, depth + 1);
        }
        if (!same(st, fs.stat('/proc/self/fd/' + dir.fileno())) || dir.close() == null) refuse('DIRECTORY_CHANGED');
    }
    let after = fs.lstat(path);
    if (after?.inode != st.inode || after.type != st.type || after.mode != st.mode ||
        after.uid != st.uid || after.gid != st.gid || after.nlink != st.nlink || after.size != st.size)
        refuse('CHANGED');
}
walk(anchored, '.', 0);
// Only inspect kernel holders for guard inodes just inventoried in this tree.
let f = fs.open('/proc/locks', 're'), locks = f?.read(262145);
if (f == null || f.close() == null || type(locks) != 'string' || length(locks) > 262144) refuse('LOCK_BOUND');
let holders = [];
for (let line in split(locks, '\n')) {
    let fields = split(trim(line), /\s+/);
    if (length(fields) < 8 || fields[1] != 'FLOCK' || !match(fields[4], /^[1-9][0-9]*$/)) continue;
    for (let guard in guards) if (fields[5] == guard.key)
        push(holders, { guard: guard.path, kernel_pid: fields[4], proc_pid_visible: fs.lstat('/proc/' + fields[4])?.type == 'directory', type: fields[1], access: fields[3] });
}
let after = fs.lstat(root);
if (after?.inode != base.inode || after.mode != base.mode || after.uid != base.uid || after.gid != base.gid)
    refuse('ROOT_CHANGED');
if (rootfd.close() == null) refuse('ROOT_HANDLE');
printf('%J\n', { schema: 'HG_NATIVE_BATCH_INVENTORY_V1', root, entries: records,
    kernel_guard_holders: holders, mutations: 0,
    warning: 'PID identity and ownership are not established; do not signal or remove anything.' });
