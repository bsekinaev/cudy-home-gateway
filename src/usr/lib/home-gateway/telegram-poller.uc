#!/usr/bin/env ucode
'use strict';

import * as fs from 'fs';

const GATEWAY = ARGV[0] || '/usr/bin/gateway';
const MODE = ARGV[1] || 'loop';

const USER_FILE = '/etc/home-gateway/secrets/telegram.user_id';
const CHAT_FILE = '/etc/home-gateway/secrets/telegram.chat_id';
const RUNTIME_DIR = '/tmp/home-gateway';
const OFFSET_FILE = RUNTIME_DIR + '/telegram.offset';
const CALLBACK_FILE = RUNTIME_DIR + '/telegram.callback';
const LOCK_FILE = RUNTIME_DIR + '/telegram-poller.lock';

const LONG_POLL_TIMEOUT = 30;
const STALE_SECONDS = 120;
const CALLBACK_TTL = 120;

function read_trimmed(path) {
	let value = fs.readfile(path);

	if (value == null)
		return null;

	value = trim(value);

	return length(value) ? value : null;
}

function read_identity(path) {
	let value = read_trimmed(path);

	if (value == null || match(value, /^-?[0-9]+$/) == null)
		return null;

	return value;
}

function shellquote(value) {
	return `'${replace(value, "'", "'\\''")}'`;
}

