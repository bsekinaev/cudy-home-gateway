#!/usr/bin/env ucode
'use strict';
import * as fs from 'fs';

const GATEWAY = ARGV[0] || '/usr/bin/gateway';
const MODE = ARGV[1] || 'show';
// Overrides are local CLI/test inputs; never supplied by Telegram.
const STATE_DIR = getenv('HG_NOTIFICATION_STATE_DIR') || '/etc/home-gateway/state';
const RUNTIME_DIR = getenv('HG_NOTIFICATION_RUNTIME_DIR') || '/tmp/home-gateway';
const SECRETS_DIR = getenv('HG_NOTIFICATION_SECRETS_DIR') || '/etc/home-gateway/secrets';
const QUEUE = STATE_DIR + '/notifications.jsonl';
const COMPACTION = STATE_DIR + '/notification-compaction.json';
const COMMITTED = STATE_DIR + '/notification-compaction.snapshot.json';
const DEDUP = STATE_DIR + '/notification-dedup.json';
const JOURNAL = STATE_DIR + '/incidents.jsonl';
const POLICY = STATE_DIR + '/notification-policy.json';
const COMPONENTS = [ 'wan', 'dns', 'main', 'torrent', 'redmi', 'asata', 'tailscale' ];
const STATUSES = [ 'PENDING', 'INFLIGHT', 'SENT', 'FAILED', 'COALESCED' ];
const MAX_BYTES = 2097152;

