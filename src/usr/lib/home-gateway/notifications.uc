#!/usr/bin/env ucode
'use strict';

import * as fs from 'fs';

const GATEWAY = ARGV[0] || '/usr/bin/gateway';
const MODE = ARGV[1] || 'show';

const STATE_DIR = '/etc/home-gateway/state';
const INCIDENTS_FILE = STATE_DIR + '/incidents.jsonl';
const NOTIFICATIONS_FILE = STATE_DIR + '/notifications.jsonl';


function ensure_state_dir() {
    if (fs.stat('/etc/home-gateway') == null)
        fs.mkdir('/etc/home-gateway');

    if (fs.stat(STATE_DIR) == null)
        fs.mkdir(STATE_DIR);
}


function read_lines(path) {
    let raw = fs.readfile(path);

    if (raw == null || !length(raw))
        return [];

    let result = [];

    for (let line in split(raw, '\n')) {
        line = trim(line);

        if (!length(line))
            continue;

        try {
            let value = json(line);

            if (type(value) == 'object')
                push(result, value);
        }
        catch (e) {
            // Ignore incomplete/corrupted tail after power loss.
        }
    }

    return result;
}


function append_event(event) {
    ensure_state_dir();

    let file = fs.open(NOTIFICATIONS_FILE, 'a');

    if (!file)
        return false;

    if (file.write(event) == null || file.write('\n') == null) {
        file.close();
        return false;
    }

    file.close();

    return true;
}


function notification_id(event) {
    /*
     * Один incident может иметь несколько STATE_CHANGED.
     * Поэтому event.at является частью идентификатора.
     *
     * Пример:
     * wan-123-STATE_CHANGED-1758660000
     */
    return `${event.incident_id}-${event.event}-${event.at}`;
}


function existing_notifications() {
    let result = {};

    for (let item in read_lines(NOTIFICATIONS_FILE)) {

        if (item?.notification_id != null)
            result[item.notification_id] = true;

        /*
         * Совместимость со старым форматом:
         * incident_id-event
         */
        if (item?.incident_id != null &&
            item?.event != null) {

            let legacy_id =
                `${item.incident_id}-${item.event}`;

            result[legacy_id] = true;
        }
    }

    return result;
}


function build_notification(event) {
    return {
    schema_version: 1,

    notification_id: notification_id(event),

    event: event.event,
    source_event: event.event,

    incident_id: event.incident_id,

    component: event.component,

    role: event.role ?? 'unknown',

    state: event.state ?? 'UNKNOWN',

    reason: event.reason ?? 'unknown',

    created_at: event.at,

    status: 'PENDING'
    };
}


function sync() {
    let known = existing_notifications();
    let created = 0;

    for (let event in read_lines(INCIDENTS_FILE)) {

        if (event?.schema_version != 1)
            continue;

        if (event?.event != 'OPEN' &&
            event?.event != 'STATE_CHANGED' &&
            event?.event != 'RECOVERED')
            continue;

        let notification = build_notification(event);

        let legacy_id =
            `${event.incident_id}-${event.event}`;

        if (known[notification.notification_id] ||
            known[legacy_id])
            continue;

        if (!append_event(notification))
            return 70;

        known[notification.notification_id] = true;
        created++;
    }

    print(`notifications: sync created=${created}\n`);

    return 0;
}


function show() {
    let items = read_lines(NOTIFICATIONS_FILE);

    print('CUDY Home Gateway — notifications\n\n');
    print(`Count: ${length(items)}\n\n`);

    for (let item in items) {
        print(
            `${item.source_event ?? item.event} ` +
            `${item.component} ` +
            `${item.state} ` +
            `[${item.notification_id}]\n`
        );
    }

    return 0;
}


function show_json() {
    let items = read_lines(NOTIFICATIONS_FILE);

    let output = {
        schema_version: 1,
        count: length(items),
        notifications: items
    };

    print(output, '\n');

    return 0;
}


function selftest() {

    let event_one = {
        schema_version: 1,
        incident_id: 'test-1',
        event: 'STATE_CHANGED',
        component: 'main',
        role: 'core',
        state: 'DOWN',
        reason: 'test',
        at: 100
    };

    let event_two = {
        schema_version: 1,
        incident_id: 'test-1',
        event: 'STATE_CHANGED',
        component: 'main',
        role: 'core',
        state: 'DEGRADED',
        reason: 'test',
        at: 101
    };

    let notification_one = build_notification(event_one);
    let notification_two = build_notification(event_two);

    if (notification_one.notification_id ==
        notification_two.notification_id)
        return 1;

    if (notification_one.status != 'PENDING')
        return 1;

    if (notification_one.source_event != 'STATE_CHANGED')
        return 1;

    print('notifications-selftest: PASS\n');

    return 0;
}


let rc;

switch (MODE) {

case 'show':
    rc = show();
    break;

case 'json':
    rc = show_json();
    break;

case 'sync':
    rc = sync();
    break;

case 'selftest':
    rc = selftest();
    break;

default:
    print('usage: notifications.uc [gateway] [show|json|sync|selftest]\n');
    rc = 2;
    break;
}

exit(rc);