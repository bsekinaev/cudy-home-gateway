#!/usr/bin/env ucode
'use strict';

import * as fs from 'fs';

const GATEWAY = ARGV[0] || '/usr/bin/gateway';
const MODE = ARGV[1] || 'show';

const RUNTIME_DIR = getenv('HG_NOTIFICATION_RUNTIME_DIR') || '/tmp/home-gateway';
const RUNTIME_FILE = RUNTIME_DIR + '/incidents.runtime.json';
const LOCK_FILE = RUNTIME_DIR + '/incidents.lock';

const STATE_DIR = getenv('HG_NOTIFICATION_STATE_DIR') || '/etc/home-gateway/state';
const JOURNAL_FILE = STATE_DIR + '/incidents.jsonl';

const OPEN_THRESHOLD = 3;
const CHANGE_THRESHOLD = 3;
const RECOVERY_THRESHOLD = 2;

const COMPONENTS = [
    { name: 'wan', role: 'core', label: 'WAN' },
    { name: 'dns', role: 'core', label: 'DNS' },
    { name: 'main', role: 'core', label: 'MAIN' },
    { name: 'torrent', role: 'service', label: 'Torrent' },
    { name: 'redmi', role: 'policy', label: 'Redmi' },
    { name: 'asata', role: 'policy', label: 'ASATA' },
    { name: 'tailscale', role: 'service', label: 'Tailscale' }
];

function shellquote(value) {
    return `'${replace(`${value}`, "'", "'\\''")}'`;
}

function run_command(command) {
    let proc = fs.popen(command, 'r');

    if (!proc)
        return { code: 127, output: '' };

    let output = proc.read('all');
    let code = proc.close();

    return {
        code,
        output: output ?? ''
    };
}

function run_gateway(args) {
    let command = `/bin/sh ${shellquote(GATEWAY)}`;

    for (let arg in args)
        command += ` ${shellquote(arg)}`;

    return run_command(command);
}

function ensure_runtime_dir() {
    if (fs.stat(RUNTIME_DIR) == null)
        fs.mkdir(RUNTIME_DIR);
}

function ensure_state_dir() {
    if (fs.stat('/etc/home-gateway') == null)
        fs.mkdir('/etc/home-gateway');

    if (fs.stat(STATE_DIR) == null)
        fs.mkdir(STATE_DIR);
}

function read_json_file(path, fallback) {
    let raw = fs.readfile(path);

    if (raw == null || !length(trim(raw)))
        return fallback;

    try {
        let value = json(raw);

        if (type(value) == 'object')
            return value;
    }
    catch (e) {
        warn(`incidents: invalid JSON in ${path}\n`);
    }

    return fallback;
}

function atomic_write_json(path, value) {
    if (fs.stat(path)?.type == 'directory') {
        warn('incidents: target is a directory\n');
        return false;
    }
    let tmp = `${path}.tmp.${time()}`;
    let file = fs.open(tmp, 'w');

    if (!file) {
        warn(`incidents: unable to open ${tmp}\n`);
        return false;
    }

    if (file.write(value) == null || file.write('\n') == null) {
        file.close();
        run_command(`/bin/rm -f ${shellquote(tmp)}`);
        warn(`incidents: unable to write ${tmp}\n`);
        return false;
    }

    file.close();

    let result = run_command(`/bin/mv -f ${shellquote(tmp)} ${shellquote(path)}`);

    if (result.code != 0) {
        run_command(`/bin/rm -f ${shellquote(tmp)}`);
        warn(`incidents: unable to replace ${path}\n`);
        return false;
    }

    return true;
}

function acquire_tick_lock() {
    ensure_runtime_dir();

    // CLOEXEC обязателен: gateway health запускается как child process.
    let file = fs.open(LOCK_FILE, 'ae');

    if (!file) {
        warn('incidents: unable to open lock file\n');
        return null;
    }

    if (file.lock('xn') == null) {
        warn('incidents: another tick is already running\n');
        file.close();
        return null;
    }

    return file;
}

function empty_runtime() {
    return {
        schema_version: 1,
        updated_at: null,
        candidates: {}
    };
}

function load_runtime() {
    let runtime = read_json_file(RUNTIME_FILE, empty_runtime());

    if (runtime?.schema_version != 1 || type(runtime?.candidates) != 'object')
        return empty_runtime();

    return runtime;
}

function candidate(runtime, component) {
    let current = runtime?.candidates?.[component];

    if (type(current) != 'object') {
        current = {
            state: 'UNKNOWN',
            count: 0,
            reason: 'unknown',
            first_seen: null,
            last_seen: null
        };

        runtime.candidates[component] = current;
    }

    return current;
}

function set_candidate(runtime, component, state, count, reason, first_seen, last_seen) {
    runtime.candidates[component] = {
        state,
        count,
        reason,
        first_seen,
        last_seen,
        first_uptime: count > 0 ? runtime.observation?.finished_uptime : null,
        boot_id: runtime.observation?.boot_id
    };

    return runtime.candidates[component];
}

