#!/usr/bin/env ucode
'use strict';

import * as fs from 'fs';

const GATEWAY = ARGV[0] || '/usr/bin/gateway';
const MODE = ARGV[1] || 'loop';

const SECRETS_DIR = getenv('HG_TELEGRAM_SECRETS_DIR') || '/etc/home-gateway/secrets';
const USER_FILE = SECRETS_DIR + '/telegram.user_id';
const CHAT_FILE = SECRETS_DIR + '/telegram.chat_id';
const RUNTIME_DIR = getenv('HG_TELEGRAM_RUNTIME_DIR') || '/tmp/home-gateway';
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

function read_user_id(path) {
	let value = read_trimmed(path);

	if (value == null || match(value, /^[0-9]+$/) == null)
		return null;

	return value;
}

function read_chat_id(path) {
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

function dashboard_markup(view) {
	// Navigation only reads fixed views. It never prepares or confirms an action,
	// so it need not expire with the separate 120-second action capability.
	return sprintf('%J', { inline_keyboard: [
		[ { text: view == 'status' ? '🔄 Обновить статус' : '🏠 Главная', callback_data: 'nav:status' },
		  { text: view == 'vtest' ? '🔄 Обновить результаты' : '🧪 Результаты vtest', callback_data: 'nav:vtest' } ],
		[ { text: view == 'actions' ? '🔄 Обновить действия' : '⚙️ Действия', callback_data: 'nav:actions' },
		  { text: 'ℹ️ Помощь', callback_data: 'nav:help' } ] ] });
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

function build_vtest() {
    let response = run_gateway([ 'vtest', '--json' ]);
    let data;
    try { data = json(response.output); }
    catch (e) { return '🧪 vtest: аудит временно недоступен.'; }
    if (response.code != 0 || data?.schema_version != 1 || data?.integration != 'BLOCKED')
        return '🧪 vtest: аудит временно недоступен.';
    // Fixed presentation never forwards external script/cron contents or output.
    let speed = data?.latest?.speed;
    let summary = data?.latest?.summary;
    let cap = data?.latest?.capability;
    // Numbers only: provider node IDs, names, locations and errors stay local.
    function count(value) { return type(value) == 'int' && value >= 0 && value <= 4096 ? `${value}` : '?'; }
    let rows = [ '🧪 Результаты vtest · только просмотр',
        `Тест: ${data?.provider?.installed == true ? 'найден' : 'не подтверждён'}`,
        `Расписание: ${data?.cron_configured == true ? 'настроено' : 'не подтверждено'}` ];
    if (speed != null)
        push(rows, `Speed samples: ${count(speed.samples)}, OK: ${count(speed.success)}, FAIL: ${count(speed.failed)}`);
    if (summary != null)
        push(rows, `Сводка: ${count(summary.nodes)}, подходят: ${count(summary.eligible)}`);
    if (cap != null)
        push(rows, `Проверка доступа: ${count(cap.nodes)}, подходят: ${count(cap.eligible)}`);
    if (speed == null && summary == null && cap == null)
        push(rows, 'Нет проверенных результатов последнего теста.');
    push(rows, `История наблюдений: ${type(data?.history) == 'array' ? length(data.history) : 'нет данных'}`);
    push(rows, 'Состояние запуска: UNKNOWN — по файлам не определяется.');
    push(rows, 'Запуск из бота заблокирован до проверки безопасности runner.');
    push(rows, 'MAIN автоматически не переключается.');
    return join('\n', rows);
}

function action_payload(response) {
    let value;
    try { value = json(response.output); } catch (e) { return null; }
    return value?.schema_version == 1 ? value : null;
}
function actions_view(issued, nonce) {
    let response = run_gateway([ 'actions', 'show' ]);
    let value = action_payload(response);
    let enabled = response.code == 0 && value?.enabled == true && match(nonce, /^[0-9a-f]{16}$/) != null;
    let navigation = json(dashboard_markup('actions')).inline_keyboard;
    let markup = dashboard_markup('actions');
    if (enabled) markup = sprintf('%J', { inline_keyboard: [
        [ { text: 'Перезапустить Tailscale', callback_data: `prepare-tailscale:${issued}:${nonce}` },
          { text: 'Перезапустить веб-интерфейс', callback_data: `prepare-uhttpd:${issued}:${nonce}` } ],
        ...navigation ] });
    return { text: `⚙️ Действия
${enabled ? 'Выберите действие и подтвердите за 120 секунд. Перезапуск Tailscale прервёт удалённый доступ: нужен доступ по LAN.' : 'Выполнение отключено или недоступно. Доступен только просмотр; кнопки перезапуска скрыты.'}
Нельзя перезапускать WAN, DNS, PassWall2, firewall или менять MAIN.`, markup };
}
function help_view() {
    return `ℹ️ Управление Gateway
🏠 Главная — состояние шлюза и сетевых служб.
🧪 Результаты vtest — только сохранённые наблюдения; тест не запускается.
⚙️ Действия — доступные перезапуски с отдельным подтверждением.
Кнопки просмотра работают и в старых сообщениях.
Переход в раздел запрашивает отмену ожидающего подтверждения.
Команды: /start, /status, /vtest, /actions, /help.
VPN, DNS, firewall и MAIN через это меню не меняются.`;
}
function action_confirmation(callback, action) {
    let chat = `${callback.message.chat.id}`, message = `${callback.message.message_id}`;
    let response = run_gateway([ 'actions', 'prepare', action, `${callback.from.id}`, chat, message ]);
    let value = action_payload(response);
    let ok = response.code == 0 && value?.status == 'CONFIRM_REQUIRED' && match(value?.token || '', /^[0-9a-f]{32}$/) != null;
    let markup = ok ? sprintf('%J', { inline_keyboard: [
        [ { text: 'Подтвердить перезапуск', callback_data: `confirm:${value.token}` } ],
        [ { text: 'Отмена · Главная', callback_data: 'nav:status' } ] ] }) : dashboard_markup('actions');
    let text = ok ? `Подтвердить ${action == 'restart-tailscale' ? 'restart Tailscale (удалённый доступ прервётся)' : 'restart uhttpd'}?
Подтверждение действует 120 секунд, один раз.
Для отмены нажмите «Отмена · Главная».` : 'Действие недоступно; выполнение не начато.';
    fs.unlink(CALLBACK_FILE); // Old menu callbacks cannot create another confirmation.
    run_gateway([ 'telegram', 'edit-message', chat, message, text, markup ]);
}
function confirm_action(callback, token) {
    answer_callback(`${callback.id}`, 'Проверка подтверждения…');
    let response = run_gateway([ 'actions', 'confirm', token, `${callback.from.id}`, `${callback.message.chat.id}`, `${callback.message.message_id}` ]);
    let value = action_payload(response);
    let text = response.code == 0 && value?.status == 'DONE' ? 'Действие завершено; повторное выполнение запрещено.' :
        value?.status == 'UNKNOWN' ? 'Исход предыдущего выполнения неизвестен. Повторно не запускалось; проверьте сервис по LAN.' :
        'Действие отклонено или завершилось ошибкой. Повторно не запускайте без проверки состояния сервиса.';
    run_gateway([ 'telegram', 'edit-message', `${callback.message.chat.id}`, `${callback.message.message_id}`, text, dashboard_markup('actions') ]);
}

function send_dashboard(chat_id, view) {
	view = view || 'status';
	let issued_at = time();
	let nonce = make_nonce();
	let view_data = view == 'actions' ? actions_view(issued_at, nonce) : null;
	let markup = view_data?.markup || dashboard_markup(view);

	let response = run_gateway([
		'telegram',
		'send-message',
		`${chat_id}`,
		view == 'actions' ? view_data.text : view == 'vtest' ? build_vtest() : view == 'help' ? help_view() : build_status(),
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

function edit_dashboard(chat_id, message_id, view) {
	view = view || 'status';
	let issued_at = time();
	let nonce = make_nonce();
	let view_data = view == 'actions' ? actions_view(issued_at, nonce) : null;
	let markup = view_data?.markup || dashboard_markup(view);

	let response = run_gateway([
		'telegram',
		'edit-message',
		`${chat_id}`,
		`${message_id}`,
		view == 'actions' ? view_data.text : view == 'vtest' ? build_vtest() : view == 'help' ? help_view() : build_status(),
		markup
	]);

	// Stable read-only buttons may refresh identical content. Telegram returns
	// HTTP 400 (curl exit 22) instead of success in that case. Keep the existing
	// capability state: no new message, no phantom nonce/TTL rotation.
	let unchanged;
	try { unchanged = json(response.output); } catch (e) { unchanged = null; }
	if ((response.code == 0 || response.code == 22) && unchanged?.ok == false &&
	    unchanged?.error_code == 400 && type(unchanged?.description) == 'string' &&
	    match(unchanged.description, /^Bad Request: message is not modified(:|$)/) != null)
		return true;
	// A timeout is ambiguous: Telegram may already have edited the message.
	// Only a definitive missing/uneditable-message receipt permits a new send.
	if ((response.code == 0 || response.code == 22) && unchanged?.ok == false &&
	    unchanged?.error_code == 400 &&
	    index([ 'Bad Request: message to edit not found', "Bad Request: message can't be edited" ], unchanged?.description) >= 0)
		return 'UNEDITABLE';

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
	if (index([ '/start', '/status', '/vtest', '/actions', '/help' ], text) >= 0)
		run_gateway([ 'actions', 'cancel', `${from_id}`, `${chat_id}` ]);

	switch (text) {
	case '/help':
		send_dashboard(chat_id, 'help');
		break;
	case '/actions':
		send_dashboard(chat_id, 'actions');
		break;

	case '/vtest':
		send_dashboard(chat_id, 'vtest');
		break;

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
				help_view(), dashboard_markup('help')
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

	let parts = split(data, ':');
	if (length(parts) == 2 && parts[0] == 'nav' &&
	    index([ 'status', 'vtest', 'actions', 'help' ], parts[1]) >= 0) {
		// Acknowledge before potentially slow status collection. Keep authorization
		// above this branch; action preparation/confirmation still use bound tokens.
		answer_callback(`${callback_id}`, '');
		let cancelled = run_gateway([ 'actions', 'cancel', `${from_id}`, `${chat_id}` ]);
		if (cancelled.code != 0)
			run_gateway([ 'telegram', 'send-message', `${chat_id}`,
				'Отмена действия не подтверждена. Не нажимайте старое подтверждение; дождитесь истечения его 120 секунд.' ]);
		if (edit_dashboard(chat_id, message_id, parts[1]) == 'UNEDITABLE')
			send_dashboard(chat_id, parts[1]);
		return;
	}
	if (length(parts) == 2 && parts[0] == 'confirm' && match(parts[1], /^[0-9a-f]{32}$/) != null) {
		confirm_action(callback, parts[1]);
		return;
	}
	let state = load_callback_state();

	if (state == null || length(parts) != 3 || (index([ 'refresh', 'vtest', 'actions', 'prepare-tailscale', 'prepare-uhttpd' ], parts[0]) < 0) ||
	    parts[1] != `${state.issued_at}` || parts[2] != state.nonce ||
	    `${message_id}` != state.message_id) {
		reject_callback(callback_id, 'Кнопка устарела — отправьте /status');
		return;
	}

	if (time() < state.issued_at || time() - state.issued_at >= CALLBACK_TTL) {
		reject_callback(callback_id, 'Кнопка устарела — отправьте /status');
		return;
	}

	// Telegram-клиент показывает progress bar до answerCallbackQuery.
	answer_callback(`${callback_id}`, '');

	if (parts[0] == 'prepare-tailscale' || parts[0] == 'prepare-uhttpd') {
		if (match(state.nonce, /^[0-9a-f]{16}$/) == null) return;
		action_confirmation(callback, parts[0] == 'prepare-tailscale' ? 'restart-tailscale' : 'restart-uhttpd');
		return;
	}
	if (edit_dashboard(chat_id, message_id, parts[0]) != true)
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

let allowed_user = read_user_id(USER_FILE);
let allowed_chat = read_chat_id(CHAT_FILE);

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
