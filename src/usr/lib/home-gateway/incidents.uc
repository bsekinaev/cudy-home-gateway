#!/usr/bin/env ucode
'use strict';

import * as fs from 'fs';

const GATEWAY = ARGV[0] || '/usr/bin/gateway';
const MODE = ARGV[1] || 'show';

const RUNTIME_DIR = '/tmp/home-gateway';
const RUNTIME_FILE = RUNTIME_DIR + '/incidents.runtime.json';
const LOCK_FILE = RUNTIME_DIR + '/incidents.lock';

const STATE_DIR = '/etc/home-gateway/state';
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
        last_seen
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
                changed_at: event?.at ?? null
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
        let incident_id = `${name}-${opened_at}`;
        let event = new_event('OPEN', name, role, incident_id, state, reason, now);

        event.opened_at = opened_at;

        active[name] = {
            incident_id,
            component: name,
            role,
            state,
            reason,
            opened_at,
            changed_at: now
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

function tick() {
    let lock = acquire_tick_lock();

    if (lock == null)
        return 73;

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

    for (let spec in COMPONENTS)
        process_component(spec, health.components?.[spec.name] ?? {}, now, runtime, active, events);

    // Journal является persistent source of truth. Runtime counters сохраняем
    // только после успешного append transition events.
    if (!append_events(events)) {
        lock.close();
        return 70;
    }

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
    return 0;
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
    warn('usage: incidents.uc [gateway-path] [show|json|tick|selftest]\n');
    rc = 2;
    break;
}

exit(rc);