function advance_candidate(runtime, component, state, reason, now) {
    let current = candidate(runtime, component);

    if (current.state == state) {
        let count = int(current.count ?? 0);

        if (count < 0)
            count = 0;

        current.count = count + 1;
        current.reason = reason;
        current.last_seen = now;

        if (current.first_seen == null)
            current.first_seen = now;

        return current;
    }

    return set_candidate(runtime, component, state, 1, reason, now, now);
}

function reset_candidate(runtime, component, state, reason, now) {
    return set_candidate(runtime, component, state, 0, reason, null, now);
}

function load_active_incidents() {
    let active = {};
    let raw = fs.readfile(JOURNAL_FILE);

    if (raw == null || !length(raw))
        return active;

    for (let line in split(raw, '\n')) {
        line = trim(line);

        if (!length(line))
            continue;

        let event;

        try {
            event = json(line);
        }
        catch (e) {
            // Возможный неполный хвост после power loss игнорируется.
            continue;
        }

        if (type(event) != 'object' || event?.schema_version != 1)
            continue;

        let component = event?.component;
        let kind = event?.event;
        let incident_id = event?.incident_id;

        if (component == null || incident_id == null)
            continue;

        if (kind == 'OPEN') {
            active[component] = {
                incident_id,
                component,
                role: event?.role ?? 'unknown',
                state: event?.state ?? 'UNKNOWN',
                reason: event?.reason ?? 'unknown',
                opened_at: event?.opened_at ?? event?.at ?? null,
                changed_at: event?.at ?? null,
                opened_boot_id: event?.opened_boot_id,
                opened_uptime: event?.opened_uptime,
                opened_context: event?.opened_context
            };
        }
        else if (kind == 'STATE_CHANGED') {
            let current = active[component];

            if (type(current) == 'object' && current.incident_id == incident_id) {
                current.state = event?.state ?? current.state;
                current.reason = event?.reason ?? current.reason;
                current.changed_at = event?.at ?? current.changed_at;
            }
        }
        else if (kind == 'RECOVERED') {
            let current = active[component];

            if (type(current) == 'object' && current.incident_id == incident_id)
                delete active[component];
        }
    }

    return active;
}

let journal_tail_repaired = false;
function repair_journal_tail() {
    let before=fs.lstat(JOURNAL_FILE);
    if(before==null) return true;
    if(before.type!='file' || before.nlink!=1 || before.size>2097152) return false;
    let raw=fs.readfile(JOURNAL_FILE);
    if(raw==null) return false;
    if(!length(raw) || substr(raw,-1)=='\n') return true;
    let edge=rindex(raw,'\n'), prefix=edge>=0?substr(raw,0,edge+1):'';
    let tail=substr(raw,edge+1);
    try {
        let event=json(tail);
        // A complete event can lose only its final delimiter during power loss.
        // Preserve it. Structurally invalid complete JSON is not a partial tail.
        if(type(event)!='object' || event.schema_version!=1 ||
            index(['OPEN','STATE_CHANGED','RECOVERED'],event.event)<0 ||
            type(event.incident_id)!='string' || type(event.at)!='int') return false;
        prefix+=tail+'\n';
    }
    catch(error) { /* Only the unfinished last record is discarded. */ }
    let temporary=JOURNAL_FILE+'.tail-repair.'+time();
    let file=fs.open(temporary,'wxe',0600);
    if(!file) return false;
    let ok=file.write(prefix)==length(prefix) && file.flush()!=null;
    let closed=file.close();
    if(!ok || closed==null || run_command('/bin/busybox fsync '+shellquote(temporary)).code!=0) {
        fs.unlink(temporary); return false;
    }
    let current=fs.lstat(JOURNAL_FILE);
    if(current?.inode!=before.inode || current.size!=before.size || current.mtime!=before.mtime ||
        !fs.rename(temporary,JOURNAL_FILE)) { fs.unlink(temporary); return false; }
    if(run_command('/bin/busybox fsync '+shellquote(STATE_DIR)).code!=0) return false;
    journal_tail_repaired=true;
    return true;
}

function append_events(events) {
    if (!length(events))
        return true;

    ensure_state_dir();

    let file = fs.open(JOURNAL_FILE, 'a');

    if (!file) {
        warn(`incidents: unable to open ${JOURNAL_FILE}\n`);
        return false;
    }

    for (let event in events) {
        if (file.write(event) == null || file.write('\n') == null) {
            file.close();
            warn(`incidents: unable to append ${JOURNAL_FILE}\n`);
            return false;
        }
    }

    file.close();
    return true;
}

