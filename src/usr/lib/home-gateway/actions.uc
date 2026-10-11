#!/usr/bin/env ucode
'use strict';
import * as fs from 'fs';

const MODE = ARGV[0] || 'show';
const STATE_DIR = getenv('HG_ACTION_STATE_DIR') || '/etc/home-gateway/state';
const RUNTIME_DIR = getenv('HG_ACTION_RUNTIME_DIR') || '/tmp/home-gateway';
const SECRETS_DIR = getenv('HG_ACTION_SECRETS_DIR') || '/etc/home-gateway/secrets';
const INIT_DIR = getenv('HG_ACTION_INIT_DIR') || '/etc/init.d';
const OWNER = fs.stat('/proc/self')?.uid;
const STATE = STATE_DIR + '/actions.json';
let ENABLED = false;
const SERVICES = { 'restart-tailscale': 'tailscale', 'restart-uhttpd': 'uhttpd' };
const PHASES = [ 'PENDING', 'EXECUTING', 'DONE', 'FAILED', 'UNKNOWN', 'EXPIRED', 'CANCELLED', 'ACKNOWLEDGED' ];
const BOOT = trim(fs.readfile('/proc/sys/kernel/random/boot_id') || '');

function fail(code, reason) { print({ schema_version: 1, status: reason }, '\n'); exit(code); }
function quote(s) { return `'${replace(`${s}`, "'", "'\\''")}'`; }
function command(args) {
    let p = fs.popen(join(' ', map(args, quote)) + ' >/dev/null 2>&1', 'r');
    if (!p) return 127;
    p.read(1);
    return p.close();
}
function private_dir(path) {
    let root = fs.lstat('/');
    if (root?.uid != 0 || ((root.perm.group_write || root.perm.other_write) && !root.perm.sticky)) fail(70, 'UNSAFE_DIRECTORY');
    if (type(OWNER) != 'int' || !match(path, /^\/[a-zA-Z0-9_./-]+$/) || index(path, '//') >= 0) fail(70, 'UNSAFE_DIRECTORY');
    if (path == '/' || path == '/tmp' || length(filter(split(path, '/'), p => length(p))) < 2 || substr(path, -1) == '/') fail(70, 'UNSAFE_DIRECTORY');
    let existing = fs.lstat(path);
    if (existing != null && (existing.type != 'directory' || existing.uid != OWNER || (existing.mode & 07777) != 0700)) fail(70, 'UNSAFE_DIRECTORY');
    let prefix = '';
    for (let part in split(path, '/')) {
        if (!length(part)) continue;
        if (part == '.' || part == '..') fail(70, 'UNSAFE_DIRECTORY');
        prefix += '/' + part;
        let st = fs.lstat(prefix);
        if (st == null) {
            if (command([ '/bin/mkdir', '-m', '700', prefix ]) != 0) fail(70, 'DIRECTORY_FAILED');
            st = fs.lstat(prefix);
        }
        if (st?.type != 'directory' || (st.uid != 0 && st.uid != OWNER) ||
            (prefix == path && st.uid != OWNER) ||
            (prefix != path && (st.perm.group_write || st.perm.other_write) && !st.perm.sticky)) fail(70, 'UNSAFE_DIRECTORY');
    }
    if ((fs.lstat(path).mode & 07777) != 0700) fail(70, 'UNSAFE_DIRECTORY');
}
function bounded(path, limit) {
    let st = fs.lstat(path);
    if (st == null) return null;
    if (st.type != 'file' || (st.uid != 0 && st.uid != OWNER) || st.perm.group_write || st.perm.other_write || st.size > limit) fail(70, 'INVALID_FILE');
    let f = fs.open(path, 're');
    if (!f) fail(70, 'READ_FAILED');
    let raw = f.read(limit + 1);
    let closed = f.close();
    if (raw == null || length(raw) > limit || closed == null) fail(70, 'READ_FAILED');
    return raw;
}
function authorized(user, chat) {
    return match(user || '', /^[1-9][0-9]{0,18}$/) && match(chat || '', /^-?[1-9][0-9]{0,18}$/) &&
        trim(bounded(SECRETS_DIR + '/telegram.user_id', 32) || '') == user &&
        trim(bounded(SECRETS_DIR + '/telegram.chat_id', 32) || '') == chat;
}
function load() {
    let raw = bounded(STATE, 131072);
    if (raw == null) return { schema_version: 1, records: [] };
    let data;
    try { data = json(raw); } catch (e) { fail(70, 'CORRUPT_STATE'); }
    if (data?.schema_version != 1 || type(data?.records) != 'array' || length(data.records) > 128) fail(70, 'CORRUPT_STATE');
    let tokens = {};
    for (let r in data.records) {
        if (type(r) != 'object' || !SERVICES[r.action] || index(PHASES, r.phase) < 0 ||
            !match(r.token || '', /^[0-9a-f]{32}$/) || tokens[r.token] ||
            !match(r.user || '', /^[1-9][0-9]{0,18}$/) || !match(r.chat || '', /^-?[1-9][0-9]{0,18}$/) ||
            type(r.message) != 'string' || !match(r.message, /^[1-9][0-9]{0,18}$/) ||
            type(r.created) != 'int' || type(r.expires) != 'int' || r.expires != r.created + 120 ||
            type(r.boot) != 'string' || !match(r.boot, /^[0-9a-f-]{36}$/) ||
            type(r.started) != 'int' || type(r.finished) != 'int' || type(r.maintenance_until) != 'int') fail(70, 'CORRUPT_STATE');
        tokens[r.token] = true;
    }
    return data;
}
function save(data) {
    let raw = sprintf('%J\n', data);
    if (length(raw) > 131072 || (fs.lstat(STATE + '.new') != null && (fs.lstat(STATE + '.new').type != 'file' || fs.lstat(STATE + '.new').uid != OWNER || fs.lstat(STATE + '.new').perm.group_write || fs.lstat(STATE + '.new').perm.other_write))) fail(70, 'WRITE_FAILED');
    let f = fs.open(STATE + '.new', 'we');
    if (!f || !fs.chmod(STATE + '.new', 0600)) fail(70, 'WRITE_FAILED');
    let ok = f.write(raw) == length(raw) && f.flush() != null;
    if (f.close() == null) ok = false;
    if (!ok || command([ '/bin/sync' ]) != 0 || !fs.rename(STATE + '.new', STATE) || command([ '/bin/sync' ]) != 0) fail(70, 'WRITE_FAILED');
}
function recover(data, now) {
    let changed = false;
    for (let r in data.records) {
        // Lock ownership is gone: a previous EXECUTING outcome is ambiguous, never replayed.
        if (r.phase == 'EXECUTING') { changed = true; r.phase = 'UNKNOWN'; r.finished = now; r.maintenance_until = 0; }
        if (r.phase == 'PENDING' && (r.boot != BOOT || now < r.created || now >= r.expires)) { r.phase = 'EXPIRED'; changed = true; }
    }
    return changed;
}
function lock(path) {
    let st = fs.lstat(path);
    if (st != null && (st.type != 'file' || st.uid != OWNER || st.perm.group_write || st.perm.other_write)) fail(70, 'UNSAFE_LOCK');
    let f = fs.open(path, 'ae');
    if (!f || !fs.chmod(path, 0600) || f.lock('xn') == null) fail(73, 'BUSY');
    return f; // e flag: CLOEXEC; service subprocesses cannot keep the lock alive.
}
function nonce() {
    let raw = trim(fs.readfile('/proc/sys/kernel/random/uuid') || '');
    if (!match(raw, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)) fail(70, 'ENTROPY_UNAVAILABLE');
    return replace(raw, '-', '');
}

