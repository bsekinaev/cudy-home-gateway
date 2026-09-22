#!/usr/bin/env ucode
'use strict';

import * as fs from 'fs';

const GATEWAY = ARGV[0] || '/usr/bin/gateway';
const MODE = ARGV[1] || 'loop';

const USER_FILE = '/etc/home-gateway/secrets/telegram.user_id';
const CHAT_FILE = '/etc/home-gateway/secrets/telegram.chat_id';
const RUNTIME_DIR = '/tmp/home-gateway';
const OFFSET_FILE = RUNTIME_DIR + '/telegram.offset';

const LONG_POLL_TIMEOUT = 30;
const STALE_SECONDS = 120;
const STARTED_AT = time();

function read_trimmed(path) {
	let value = fs.readfile(path);

	if (value == null)
		return null;

	value = trim(value);

	return length(value) ? value : null;
}

function shellquote(value) {
	return `'${replace(value, "'", "'\\''")}'`;
}

function run_gateway(args) {
	// OpenWrt ucode 2026.01 accepts only string commands in fs.popen().
	// Quote every argument before handing the command to /bin/sh -c.
	let command = `/bin/sh ${shellquote(GATEWAY)}`;

	for (let arg in args)
		command += ` ${shellquote(arg)}`;

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

function parse_response(result, label) {
	if (result.code != 0) {
		warn(`telegram-poller: ${label} failed, exit=${result.code}\n`);
		return null;
	}

	let payload;

	try {
		payload = json(result.output);
	}
	catch (e) {
		warn(`telegram-poller: ${label} returned invalid JSON\n`);
		return null;
	}

	if (!payload?.ok) {
		warn(`telegram-poller: ${label} returned ok=false\n`);
		return null;
	}

	return payload;
}

function ensure_runtime_dir() {
	if (fs.stat(RUNTIME_DIR) == null)
		fs.mkdir(RUNTIME_DIR);
}

function load_offset() {
	let value = read_trimmed(OFFSET_FILE);

	if (value == null)
		return '0';

	return value;
}

function save_offset(value) {
	ensure_runtime_dir();

	let file = fs.open(OFFSET_FILE, 'w');

	if (!file) {
		warn('telegram-poller: unable to write offset\n');
		return false;
	}

	file.write(`${value}\n`);
	file.close();

	return true;
}

function send_message(chat_id, text) {
	let response = run_gateway([
		'telegram',
		'send-message',
		`${chat_id}`,
		text
	]);

	let payload = parse_response(response, 'sendMessage');

	return payload != null;
}

function state(value) {
	return value ?? 'UNKNOWN';
}

function value_or(value, fallback) {
	return value ?? fallback;
}

function build_status() {
	let response = run_gateway([ 'status', '--json' ]);

	if (response.code != 0)
		return 'Статус временно недоступен.';

	let data;

	try {
		data = json(response.output);
	}
	catch (e) {
		return 'Статус временно недоступен.';
	}

	if (data == null)
		return 'Статус временно недоступен.';

	let main_ip = value_or(data?.vpn?.main?.egress?.ipv4, 'n/a');
	let torrent_ip = value_or(data?.torrent?.egress?.ipv4, 'n/a');

	return `🏠 CUDY Home Gateway

WAN: ${state(data?.network?.wan?.state)}
Direct egress: ${state(data?.network?.direct_egress?.state)}

MAIN VPN: ${state(data?.vpn?.main?.state)}
MAIN egress: ${main_ip} (${state(data?.vpn?.main?.egress?.state)})

Torrent: ${state(data?.torrent?.state)}
Torrent egress: ${torrent_ip} (${state(data?.torrent?.egress?.state)})

Redmi: ${state(data?.redmi?.state)}
ASATA: ${state(data?.asata?.state)}
Tailscale: ${state(data?.tailscale?.state)}
DNS: ${state(data?.dns?.state)}

Версия: ${value_or(data?.gateway_version, 'unknown')}`;
}

function handle_message(message, allowed_user, allowed_chat) {
	if (message == null)
		return;

	let from_id = message?.from?.id;
	let chat_id = message?.chat?.id;

	if (from_id == null || chat_id == null)
		return;

	if (`${from_id}` != allowed_user || `${chat_id}` != allowed_chat)
		return;

	let message_date = message?.date;

	if (message_date != null && message_date < STARTED_AT - STALE_SECONDS)
		return;

	let text = message?.text ?? '';

	switch (text) {
	case '/start':
		send_message(chat_id,
			'🏠 CUDY Home Gateway\n\nRead-only Telegram control plane активен.\n\n/status — текущий статус');
		break;

	case '/status':
		send_message(chat_id, build_status());
		break;

	default:
		if (length(text))
			send_message(chat_id, 'Доступные команды:\n/start\n/status');
		break;
	}
}

function poll_once(offset, timeout, allowed_user, allowed_chat) {
	let response = run_gateway([
		'telegram',
		'get-updates',
		`${offset}`,
		`${timeout}`
	]);

	let payload = parse_response(response, 'getUpdates');

	if (payload == null)
		return false;

	for (let update in (payload.result ?? [])) {
		let update_id = update?.update_id;

		if (update_id == null)
			continue;

		// At-most-once внутри одного boot/process lifetime:
		// сначала фиксируем следующий offset, затем обрабатываем update.
		save_offset(update_id + 1);
		handle_message(update?.message, allowed_user, allowed_chat);
	}

	return true;
}

let allowed_user = read_trimmed(USER_FILE);
let allowed_chat = read_trimmed(CHAT_FILE);

if (allowed_user == null || allowed_chat == null) {
	warn('telegram-poller: whitelist files are missing or empty\n');
	exit(70);
}

ensure_runtime_dir();

if (MODE == 'once') {
	let ok = poll_once(load_offset(), 0, allowed_user, allowed_chat);
	exit(ok ? 0 : 1);
}

if (MODE != 'loop') {
	warn('usage: telegram-poller.uc [gateway-path] [once|loop]\n');
	exit(2);
}

while (true) {
	if (!poll_once(load_offset(), LONG_POLL_TIMEOUT, allowed_user, allowed_chat)) {
		let sleeper = fs.popen('/bin/sleep 5', 'r');

		if (sleeper)
			sleeper.close();
	}
}