// Compact chat code only; persistent IDs retain the complete legacy-compatible
// decimal encoding. No identifier is shortened in the journal or delivery dedup.
function incident_chat_code(id) {
    let m=match(id,/^(wan|dns|main|torrent|redmi|asata|tailscale)-8([0-9]{64})([0-9]{64})([0-9]{20})$/);
    if(m==null) return id;
    let pairs=['00','01','02','03','04','05','06','07','08','09','10','11','12','13','14','15'];
    let parts=[];
    for(let value in [m[2],m[3]]) {
        let hex='';
        for(let i=0;i<8;i++) {
            let n=index(pairs,substr(value,i*2,2));
            if(n<0) return id;
            hex+=substr('0123456789abcdef',n,1);
        }
        push(parts,hex);
    }
    return `${m[1]}-${parts[0]}-${parts[1]}-${replace(m[4],/^0+/,'') || '0'}`;
}

function new_event(kind, component, role, incident_id, state, reason, now) {
    return {
        schema_version: 1,
        event: kind,
        incident_id,
        component,
        role,
        state,
        reason,
        at: now
    };
}

function process_component(spec, observation, now, runtime, active, events) {
    let name = spec.name;
    let role = observation?.role ?? spec.role;
    let state = `${observation?.state ?? 'UNKNOWN'}`;
    let reason = `${observation?.reason ?? 'unknown'}`;
    let incident = active[name];
    if (type(runtime.context_boundaries) != 'object') runtime.context_boundaries = {};
    if (incident?.opened_context != null && runtime.observation?.context != null &&
        incident.opened_context != runtime.observation.context)
        runtime.context_boundaries[incident.incident_id] = true;

    if (state != 'OK' &&
        state != 'DEGRADED' &&
        state != 'DOWN' &&
        state != 'UNKNOWN' &&
        state != 'MAINTENANCE')
        state = 'UNKNOWN';

    // UNKNOWN и MAINTENANCE не открывают и не закрывают incident.
    // Они только прерывают текущий debounce candidate.
    if (state == 'UNKNOWN' || state == 'MAINTENANCE') {
        reset_candidate(runtime, name, state, reason, now);
        return;
    }

    if (type(incident) != 'object') {
        if (state == 'OK') {
            reset_candidate(runtime, name, state, reason, now);
            return;
        }

        let c = advance_candidate(runtime, name, state, reason, now);

        if (c.count < OPEN_THRESHOLD)
            return;

        let opened_at = c.first_seen ?? now;
        let e = runtime.observation;
        let incident_id = `${name}-${opened_at}`;
        if (e?.boot_id != null && e?.incarnation != null) {
            let boot = replace(e.boot_id, /-/g, '');
            let incarnation = replace(e.incarnation, /-/g, '');
            if(match(boot,/^[a-f0-9]{32}$/)==null || match(incarnation,/^[a-f0-9]{32}$/)==null ||
                type(e.sequence)!='int' || e.sequence<0) {
                reset_candidate(runtime,name,'UNKNOWN','invalid_sample_identity',now); return;
            }
            // Fixed-width decimal encoding preserves all UUID bits while keeping
            // the installed baseline's component-[0-9]+ journal/queue grammar.
            let digits='8';
            for(let value in [boot,incarnation]) for(let i=0;i<32;i++)
                digits+=sprintf('%02d',index('0123456789abcdef',substr(value,i,1)));
            incident_id = `${name}-${digits}${sprintf('%020d',e.sequence)}`;
        }
        let event = new_event('OPEN', name, role, incident_id, state, reason, now);

        event.opened_at = opened_at;
        event.opened_boot_id = c.boot_id;
        event.opened_uptime = c.first_uptime;
        event.opened_context = runtime.observation?.context;

        active[name] = {
            incident_id,
            component: name,
            role,
            state,
            reason,
            opened_at,
            changed_at: now,
            opened_boot_id: event.opened_boot_id,
            opened_uptime: event.opened_uptime,
            opened_context: event.opened_context
        };

        push(events, event);
        reset_candidate(runtime, name, state, reason, now);
        return;
    }

    if (state == incident.state) {
        reset_candidate(runtime, name, state, reason, now);
        return;
    }

    if (state == 'OK') {
        let c = advance_candidate(runtime, name, state, reason, now);

        if (c.count < RECOVERY_THRESHOLD)
            return;

        let event = new_event(
            'RECOVERED',
            name,
            incident.role ?? role,
            incident.incident_id,
            'OK',
            reason,
            now
        );

        event.previous_state = incident.state;
        event.previous_reason = incident.reason;
        event.opened_at = incident.opened_at;

        let opened_at = int(incident.opened_at ?? now);
        event.duration_seconds = now >= opened_at ? now - opened_at : null;
        event.duration_scope = 'same_boot_observation_lifecycle';
        event.observed_duration_seconds = incident.opened_boot_id == runtime.observation?.boot_id &&
            incident.opened_uptime != null && runtime.observation?.finished_uptime >= incident.opened_uptime ?
            runtime.observation.finished_uptime - incident.opened_uptime : null;
        event.context_changed = runtime.context_boundaries[incident.incident_id] == true;
        delete runtime.context_boundaries[incident.incident_id];

        push(events, event);
        delete active[name];
        reset_candidate(runtime, name, state, reason, now);
        return;
    }

    // DEGRADED <-> DOWN также требуют устойчивого подтверждения.
    let c = advance_candidate(runtime, name, state, reason, now);

    if (c.count < CHANGE_THRESHOLD)
        return;

    let event = new_event(
        'STATE_CHANGED',
        name,
        incident.role ?? role,
        incident.incident_id,
        state,
        reason,
        now
    );

    event.previous_state = incident.state;
    event.previous_reason = incident.reason;
    event.opened_at = incident.opened_at;

    push(events, event);

    incident.state = state;
    incident.reason = reason;
    incident.changed_at = now;

    reset_candidate(runtime, name, state, reason, now);
}