function quote(value) {
    return `'${replace(`${value}`, "'", "'\\''")}'`;
}
function command(args) {
    let text = '';
    for (let arg in args)
        text += (length(text) ? ' ' : '') + quote(arg);
    let proc = fs.popen(text + ' 2>/dev/null', 'r');
    if (!proc)
        return { code: 127, output: '' };
    let output = proc.read('all') ?? '';
    return { code: proc.close(), output };
}
function gateway(args) {
    return command([ '/bin/sh', GATEWAY, ...args ]);
}
function ensure_dirs() {
    for (let path in [ STATE_DIR, RUNTIME_DIR ]) {
        if (command([ '/bin/mkdir', '-p', path ]).code != 0 || !fs.chmod(path, 0700))
            die('notifications: unable to prepare private directories\n');
    }
}
function lock_queue() {
    ensure_dirs();
    let file = fs.open(RUNTIME_DIR + '/notifications.lock', 'ae');
    if (!file || file.lock('xn') == null)
        return null;
    return file;
}
function raw_file(path) {
    let stat = fs.stat(path);
    if (stat == null)
        return null;
    if (stat.size > MAX_BYTES)
        die('notifications: state size limit exceeded; operator intervention required\n');
    let raw = fs.readfile(path);
    if (raw == null)
        die('notifications: unreadable state\n');
    return raw;
}
function parse_lines(raw) {
    let items = [];
    for (let line in split(raw ?? '', '\n')) {
        if (!length(trim(line)))
            continue;
        let value;
        try { value = json(line); }
        catch (e) { die('notifications: corrupt journal; delivery paused\n'); }
        if (type(value) != 'object')
            die('notifications: invalid journal record; delivery paused\n');
        push(items, value);
    }
    return items;
}
function read_lines(path) {
    return parse_lines(raw_file(path));
}
function atomic_write(path, raw) {
    if (length(raw) > MAX_BYTES)
        return false;
    let tmp = path + '.new';
    let file = fs.open(tmp, 'w');
    if (!file || !fs.chmod(tmp, 0600))
        return false;
    let ok = file.write(raw) == length(raw) && file.flush() != null;
    if (file.close() == null)
        ok = false;
    // ucode target has no fsync binding: sync before and after same-filesystem rename.
    if (!ok || command([ '/bin/sync' ]).code != 0 || !fs.rename(tmp, path))
        return false;
    return command([ '/bin/sync' ]).code == 0;
}
function save_queue(items) {
    let raw = '';
    for (let item in items)
        raw += sprintf('%J\n', item);
    return atomic_write(QUEUE, raw);
}
function contains(values, value) {
    for (let item in values)
        if (item == value)
            return true;
    return false;
}
function valid_event(event) {
    return event.schema_version == 1 && type(event.incident_id) == 'string' &&
        match(event.incident_id, /^(wan|dns|main|torrent|redmi|asata|tailscale)-[0-9]+$/) != null &&
        contains(COMPONENTS, event.component) &&
        contains([ 'OPEN', 'STATE_CHANGED', 'RECOVERED' ], event.event) &&
        type(event.at) == 'int' && event.at >= 0;
}
function notification_id(event) {
    return `${event.incident_id}-${event.event}-${event.at}`;
}
function validate_queue(items) {
    let seen = {};
    for (let item in items) {
        if (!valid_event({ ...item, at: item.created_at }) ||
            type(item.notification_id) != 'string' || seen[item.notification_id] ||
            (item.notification_id != notification_id({ ...item, at: item.created_at }) &&
             item.notification_id != `${item.incident_id}-${item.event}`) ||
            !contains(STATUSES, item.status) ||
            (item.attempts != null && (type(item.attempts) != 'int' || item.attempts < 0)) ||
            (item.next_attempt_at != null && (type(item.next_attempt_at) != 'int' || item.next_attempt_at < 0)))
            die('notifications: invalid queue; delivery paused\n');
        seen[item.notification_id] = true;
    }
    return items;
}
function load_queue() {
    return validate_queue(read_lines(QUEUE));
}
function default_policy() {
    return { schema_version: 1, enabled: false, mute_until: 0, delivery_not_before: 0, categories: {} };
}
function load_policy() {
    let raw = raw_file(POLICY);
    if (raw == null)
        return default_policy();
    let policy;
    try { policy = json(raw); }
    catch (e) { die('notifications: corrupt policy; delivery paused\n'); }
    if (policy?.schema_version != 1 || type(policy.enabled) != 'bool' ||
        type(policy.mute_until) != 'int' || policy.mute_until < 0 || type(policy.categories) != 'object' ||
        (policy.delivery_not_before != null && (type(policy.delivery_not_before) != 'int' || policy.delivery_not_before < 0)))
        die('notifications: invalid policy; delivery paused\n');
    for (let key, value in policy.categories)
        if (!contains(COMPONENTS, key) || type(value) != 'bool')
            die('notifications: invalid category; delivery paused\n');
    return policy;
}
// A redo journal commits the three snapshots as one logical transaction. Producers
// refuse to append while it exists; recovery always runs under both CLOEXEC locks.
function lines(items) {
    let raw = '';
    for (let item in items) raw += sprintf('%J\n', item);
    return raw;
}
function validate_dedup(value) {
    if (value?.schema_version != 1 || type(value.ids) != 'array' || length(value.ids) > 1024)
        die('notifications: invalid dedup index; delivery paused\n');
    let seen = {};
    for (let id in value.ids) {
        if (type(id) != 'string' || seen[id] ||
            match(id, /^(wan|dns|main|torrent|redmi|asata|tailscale)-[0-9]+-(OPEN|STATE_CHANGED|RECOVERED)(-[0-9]+)?$/) == null)
            die('notifications: invalid dedup receipt; delivery paused\n');
        seen[id] = true;
    }
    return value.ids;
}
function load_dedup() {
    let raw = raw_file(DEDUP);
    if (raw == null) {
        let snapshot = raw_file(COMMITTED);
        if (snapshot != null) {
            let plan;
            try { plan = json(snapshot); }
            catch (e) { die('notifications: corrupt receipt snapshot; delivery paused\n'); }
            if (plan?.schema_version != 1) die('notifications: invalid receipt snapshot\n');
            return validate_dedup(plan.dedup);
        }
        for (let item in load_queue())
            if (item.dedup_required == true) die('notifications: missing dedup receipts; delivery paused\n');
        return [];
    }
    let value;
    try { value = json(raw); }
    catch (e) { die('notifications: corrupt dedup index; delivery paused\n'); }
    return validate_dedup(value);
}
function recover_compaction() {
    let raw = raw_file(COMPACTION);
    if (raw == null) return true;
    let plan;
    try { plan = json(raw); }
    catch (e) { die('notifications: corrupt compaction journal; delivery paused\n'); }
    if (plan?.schema_version != 1 || type(plan.queue) != 'string' ||
        type(plan.journal) != 'string' || type(plan.dedup) != 'object')
        die('notifications: invalid compaction journal; delivery paused\n');
    validate_queue(parse_lines(plan.queue));
    validate_dedup(plan.dedup);
    for (let event in parse_lines(plan.journal))
        if (!valid_event(event)) die('notifications: invalid compacted event\n');
    if (!atomic_write(DEDUP, sprintf('%J\n', plan.dedup)) ||
        !atomic_write(QUEUE, plan.queue) || !atomic_write(JOURNAL, plan.journal) ||
        !atomic_write(COMMITTED, raw)) return false;
    if (!fs.unlink(COMPACTION)) return false;
    return command([ '/bin/sync' ]).code == 0;
}
function compact(items, force) {
    let events = read_lines(JOURNAL);
    if (!force && length(items) <= 512 && length(events) <= 512) return true;
    let outstanding = {};
    let terminal = [];
    let known = {};
    for (let id in load_dedup()) known[id] = true;
    for (let item in items) {
        known[item.notification_id] = true;
        if (contains([ 'PENDING', 'INFLIGHT' ], item.status)) outstanding[item.notification_id] = true;
        else push(terminal, item);
    }
    let recent = {};
    let closed = [];
    let seen_closed = {};
    let latest = {};
    // Preserve OPEN, latest STATE_CHANGED and RECOVERED for each recent/active
    // incident, plus every source event still awaiting delivery.
    for (let event in events) {
        if (!valid_event(event)) die('notifications: invalid incident event\n');
        latest[`${event.incident_id}-${event.event}`] = notification_id(event);
        if (event.event == 'RECOVERED' && !seen_closed[event.incident_id]) {
            push(closed, event.incident_id);
            seen_closed[event.incident_id] = true;
        }
    }
    for (let i = max(0, length(closed) - 128); i < length(closed); i++) recent[closed[i]] = true;
    let kept_events = [];
    for (let event in events) {
        let id = notification_id(event);
        if (outstanding[id] || ((!seen_closed[event.incident_id] || recent[event.incident_id]) &&
            latest[`${event.incident_id}-${event.event}`] == id)) push(kept_events, event);
    }
    let kept = [];
    let kept_ids = {};
    let retain_from = max(0, length(terminal) - 256);
    for (let i = retain_from; i < length(terminal); i++) kept_ids[terminal[i].notification_id] = true;
    for (let item in items) {
        if (outstanding[item.notification_id] || kept_ids[item.notification_id]) {
            item.dedup_required = true;
            push(kept, item);
            kept_ids[item.notification_id] = true;
        }
    }
    let receipts = [];
    let receipt_ids = {};
    for (let event in kept_events) {
        let id = notification_id(event);
        let legacy = `${event.incident_id}-${event.event}`;
        if (!kept_ids[id] && !kept_ids[legacy] && !receipt_ids[id] && (known[id] || known[legacy])) {
            push(receipts, id);
            receipt_ids[id] = true;
        }
    }
    // Backpressure, never eviction of undelivered work. Input and transaction
    // byte limits also bound RAM/flash; capacity failures preserve all old files.
    if (length(kept) > 1024 || length(kept_events) > 1024 || length(receipts) > 1024) return false;
    let plan = { schema_version: 1, queue: lines(kept), journal: lines(kept_events),
        dedup: { schema_version: 1, ids: receipts } };
    if (!atomic_write(COMPACTION, sprintf('%J\n', plan))) return false;
    return recover_compaction();
}
function sync_queue(items) {
    let known = {};
    let legacy = {};
    for (let id in load_dedup()) known[id] = true;
    for (let item in items) {
        known[item.notification_id] = true;
        // Only genuinely legacy IDs suppress old events. Modern IDs include at.
        let old_id = `${item.incident_id}-${item.event}`;
        if (item.notification_id == old_id)
            legacy[old_id] = true;
    }
    let changed = false;
    let events = read_lines(JOURNAL);
    let opened_at = {};
    for (let event in events) {
        if (!valid_event(event)) die('notifications: invalid incident event; projection paused\n');
        if (event.event == 'OPEN') opened_at[event.incident_id] = event.opened_at ?? event.at;
    }
    for (let event in events) {
        if (!valid_event(event))
            die('notifications: invalid incident event; projection paused\n');
        let id = notification_id(event);
        if (known[id] || legacy[`${event.incident_id}-${event.event}`])
            continue;
        push(items, {
            schema_version: 1, notification_id: id, event: event.event,
            source_event: event.event, incident_id: event.incident_id,
            component: event.component, role: event.role ?? 'unknown',
            state: event.state ?? 'UNKNOWN', reason: event.reason ?? 'unknown',
            created_at: event.at, opened_at: event.opened_at ?? opened_at[event.incident_id] ?? event.at, status: 'PENDING', attempts: 0, next_attempt_at: 0
        });
        known[id] = true;
        changed = true;
    }
    // A recovered incident supersedes undelivered transitions; one recovery summary.
    for (let recovery in items) {
        if (recovery.event != 'RECOVERED' || recovery.status != 'PENDING')
            continue;
        let opened = opened_at[recovery.incident_id] ?? recovery.opened_at ?? recovery.created_at;
        for (let item in items) {
            if (item.incident_id != recovery.incident_id || item.created_at > recovery.created_at || item == recovery)
                continue;
            if (item.event == 'OPEN')
                opened = item.opened_at ?? item.created_at;
            if (item.status == 'INFLIGHT' && (item.next_attempt_at ?? 0) > time()) {
                if ((recovery.next_attempt_at ?? 0) < item.next_attempt_at) {
                    recovery.next_attempt_at = item.next_attempt_at;
                    changed = true;
                }
            }
            if (item.status == 'PENDING' ||
                (item.status == 'INFLIGHT' && (item.next_attempt_at ?? 0) <= time())) {
                item.status = 'COALESCED';
                item.summary_id = recovery.notification_id;
                changed = true;
            }
        }
        if (recovery.duration_seconds == null) {
            recovery.duration_seconds = recovery.created_at - opened;
            changed = true;
        }
    }
    return !changed || save_queue(items);
}
function delivery(item, proxy, chat) {
    // Only component/state/event IDs appear in messages; raw reasons may contain secrets.
    let text = item.event == 'RECOVERED'
        ? `✅ CUDY: ${item.component} восстановлен. Длительность: ${item.duration_seconds ?? 0} с.`
        : `⚠️ CUDY: ${item.component} — ${contains([ 'DOWN', 'DEGRADED' ], item.state) ? item.state : 'UNKNOWN'}.`;
    text += `\nСобытие: ${item.notification_id}`;
    let path = RUNTIME_DIR + '/notification-payload.json';
    let file = fs.open(path, 'w');
    if (!file || !fs.chmod(path, 0600))
        return { kind: 'RETRY', error: 'PAYLOAD_IO' };
    let payload = sprintf('%J', { chat_id: chat, text });
    let ok = file.write(payload) == length(payload) && file.flush() != null;
    if (file.close() == null)
        ok = false;
    if (!ok)
        return { kind: 'RETRY', error: 'PAYLOAD_IO' };
    let result = gateway([ 'telegram', 'deliver-notification', path, proxy ]);
    fs.unlink(path);
    let parts = split(result.output, '\nHG_TRANSPORT ');
    if (length(parts) < 2) return { kind: 'RETRY', error: 'INVALID_TRANSPORT' };
    // Body can contain the delimiter. Only curl's final suffix is authoritative.
    let suffix = trim(pop(parts));
    if (match(suffix, /^[0-9]{1,3} [0-9]+$/) == null)
        return { kind: 'RETRY', error: 'INVALID_TRANSPORT' };
    let meta = split(suffix, ' ');
    let http = int(meta[0]);
    let uploaded = int(meta[1]);
    if (http == 0) {
        // Fallback only when no request body left curl. Ambiguous delivery retries later.
        return { kind: 'RETRY', error: 'TRANSPORT', safe_fallback: result.code != 0 && uploaded == 0 };
    }
    let response;
    try { response = json(join('\nHG_TRANSPORT ', parts)); }
    catch (e) { return { kind: 'RETRY', error: 'INVALID_RESPONSE' }; }
    if (http == 200 && response?.ok == true && type(response?.result?.message_id) == 'int' && response.result.message_id > 0)
        return { kind: 'SENT', message_id: response.result.message_id };
    if (http == 429 || response?.error_code == 429) {
        let after = response?.parameters?.retry_after;
        return { kind: 'RETRY', error: 'RATE_LIMIT', retry_after: type(after) == 'int' ? min(86400, max(1, after)) : 60 };
    }
    if (contains([ 400, 401, 403, 404 ], http) || contains([ 400, 401, 403, 404 ], response?.error_code))
        return { kind: 'FAILED', error: 'TELEGRAM_REJECTED' };
    return { kind: 'RETRY', error: 'TELEGRAM_UNAVAILABLE' };
}
function dispatch(items, policy) {
    let now = time();
    if (!policy.enabled || policy.mute_until > now || (policy.delivery_not_before ?? 0) > now)
        return 0;
    // Queue receipt also enforces the global pause if a crash preceded policy write.
    for (let item in items)
        if (item.last_error == 'RATE_LIMIT' && (item.next_attempt_at ?? 0) > now) return 0;
    let chat = trim(fs.readfile(SECRETS_DIR + '/telegram.chat_id') ?? '');
    if (match(chat, /^-?[0-9]+$/) == null)
        return 70;
    let sent = 0;
    let processed = 0;
    for (let item in items) {
        if (!contains([ 'PENDING', 'INFLIGHT' ], item.status) ||
            (item.next_attempt_at ?? 0) > now || policy.categories[item.component] == false)
            continue;
        if (++processed > 4)
            break;
        item.status = 'INFLIGHT';
        item.attempts = (item.attempts ?? 0) + 1;
        item.next_attempt_at = now + 60;
        if (!save_queue(items))
            return 70;
        let result = delivery(item, '127.0.0.1:1082', chat);
        let route = 'MAIN';
        if (result.safe_fallback) {
            result = delivery(item, '127.0.0.1:1081', chat);
            route = 'TORRENT';
        }
        let finished = time();
        item.status = result.kind == 'RETRY' ? 'PENDING' : result.kind;
        item.last_error = result.error ?? null;
        if (item.status == 'SENT') {
            item.sent_at = finished;
            item.message_id = result.message_id;
            item.route = route;
            sent++;
        }
        else {
            item.next_attempt_at = finished + max(result.retry_after ?? 0, min(3600, 15 * (2 ** min(item.attempts - 1, 8))));
        }
        if (!save_queue(items))
            return 70;
        // Global Telegram retry_after: do not send the rest of this batch immediately.
        if (result.error == 'RATE_LIMIT') {
            policy.delivery_not_before = item.next_attempt_at;
            if (!atomic_write(POLICY, sprintf('%J\n', policy))) return 70;
            break;
        }
    }
    print(`notifications: processed=${min(processed, 4)} sent=${sent}\n`);
    return 0;
}
function persistence() {
    let path = getenv('HG_SYSUPGRADE_FILE') || '/etc/sysupgrade.conf';
    let raw = raw_file(path) ?? '';
    if (length(raw) && substr(raw, -1) != '\n') raw += '\n';
    for (let entry in [ '/etc/home-gateway/', '/usr/bin/gateway',
        '/usr/lib/home-gateway/', '/etc/init.d/home-gateway-telegram',
        '/etc/rc.d/S95home-gateway-telegram' ]) {
        if (!contains(split(raw, '\n'), entry)) raw += entry + '\n';
    }
    return atomic_write(path, raw) ? 0 : 70;
}
function configure() {
    let policy = load_policy();
    let value = ARGV[3] ?? '';
    switch (ARGV[2]) {
    case 'enable': policy.enabled = true; break;
    case 'disable': policy.enabled = false; break;
    case 'mute':
        if (match(value, /^[0-9]+$/) == null || int(value) > 86400)
            return 2;
        policy.mute_until = int(value) ? time() + int(value) : 0;
        break;
    case 'category':
        if (!contains(COMPONENTS, value) || !contains([ 'on', 'off' ], ARGV[4]))
            return 2;
        policy.categories[value] = ARGV[4] == 'on';
        break;
    default: return 2;
    }
    return atomic_write(POLICY, sprintf('%J\n', policy)) ? 0 : 70;
}
function iteration(mode) {
    let lock = lock_queue();
    if (!lock)
        return 73;
    let source_lock = fs.open(RUNTIME_DIR + '/incidents.lock', 'ae');
    if (!source_lock || source_lock.lock('xn') == null) { lock.close(); return 73; }
    if (!recover_compaction()) { source_lock.close(); lock.close(); return 70; }
    let rc = 0;
    if (mode == 'recover') rc = 0;
    else if (mode == 'configure')
        rc = configure();
    else if (mode == 'persistence')
        rc = persistence();
    else {
        let items = load_queue();
        if (mode == 'sync' || mode == 'dispatch' || mode == 'compact') {
            if (!sync_queue(items)) rc = 70;
            else if (!compact(items, mode == 'compact')) rc = 70;
            else if (mode == 'dispatch') rc = dispatch(load_queue(), load_policy());
        }
        else if (mode == 'json')
            print({ schema_version: 1, count: length(items), notifications: items, policy: load_policy() }, '\n');
        else if (mode == 'show') {
            print('CUDY Home Gateway — notifications\n');
            for (let item in items)
                print(`${item.status} ${item.component} ${item.event} [${item.notification_id}]\n`);
        }
        else rc = 2;
    }
    source_lock.close();
    lock.close();
    return rc;
}
if (MODE == 'selftest') {
    if (notification_id({ incident_id: 'test', event: 'STATE_CHANGED', at: 100 }) ==
        notification_id({ incident_id: 'test', event: 'STATE_CHANGED', at: 101 })) exit(1);
    print('notifications-selftest: PASS\n');
    exit(0);
}
if (MODE == 'loop') {
    ensure_dirs();
    let loop_lock = fs.open(RUNTIME_DIR + '/notifications-loop.lock', 'ae');
    if (!loop_lock || loop_lock.lock('xn') == null) exit(73);
    while (true) {
        let policy = load_policy();
        if (policy.enabled) {
            if (iteration('recover') == 0 && gateway([ 'incidents', 'tick' ]).code == 0)
                iteration('dispatch');
        }
        command([ '/bin/sleep', '30' ]);
    }
}
exit(iteration(MODE));
