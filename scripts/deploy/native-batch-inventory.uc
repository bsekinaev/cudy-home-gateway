// OWNER-EXECUTED read-only diagnostic. Never signals processes or mutates files.
import * as fs from 'fs';
function refuse(code) { die('NATIVE_BATCH_INVENTORY_REFUSED=' + code + '\n'); }
let lab = ARGV[0] == '--test-root';
let root = ARGV[lab ? 1 : 0];
if (length(ARGV) != (lab ? 2 : 1) || !match(root, /^\/tmp\/hg-native-batch\.[A-Za-z0-9_-]+$/)) refuse('ROOT');
let parent = fs.lstat('/tmp'), base = fs.lstat(root);
let owner = 0, group = 0;
if (lab) {
    let marker = fs.lstat(root + '/.hg-deploy-test-root');
    if (marker?.type != 'file' || marker.nlink != 1 || marker.mode != 0600 ||
        marker.uid != base?.uid || marker.gid != base?.gid || marker.size != 11 ||
        fs.readfile(root + '/.hg-deploy-test-root') != 'DISPOSABLE\n') refuse('LAB_MARKER');
    owner = base.uid; group = base.gid;
}
if (parent?.type != 'directory' || parent.uid != 0 || !parent.perm.sticky ||
    base?.type != 'directory' || base.uid != owner || base.gid != group || base.mode != 0700) refuse('ROOT_METADATA');
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
        let entries = fs.lsdir(path);
        if (entries == null || length(entries) + count > 128) refuse('DIRECTORY_BOUND');
        for (let name in sort(entries)) walk(path + '/' + name, relative + '/' + name, depth + 1);
    }
    let after = fs.lstat(path);
    if (after?.inode != st.inode || after.type != st.type || after.mode != st.mode ||
        after.uid != st.uid || after.gid != st.gid || after.nlink != st.nlink || after.size != st.size)
        refuse('CHANGED');
}
walk(root, '.', 0);
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
printf('%J\n', { schema: 'HG_NATIVE_BATCH_INVENTORY_V1', root, entries: records,
    kernel_guard_holders: holders, mutations: 0,
    warning: 'PID identity and ownership are not established; do not signal or remove anything.' });