function fetch_health() {
    let result = run_gateway([ 'health', '--json' ]);

    // gateway health intentionally returns 1 when the observed system is unhealthy.
    if (result.code != 0 && result.code != 1) {
        warn(`incidents: gateway health failed, exit=${result.code}\n`);
        return null;
    }

    try {
        let health = json(result.output);

        if (type(health) == 'object' &&
            health?.schema_version == 1 &&
            type(health?.components) == 'object')
            return health;
    }
    catch (e) {
        warn('incidents: gateway health returned invalid JSON\n');
    }

    return null;
}

function active_count(active) {
    let count = 0;

    for (let spec in COMPONENTS) {
        if (type(active[spec.name]) == 'object')
            count++;
    }

    return count;
}


const HISTORY_RAM = RUNTIME_DIR + '/monitor-history.json';
const HISTORY_DISK = STATE_DIR + '/monitor-history.json';
const HISTORY_CAP = 2097152;
function empty_history() {
    return { schema_version: 1, records: [], daily: [], events: [], truncated: false, last: null, flushed_uptime: null };
}
function load_history() {
    let h = read_json_file(HISTORY_RAM, null);
    let ram_unreadable = fs.stat(HISTORY_RAM) != null &&
        (h?.schema_version != 1 || type(h?.records) != 'array' || type(h?.daily) != 'array');
    if (h?.schema_version != 1 || type(h?.records) != 'array' || type(h?.daily) != 'array')
        h = read_json_file(HISTORY_DISK, null);
    let disk_unreadable = h == null && fs.stat(HISTORY_DISK) != null;
    if (h?.schema_version != 1 || type(h?.records) != 'array' || type(h?.daily) != 'array') {
        disk_unreadable = disk_unreadable || h != null;
        h = empty_history();
    }
    if (ram_unreadable || disk_unreadable) {
        h.truncated = true;
        h.recovery = ram_unreadable ? 'runtime_checkpoint_unreadable' : 'persistent_checkpoint_unreadable';
    }
    if (h.last != null && (type(h.last) != 'object' || type(h.last.uptime) != 'int' ||
        type(h.last.boot_id) != 'string' || type(h.last.components) != 'object')) {
        h.last = null; h.truncated = true;
    }
    if (h.events == null) h.events = [];
    let good_events = [];
    if (type(h.events) == 'array') for (let event in h.events) {
        if (type(event) == 'object' && type(event.incident_id) == 'string' &&
            type(event.at) == 'int' && index(['OPEN','STATE_CHANGED','RECOVERED'],event.event)>=0 &&
            length(filter(COMPONENTS, spec=>spec.name==event.component))==1)
            push(good_events,event);
        else h.truncated=true;
    }
    else h.truncated=true;
    h.events=good_events;
    let rows = [];
    for (let r in h.records) {
        if (type(r) != 'object' || type(r.boot_id) != 'string' || type(r.end_uptime) != 'int' ||
            (!r.gap && (type(r.seconds) != 'int' || r.seconds <= 0 || type(r.components) != 'object'))) {
            h.truncated = true; continue;
        }
        let valid = true;
        if (!r.gap) for (let spec in COMPONENTS) {
            let c = r.components[spec.name];
            if (type(c) != 'object' || type(c.covered_seconds) != 'int' ||
                c.covered_seconds < 0 || c.covered_seconds > r.seconds) valid = false;
        }
        if (valid) push(rows, r); else h.truncated = true;
    }
    h.records = rows;
    rows = [];
    for (let d in h.daily) {
        if (type(d) == 'object' && type(d.day) == 'int' && type(d.components) == 'object') push(rows, d);
        else h.truncated = true;
    }
    h.daily = rows;
    return h;
}
function valid_sample(c, e) {
    let s = c?.sample;
    return e?.schema_version == 1 && type(e?.boot_id) == 'string' &&
        type(e?.context) == 'string' && type(e?.finished_uptime) == 'int' &&
        s?.valid == true && type(s?.id) == 'string' && length(s.id) > 0 &&
        s?.boot_id == e.boot_id && s?.context == e.context &&
        type(s?.checked_uptime) == 'int' && type(s?.expires_uptime) == 'int' &&
        s.checked_uptime <= e.finished_uptime && e.finished_uptime <= s.expires_uptime;
}
function gated_component(spec, health, runtime) {
    let c = health.components?.[spec.name] ?? {};
    if (getenv('HG_INCIDENTS_LEGACY_SAMPLES') == '1' && health?.observation == null) return c;
    if (!valid_sample(c, health?.observation)) return { state: 'UNKNOWN', reason: 'invalid_or_stale_sample' };
    if (type(runtime.samples) != 'object') runtime.samples = {};
    let p = runtime.samples[spec.name];
    let a = c.sample;
    if (p?.id == a.id || (p?.boot_id == a.boot_id && p?.context == a.context && p?.checked_uptime >= a.checked_uptime))
        return null;
    runtime.samples[spec.name] = { id: a.id, boot_id: a.boot_id, context: a.context, checked_uptime: a.checked_uptime };
    return c;
}
function record_history(health, epoch, events) {
    let e = health?.observation;
    if (e?.schema_version != 1 || type(e?.finished_uptime) != 'int') return true;
    let h = load_history();
    if(journal_tail_repaired) { h.truncated=true; h.journal_tail_repaired=true; }
    let p = h.last;
    let c = { boot_id: e.boot_id, context: e.context, uptime: e.finished_uptime,
        epoch: epoch >= 1700000000 ? epoch : null, trusted: e.wall_time_trusted == true, components: {} };
    for (let spec in COMPONENTS) {
        let a = health.components?.[spec.name];
        c.components[spec.name] = valid_sample(a, e) ? { state: a.state, expires: a.sample.expires_uptime } :
            { state: 'UNKNOWN', expires: c.uptime };
    }
    if (p?.boot_id == c.boot_id && p?.context == c.context && type(p?.uptime) == 'int' && c.uptime > p.uptime) {
        let duration = c.uptime - p.uptime;
        let r = { boot_id: c.boot_id, end_uptime: c.uptime, start_epoch: p.epoch, end_epoch: c.epoch,
            seconds: duration, components: {} };
        if (p.epoch == null || c.epoch == null || c.epoch-p.epoch-duration > 5 || c.epoch-p.epoch-duration < -5) {
            r.start_epoch = null; r.end_epoch = null;
        }
        for (let spec in COMPONENTS) {
            let a = p.components?.[spec.name];
            let covered = (a?.state == 'OK' || a?.state == 'DOWN' || a?.state == 'DEGRADED') ? max(0, min(c.uptime, a?.expires ?? p.uptime) - p.uptime) : 0;
            r.components[spec.name] = { state: a?.state ?? 'UNKNOWN', covered_seconds: covered, unknown_seconds: duration-covered };
        }
        // Run-length encode stable complete intervals; transitions and partial expiry remain separate.
        let tail = length(h.records) ? h.records[length(h.records)-1] : null;
        let merge = tail != null && !tail.gap && tail.boot_id == r.boot_id &&
            tail.end_uptime == p.uptime && tail.end_epoch == r.start_epoch;
        for (let spec in COMPONENTS) {
            let a = tail?.components?.[spec.name]; let b = r.components[spec.name];
            if (a?.state != b.state ||
                !((a?.covered_seconds == 0 && b.covered_seconds == 0) ||
                  (a?.covered_seconds == tail?.seconds && b.covered_seconds == r.seconds))) merge = false;
        }
        if (merge) {
            tail.end_uptime = r.end_uptime; tail.end_epoch = r.end_epoch; tail.seconds += r.seconds;
            for (let spec in COMPONENTS) {
                tail.components[spec.name].covered_seconds += r.components[spec.name].covered_seconds;
                tail.components[spec.name].unknown_seconds += r.components[spec.name].unknown_seconds;
            }
        }
        else push(h.records, r);
        if (p.epoch != null && c.epoch != null && (c.epoch-p.epoch-duration <= 5 && c.epoch-p.epoch-duration >= -5)) {
            // Split by UTC midnight; only the retained 30 days are materialized.
            let cursor = max(p.epoch, (int(c.epoch/86400)-29)*86400);
            while (cursor < c.epoch) {
                let day = int(cursor / 86400);
                let end = min(c.epoch, (day+1)*86400);
                let bucket = null;
                for (let d in h.daily) if (d.day == day) bucket = d;
                if (bucket == null) { bucket = { day, components: {} }; push(h.daily, bucket); }
                for (let spec in COMPONENTS) {
                    if (bucket.components[spec.name] == null)
                        bucket.components[spec.name] = { covered_seconds: 0, unknown_seconds: 0, ok_seconds: 0 };
                    let t = bucket.components[spec.name]; let a = r.components[spec.name];
                    let covered = max(0, min(end, p.epoch+a.covered_seconds)-cursor);
                    t.covered_seconds += covered; t.unknown_seconds += end-cursor-covered;
                    if (a.state == 'OK') t.ok_seconds += covered;
                }
                cursor = end;
            }
        }
    }
    else if (p != null && (p.boot_id != c.boot_id || p.context != c.context))
        push(h.records, { gap: true, boot_id: c.boot_id, end_epoch: c.epoch, end_uptime: c.uptime });
    for (let event in events ?? []) push(h.events, {
        event:event.event, component:event.component, incident_id:event.incident_id,
        at:event.at, observed_boot_id:event.observed_boot_id, observed_uptime:event.observed_uptime,
        state:event.state, observed_duration_seconds:event.observed_duration_seconds ?? null,
        context_changed:event.context_changed==true, wall_time_trusted:event.wall_time_trusted==true
    });
    let recent_events=[];
    for (let event in h.events) {
        let age=event.observed_boot_id==c.boot_id && type(event.observed_uptime)=='int'
            ? c.uptime-event.observed_uptime : c.epoch!=null ? c.epoch-event.at : null;
        if (age!=null && age>=0 && age<=604800) push(recent_events,event);
    }
    h.events=recent_events;
    while (length(h.events)>512) { shift(h.events); h.truncated=true; }
    h.last = c;
    let keep = [];
    for (let r in h.records) {
        let recent = r.boot_id == c.boot_id && c.uptime-r.end_uptime <= 604800;
        if (c.epoch != null && r.end_epoch != null) recent = c.epoch-r.end_epoch <= 604800;
        if (recent) {
            if (!r.gap) {
                let age = r.boot_id == c.boot_id ? c.uptime-r.end_uptime : c.epoch-r.end_epoch;
                let remove = max(0, r.seconds-(604800-age));
                if (remove > 0) {
                    r.seconds -= remove;
                    if (r.start_epoch != null) r.start_epoch += remove;
                    for (let spec in COMPONENTS) {
                        let a = r.components[spec.name];
                        a.covered_seconds = max(0, a.covered_seconds-remove);
                        a.unknown_seconds = r.seconds-a.covered_seconds;
                    }
                }
            }
            push(keep, r);
        }
    }
    h.records = keep; keep = [];
    for (let d in h.daily) if (c.epoch == null || d.day >= int(c.epoch/86400)-29) push(keep, d);
    h.daily = keep;
    while (length(sprintf('%J', h.daily)) > 524288 && length(h.daily)) { shift(h.daily); h.truncated = true; }
    while (length(sprintf('%J', h)) > HISTORY_CAP && length(h.records)) { shift(h.records); h.truncated = true; }
    while (length(sprintf('%J', h)) > HISTORY_CAP && length(h.events)) { shift(h.events); h.truncated = true; }
    if (p?.boot_id != c.boot_id || h.flushed_uptime == null || c.uptime-h.flushed_uptime >= 900) {
        ensure_state_dir(); h.flushed_uptime = c.uptime;
        if (!atomic_write_json(HISTORY_DISK, h)) {
            h.flushed_uptime = null; h.truncated = true; atomic_write_json(HISTORY_RAM, h); return false;
        }
    }
    return atomic_write_json(HISTORY_RAM, h);
}
function history_query_clock() {
    // Local CLI fixture seam only; these values are never persisted as observations.
    let boot = getenv('HG_HISTORY_QUERY_BOOT_ID') ?? trim(fs.readfile('/proc/sys/kernel/random/boot_id') ?? '');
    let raw = split(trim(fs.readfile('/proc/uptime') ?? ''), ' ')[0];
    let uptime = int(getenv('HG_HISTORY_QUERY_UPTIME') ?? raw);
    let epoch = int(getenv('HG_HISTORY_QUERY_EPOCH') ?? time());
    return { boot_id: boot, uptime, epoch };
}
function history_summary(human) {
    let period = ARGV[2] || 'day';
    if (period != 'day' && period != 'week') return 2;
    let h = load_history(); let span = period == 'week' ? 604800 : 86400;
    let clock = history_query_clock();
    let age = null;
    if (h.last?.boot_id == clock.boot_id && clock.uptime >= h.last?.uptime)
        age = clock.uptime-h.last.uptime;
    else if (h.last?.epoch != null && clock.epoch >= h.last.epoch)
        age = clock.epoch-h.last.epoch;
    let result = { schema_version: 1, period, requested_seconds: span, detail_retention_days: 7,
        daily_retention_days: 30, checkpoint_seconds: 900, storage_cap_bytes: HISTORY_CAP,
        daily_cap_bytes: 524288, truncated: h.truncated, recovery: h.recovery,
        generated_at: clock.epoch, period_end: 'query_time', query_clock: clock,
        latest_sample: h.last == null ? null : { epoch: h.last.epoch, uptime: h.last.uptime, boot_id: h.last.boot_id },
        snapshot_age_seconds: age, wall_time_trusted: h.last?.trusted == true,
        wall_time_quality: h.last?.trusted ? 'trusted' : (h.last?.epoch != null ? 'unconfirmed' : 'unknown'),
        reboot_gaps: 0, components: {}, daily: h.daily, events: [],
        incident_counts:{opened:0,recovered:0,changed:0} };
    for (let event in h.events) {
        let age=event.observed_boot_id==clock.boot_id && type(event.observed_uptime)=='int'
            ? clock.uptime-event.observed_uptime : clock.epoch>=1700000000 ? clock.epoch-event.at : null;
        if(age==null || age<0 || age>span) continue;
        push(result.events,event);
        if(event.event=='OPEN') result.incident_counts.opened++;
        else if(event.event=='RECOVERED') result.incident_counts.recovered++;
        else result.incident_counts.changed++;
    }
    for (let spec in COMPONENTS) result.components[spec.name] = { covered_seconds: 0, unknown_seconds: 0,
        ok_seconds: 0, down_seconds: 0, degraded_seconds: 0 };
    for (let r in h.records) {
        let age = r.boot_id == clock.boot_id && clock.uptime >= r.end_uptime ? clock.uptime-r.end_uptime : null;
        if (r.boot_id != clock.boot_id && clock.epoch >= 1700000000 && r.end_epoch != null)
            age = clock.epoch-r.end_epoch;
        if (age == null || age < 0 || age >= span) continue;
        if (r.gap) { result.reboot_gaps++; continue; }
        let kept_seconds = min(r.seconds, span-age);
        let removed = r.seconds-kept_seconds;
        for (let spec in COMPONENTS) {
            let a = r.components?.[spec.name]; let t = result.components[spec.name];
            let covered = max(0, (a?.covered_seconds ?? 0)-removed);
            t.covered_seconds += covered;
            t.unknown_seconds += kept_seconds-covered;
            if (a?.state == 'OK') t.ok_seconds += covered;
            if (a?.state == 'DOWN') t.down_seconds += covered;
            if (a?.state == 'DEGRADED') t.degraded_seconds += covered;
        }
    }
    for (let spec in COMPONENTS) {
        let t = result.components[spec.name];
        t.unobserved_seconds = max(0, span-t.covered_seconds-t.unknown_seconds);
        t.availability_percent = t.covered_seconds > 0 ? 100*t.ok_seconds/t.covered_seconds : null;
    }
    if (!human) { print(result, '\n'); return 0; }
    print(`Окно до момента запроса; возраст последнего наблюдения: ${age == null ? 'неизвестен' : `${int(age)}с`}\n`);
    print(`История: ${period == 'week' ? 'неделя' : 'сутки'}; часы: ${result.wall_time_quality}; разрывы: ${result.reboot_gaps}\n`);
    for (let spec in COMPONENTS) {
        let t = result.components[spec.name];
        print(`${spec.label}: OK ${int(t.ok_seconds)}с; DOWN ${int(t.down_seconds)}с; DEGRADED ${int(t.degraded_seconds)}с; покрытие ${int(t.covered_seconds)}с; UNKNOWN ${int(t.unknown_seconds)}с; нет наблюдений ${int(t.unobserved_seconds)}с\n`);
    }
    print(`Подтверждено сбоев: ${result.incident_counts.opened}; восстановлений: ${result.incident_counts.recovered}\n`);
    for(let i=max(0,length(result.events)-8); i<length(result.events); i++) {
        let event=result.events[i];
        let kind=event.event=='OPEN'?'сбой':event.event=='RECOVERED'?'восстановление':'изменение';
        print(`${event.component}: ${kind}; ID ${incident_chat_code(event.incident_id)}\n`);
    }
    if (result.truncated) print('Полнота сокращена лимитом хранения или ошибкой записи\n');
    return 0;
}
function tick() {
    let lock = acquire_tick_lock();

    if (lock == null)
        return 73;

    // Compaction recovery belongs to notifications and must finish before any append.
    if (fs.stat(STATE_DIR + '/notification-compaction.json') != null) {
        lock.close();
        warn('incidents: notification compaction recovery required\n');
        return 70;
    }

    // Delivery projection is strict: repair a power-loss tail before any new
    // append can join it. The incident lock excludes producers and compaction.
    if(!repair_journal_tail()) {
        lock.close(); warn('incidents: journal tail recovery failed\n'); return 70;
    }

    let health = fetch_health();

    if (health == null) {
        lock.close();
        return 70;
    }

    let now = int(health?.generated_at?.epoch ?? time());

    if (now <= 0)
        now = time();

    let runtime = load_runtime();
    let active = load_active_incidents();
    let events = [];

    let e = health?.observation;
    if (e != null) {
        let p = runtime.observation;
        if (p?.boot_id != e.boot_id || p?.context != e.context ||
            (getenv('HG_MONITOR_INCARNATION') != null && p?.incarnation != e.incarnation)) runtime.candidates = {};
        runtime.observation = e;
    }
    for (let spec in COMPONENTS) {
        let c = gated_component(spec, health, runtime);
        if (c != null) process_component(spec, c, now, runtime, active, events);
    }
    for (let event in events) {
        if (e != null) {
            event.observed_boot_id = e.boot_id;
            event.observed_uptime = e.finished_uptime;
            event.wall_time_trusted = e.wall_time_trusted == true;
        }
    }

    // Journal является persistent source of truth. Runtime counters сохраняем
    // только после успешного append transition events.
    if (!append_events(events)) {
        lock.close();
        return 70;
    }

    let history_ok = record_history(health, now, events);

    runtime.updated_at = now;
    ensure_runtime_dir();

    if (!atomic_write_json(RUNTIME_FILE, runtime)) {
        lock.close();
        return 70;
    }

    let count = active_count(active);

    print(`incidents: tick ok observations=${length(COMPONENTS)} events=${length(events)} active=${count}\n`);

    for (let event in events)
        print(`incidents: ${event.event} ${event.component} ${event.state} ${event.reason}\n`);

    lock.close();
    return history_ok ? 0 : 70;
}