ENABLED = getenv('HG_ACTION_EXECUTION_ENABLED') == '1' ||
    trim(bounded(getenv('HG_ACTION_POLICY_FILE') || '/etc/home-gateway/actions.enabled', 16) || '') == '1';

if (MODE == 'maintenance') {
    let data = load(), now = time(), latest = null;
    for (let r in data.records)
        if (r.action == 'restart-tailscale' && r.boot == BOOT && r.started > 0 &&
            (latest == null || r.started >= latest.started)) latest = r;
    let active = latest != null && now >= latest.started && latest.maintenance_until > now &&
        latest.maintenance_until <= latest.started + 120 && (latest.phase == 'EXECUTING' || latest.phase == 'DONE');
    print(active ? 'MAINTENANCE\n' : 'NONE\n');
    exit(0);
}
if (MODE != 'show' && MODE != 'prepare' && MODE != 'confirm' && MODE != 'cancel' && MODE != 'acknowledge') fail(2, 'USAGE');
if ((MODE == 'prepare' || MODE == 'confirm') && length(ARGV) != 5) fail(2, 'USAGE');
if (MODE == 'show' && length(ARGV) > 1) fail(2, 'USAGE');
if (MODE == 'acknowledge' && (length(ARGV) != 2 || !SERVICES[ARGV[1]] || getenv('HG_ACTION_ACKNOWLEDGE_AUTHORIZED') != '1')) fail(77, 'LOCAL_ACK_REQUIRED');
if (!match(BOOT, /^[0-9a-f-]{36}$/)) fail(70, 'BOOT_UNAVAILABLE');
if (MODE == 'cancel' && (length(ARGV) != 3 || !authorized(ARGV[1], ARGV[2]))) fail(77, 'UNAUTHORIZED');
if ((MODE == 'prepare' || MODE == 'confirm') && !authorized(ARGV[2], ARGV[3])) fail(77, 'UNAUTHORIZED');
if ((MODE == 'prepare' || MODE == 'confirm') && !ENABLED) fail(70, 'DISABLED');
private_dir(STATE_DIR); private_dir(RUNTIME_DIR);
let guard = lock(RUNTIME_DIR + '/actions.lock');
let data = load(), now = time();
let recovered = recover(data, now);
if (recovered) save(data);
if (MODE == 'acknowledge') {
    for (let r in data.records)
        if (r.action == ARGV[1] && r.phase == 'UNKNOWN') r.phase = 'ACKNOWLEDGED';
    save(data);
    print({ schema_version: 1, status: 'ACKNOWLEDGED' }, '\n');
    exit(0);
}
if (MODE == 'show') {
    print({ schema_version: 1, enabled: ENABLED, actions: keys(SERVICES),
            records: map(data.records, r => ({ action: r.action, phase: r.phase, created: r.created, finished: r.finished })) }, '\n');
    exit(0);
}
if (MODE == 'cancel') {
    let changed = recovered;
    for (let r in data.records)
        if (r.phase == 'PENDING' && r.user == ARGV[1] && r.chat == ARGV[2]) { r.phase = 'CANCELLED'; changed = true; }
    if (changed) save(data);
    print({ schema_version: 1, status: 'CANCELLED' }, '\n');
    exit(0);
}
if (!match(ARGV[4] || '', /^[1-9][0-9]{0,18}$/)) fail(2, 'USAGE');
if (MODE == 'prepare') {
    let action = ARGV[1];
    if (!SERVICES[action]) fail(2, 'NOT_ALLOWED');
    for (let r in data.records) if (r.action == action && r.phase == 'UNKNOWN') fail(70, 'RESOURCE_QUARANTINED');
    for (let r in data.records)
        if (r.phase == 'PENDING' && r.user == ARGV[2] && r.chat == ARGV[3] && r.action == action) r.phase = 'CANCELLED';
    // Bounded audit retention; dropping a terminal token never permits execution of it.
    let pending = filter(data.records, r => r.phase == 'PENDING');
    let quarantined = filter(data.records, r => r.phase == 'UNKNOWN');
    let terminal = filter(data.records, r => r.phase != 'PENDING' && r.phase != 'UNKNOWN');
    if (length(pending) + length(quarantined) >= 20) fail(70, 'BACKPRESSURE');
    while (length(terminal) > 100) shift(terminal);
    data.records = [ ...terminal, ...quarantined, ...pending ];
    let r = { action, token: nonce(), user: ARGV[2], chat: ARGV[3], message: ARGV[4],
              created: now, expires: now + 120, boot: BOOT, phase: 'PENDING', started: 0, finished: 0, maintenance_until: 0 };
    push(data.records, r); save(data);
    print({ schema_version: 1, status: 'CONFIRM_REQUIRED', action, token: r.token, expires: r.expires }, '\n');
    exit(0);
}
let token = ARGV[1], found = null;
if (!match(token || '', /^[0-9a-f]{32}$/)) fail(2, 'USAGE');
for (let r in data.records) if (r.token == token) found = r;
if (!found || found.user != ARGV[2] || found.chat != ARGV[3] || found.message != ARGV[4]) fail(77, 'INVALID_CONFIRMATION');
if (found.phase != 'PENDING') { save(data); fail(75, found.phase); }
for (let r in data.records) if (r.action == found.action && r.phase == 'UNKNOWN') fail(70, 'RESOURCE_QUARANTINED');
let resource = lock(RUNTIME_DIR + '/action-' + SERVICES[found.action] + '.lock');
let service = INIT_DIR + '/' + SERVICES[found.action];
let service_prefix = '';
for (let part in split(INIT_DIR, '/')) {
    if (!length(part)) continue;
    if (part == '.' || part == '..') fail(70, 'INVALID_SERVICE');
    service_prefix += '/' + part;
    let st = fs.lstat(service_prefix);
    if (st?.type != 'directory' || (st.uid != 0 && st.uid != OWNER) ||
        ((st.perm.group_write || st.perm.other_write) && !st.perm.sticky)) fail(70, 'INVALID_SERVICE');
}
let service_stat = fs.lstat(service);
if (service_stat?.type != 'file' || (service_stat.uid != 0 && service_stat.uid != OWNER) || !service_stat.perm.user_exec || service_stat.perm.group_write || service_stat.perm.other_write) fail(70, 'INVALID_SERVICE');
for (let r in data.records) if (r.action == found.action) r.maintenance_until = 0;
found.phase = 'EXECUTING'; found.started = now; found.maintenance_until = now + 120;
save(data); // Consume durably before starting the allowlisted process.
let rc = command([ 'timeout', '-k', '2', '30', service, 'restart' ]);
if (rc == 0) rc = command([ 'timeout', '-k', '2', '10', service, 'status' ]);
found.phase = rc == 0 ? 'DONE' : (rc < 0 || index([ 124, 137, 143 ], rc) >= 0) ? 'UNKNOWN' : 'FAILED'; found.finished = time();
found.maintenance_until = rc == 0 ? min(found.started + 120, found.finished + 30) : 0;
save(data);
print({ schema_version: 1, status: found.phase, action: found.action }, '\n');
exit(rc == 0 ? 0 : 70);