function run_gateway(args) {
	// OpenWrt ucode 2026.01 принимает в fs.popen() строку команды.
	// Каждый аргумент shell-quote'ится до передачи в /bin/sh -c.
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

function acquire_loop_lock() {
	// The poller launches gateway/curl children while holding this lock.
	// O_CLOEXEC is required so a long-poll child cannot retain the flock
	// after the poller itself exits or is restarted by procd.
	let file = fs.open(LOCK_FILE, 'ae');

	if (!file) {
		warn('telegram-poller: unable to open lock file\n');
		return null;
	}

	if (file.lock('xn') == null) {
		warn('telegram-poller: another loop instance is already running\n');
		file.close();
		return null;
	}

	return file;
}

function load_offset() {
	let value = read_trimmed(OFFSET_FILE);

	if (value == null || match(value, /^[0-9]+$/) == null)
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

function make_nonce() {
	let uuid = fs.readfile('/proc/sys/kernel/random/uuid');

	if (uuid != null) {
		uuid = replace(trim(uuid), /-/g, '');

		if (length(uuid) >= 16)
			return substr(uuid, 0, 16);
	}

	return `${time()}`;
}

function save_callback_state(issued_at, nonce, message_id) {
	let file = fs.open(CALLBACK_FILE, 'w');

	if (!file) {
		warn('telegram-poller: unable to write callback state\n');
		return false;
	}

	file.write(`${issued_at}:${nonce}:${message_id}\n`);
	file.close();

	return true;
}

function load_callback_state() {
	let value = read_trimmed(CALLBACK_FILE);

	if (value == null)
		return null;

	let parts = split(value, ':');

	if (length(parts) != 3)
		return null;

	let issued_at = int(parts[0]);

	if (issued_at != issued_at || match(parts[1], /^[0-9a-zA-Z]+$/) == null ||
	    match(parts[2], /^[0-9]+$/) == null)
		return null;

	return {
		issued_at,
		nonce: parts[1],
		message_id: parts[2]
	};
}

function dashboard_markup(issued_at, nonce) {
	return `{"inline_keyboard":[[{"text":"🔄 Обновить","callback_data":"refresh:${issued_at}:${nonce}"}]]}`;
}

function answer_callback(callback_id, text) {
	let args = [
		'telegram',
		'answer-callback',
		callback_id
	];

	if (length(text))
		push(args, text);

	let response = run_gateway(args);
	return parse_response(response, 'answerCallbackQuery') != null;
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
	let updated = value_or(data?.generated_at?.local, 'n/a');

	return `🏠 CUDY Home Gateway

🌐 WAN: ${state(data?.network?.wan?.state)}
↗️ Direct egress: ${state(data?.network?.direct_egress?.state)}

🛡 MAIN VPN: ${state(data?.vpn?.main?.state)}
MAIN egress: ${main_ip} (${state(data?.vpn?.main?.egress?.state)})

⬇️ Torrent: ${state(data?.torrent?.state)}
Torrent egress: ${torrent_ip} (${state(data?.torrent?.egress?.state)})

📱 Redmi: ${state(data?.redmi?.state)}
🖥 ASATA: ${state(data?.asata?.state)}
🔗 Tailscale: ${state(data?.tailscale?.state)}
🌍 DNS: ${state(data?.dns?.state)}

🕒 Обновлено: ${updated}
Версия: ${value_or(data?.gateway_version, 'unknown')}`;
}

function send_dashboard(chat_id) {
	let issued_at = time();
	let nonce = make_nonce();
	let markup = dashboard_markup(issued_at, nonce);

	let response = run_gateway([
		'telegram',
		'send-message',
		`${chat_id}`,
		build_status(),
		markup
	]);

	let payload = parse_response(response, 'sendMessage');

	if (payload == null)
		return false;

	let message_id = payload?.result?.message_id;

	if (message_id == null)
		return false;

	return save_callback_state(issued_at, nonce, message_id);
}

function edit_dashboard(chat_id, message_id) {
	let issued_at = time();
	let nonce = make_nonce();
	let markup = dashboard_markup(issued_at, nonce);

	let response = run_gateway([
		'telegram',
		'edit-message',
		`${chat_id}`,
		`${message_id}`,
		build_status(),
		markup
	]);

	let payload = parse_response(response, 'editMessageText');

	if (payload == null)
		return false;

	return save_callback_state(issued_at, nonce, message_id);
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

	if (message_date != null && message_date < time() - STALE_SECONDS)
		return;

	let text = message?.text ?? '';

	switch (text) {
	case '/start':
	case '/status':
		send_dashboard(chat_id);
		break;

	default:
		if (length(text))
			run_gateway([
				'telegram',
				'send-message',
				`${chat_id}`,
				'Доступные команды:\n/start\n/status'
			]);
		break;
	}
}

function reject_callback(callback_id, text) {
	if (callback_id != null)
		answer_callback(`${callback_id}`, text);
}

function handle_callback(callback, allowed_user, allowed_chat) {
	if (callback == null)
		return;

	let callback_id = callback?.id;
	let from_id = callback?.from?.id;
	let chat_id = callback?.message?.chat?.id;
	let message_id = callback?.message?.message_id;
	let data = callback?.data ?? '';

	if (callback_id == null || from_id == null || chat_id == null || message_id == null)
		return;

	if (`${from_id}` != allowed_user || `${chat_id}` != allowed_chat) {
		reject_callback(callback_id, 'Недоступно');
		return;
	}

	let state = load_callback_state();
	let parts = split(data, ':');

	if (state == null || length(parts) != 3 || parts[0] != 'refresh' ||
	    parts[1] != `${state.issued_at}` || parts[2] != state.nonce ||
	    `${message_id}` != state.message_id) {
		reject_callback(callback_id, 'Кнопка устарела — отправьте /status');
		return;
	}

	if (time() - state.issued_at > CALLBACK_TTL) {
		reject_callback(callback_id, 'Кнопка устарела — отправьте /status');
		return;
	}

	// Telegram-клиент показывает progress bar до answerCallbackQuery.
	answer_callback(`${callback_id}`, '');

	if (!edit_dashboard(chat_id, message_id))
		warn('telegram-poller: dashboard refresh failed\n');
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

		if (update?.message != null)
			handle_message(update.message, allowed_user, allowed_chat);
		else if (update?.callback_query != null)
			handle_callback(update.callback_query, allowed_user, allowed_chat);
	}

	return true;
}

let allowed_user = read_identity(USER_FILE);
let allowed_chat = read_identity(CHAT_FILE);

if (allowed_user == null || allowed_chat == null) {
	warn('telegram-poller: whitelist files are missing or invalid\n');
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

// loop mode должен иметь единственного активного poller.
let loop_lock = acquire_loop_lock();

if (loop_lock == null)
	exit(73);

while (true) {
	if (!poll_once(load_offset(), LONG_POLL_TIMEOUT, allowed_user, allowed_chat)) {
		let sleeper = fs.popen('/bin/sleep 5', 'r');

		if (sleeper)
			sleeper.close();
	}
}