function show_human() {
    let runtime = load_runtime();
    let active = load_active_incidents();
    let count = active_count(active);

    print('CUDY Home Gateway — incidents\n\n');
    print(`Active incidents: ${count}\n`);
    print(`Thresholds: open=${OPEN_THRESHOLD}, change=${CHANGE_THRESHOLD}, recovery=${RECOVERY_THRESHOLD}\n\n`);

    if (count) {
        print('Active\n');

        for (let spec in COMPONENTS) {
            let incident = active[spec.name];

            if (type(incident) != 'object')
                continue;

            print(`  ${spec.label}: ${incident.state} ${incident.reason}`);
            print(` [${incident.incident_id}]\n`);
        }

        print('\n');
    }

    print('Candidates\n');

    for (let spec in COMPONENTS) {
        let c = candidate(runtime, spec.name);
        print(`  ${spec.label}: ${c.state} x${int(c.count ?? 0)} ${c.reason ?? 'unknown'}\n`);
    }

    print(`\nJournal: ${JOURNAL_FILE}`);
    print(fs.stat(JOURNAL_FILE) == null ? ' (empty)\n' : '\n');

    return 0;
}

function show_json() {
    let runtime = load_runtime();
    let active = load_active_incidents();

    let output = {
        schema_version: 1,
        active_count: active_count(active),
        thresholds: {
            open: OPEN_THRESHOLD,
            change: CHANGE_THRESHOLD,
            recovery: RECOVERY_THRESHOLD
        },
        active,
        runtime,
        journal: {
            path: JOURNAL_FILE,
            exists: fs.stat(JOURNAL_FILE) != null
        }
    };

    print(output, '\n');
    return 0;
}

function selftest_observation(state, reason) {
    return {
        state,
        role: 'core',
        reason
    };
}

function run_selftest() {
    let runtime = empty_runtime();
    let active = {};
    let events = [];
    let spec = { name: 'main', role: 'core', label: 'MAIN' };

    process_component(spec, selftest_observation('DEGRADED', 'probe'), 100, runtime, active, events);
    process_component(spec, selftest_observation('DEGRADED', 'probe'), 101, runtime, active, events);

    if (length(events) != 0 || active_count(active) != 0)
        return 1;

    process_component(spec, selftest_observation('DEGRADED', 'probe'), 102, runtime, active, events);

    if (length(events) != 1 ||
        events[0]?.event != 'OPEN' ||
        active?.main?.state != 'DEGRADED')
        return 1;

    events = [];
    process_component(spec, selftest_observation('UNKNOWN', 'unknown'), 103, runtime, active, events);

    if (length(events) != 0 || active?.main?.state != 'DEGRADED')
        return 1;

    process_component(spec, selftest_observation('DOWN', 'xray'), 104, runtime, active, events);
    process_component(spec, selftest_observation('DOWN', 'xray'), 105, runtime, active, events);

    if (length(events) != 0 || active?.main?.state != 'DEGRADED')
        return 1;

    process_component(spec, selftest_observation('DOWN', 'xray'), 106, runtime, active, events);

    if (length(events) != 1 ||
        events[0]?.event != 'STATE_CHANGED' ||
        active?.main?.state != 'DOWN')
        return 1;

    events = [];
    process_component(spec, selftest_observation('OK', 'ready'), 107, runtime, active, events);

    if (length(events) != 0 || active?.main?.state != 'DOWN')
        return 1;

    process_component(spec, selftest_observation('OK', 'ready'), 108, runtime, active, events);

    if (length(events) != 1 ||
        events[0]?.event != 'RECOVERED' ||
        active_count(active) != 0)
        return 1;

    print('incidents-selftest: PASS\n');
    return 0;
}

let rc;

switch (MODE) {
case 'history-json':
    rc = history_summary(false);
    break;
case 'history':
    rc = history_summary(true);
    break;
case 'show':
    rc = show_human();
    break;

case 'json':
    rc = show_json();
    break;

case 'tick':
    rc = tick();
    break;

case 'selftest':
    rc = run_selftest();
    break;

default:
    warn('usage: incidents.uc [gateway-path] [show|json|tick|selftest|history|history-json] [day|week]\n');
    rc = 2;
    break;
}

exit(rc);
