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
	let home = { text: '🏠 Главная', callback_data: 'nav:status' };
	let results = { text: '🧪 Результаты vtest', callback_data: 'nav:vtest' };
	let first = [ home, results ];
	if (view == 'status')
		first = [ { text: '🔄 Обновить статус', callback_data: 'nav:status', style: 'primary' }, results ];
	else if (view == 'vtest')
		first = [ { text: '🔄 Обновить результаты', callback_data: 'nav:vtest', style: 'primary' }, home ];
	return sprintf('%J', { inline_keyboard: [ first,
		[ { text: view == 'actions' ? '🔄 Обновить действия' : '⚙️ Действия', callback_data: 'nav:actions' },
		  { text: 'ℹ️ Помощь', callback_data: 'nav:help' } ],
        [ { text: '📊 За сутки', callback_data: 'nav:day' },
          { text: '🗓 За неделю', callback_data: 'nav:week' } ] ] });
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

function status_state(value) {
	return index([ 'OK', 'DEGRADED', 'DOWN', 'UNKNOWN', 'MAINTENANCE' ], value) >= 0 ? value : 'UNKNOWN';
}

function status_text(value, fallback) {
	if (type(value) != 'string' || !length(value) || length(value) > 128 || index(value, '\x00') >= 0 || match(value, /[[:cntrl:]]/))
		return fallback;
	// POSIX cntrl does not cover Unicode visual line/direction controls.
	for (let unsafe in [ '\u0085', '\u061c', '\u200e', '\u200f', '\u2028', '\u2029',
		'\u202a', '\u202b', '\u202c', '\u202d', '\u202e', '\u2066', '\u2067', '\u2068', '\u2069' ])
		if (index(value, unsafe) >= 0)
			return fallback;
	return value;
}

function status_ipv4(value) {
	if (type(value) != 'string' || length(value) > 15)
		return false;
	let m = match(value, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
	return m != null && m[0] == value && int(m[1]) <= 255 && int(m[2]) <= 255 && int(m[3]) <= 255 && int(m[4]) <= 255;
}

function status_egress(evidence, local_state, now, wan_state) {
	if (local_state == 'DOWN')
		return 'нет подтверждения (служба недоступна)';
	if (wan_state == 'DOWN')
		return 'нет подтверждения (канал WAN недоступен)';
	if (type(evidence) != 'object')
		return 'не проверен';
	let source = evidence.source;
	if (index([ 'live_probe', 'cache', 'stale_cache' ], source) < 0)
		return 'не проверен';
	let stamp = evidence.checked_at;
	if (type(stamp) != 'int' || stamp <= 0 || stamp > now)
		return source == 'stale_cache' ? 'нет свежей проверки' : 'не проверен';
	let age = now - stamp;
	// UI trust is bounded independently of backend cache configuration.
	if (source == 'stale_cache' || age > 300)
		return `нет свежей проверки · ${age} с назад`;
	if (evidence.state == 'DOWN')
		return `проверка неуспешна · ${age} с назад`;
	if (evidence.state != 'OK' || !status_ipv4(evidence.ipv4))
		return 'не проверен';
	let label = source == 'cache' ? 'проверен, кэш' : 'проверен';
	return `${label} · ${age} с назад · IP ${evidence.ipv4}`;
}

function status_profile_dns(evidence, process_state, now) {
	if (process_state != 'OK' || type(evidence) != 'object' ||
	    evidence.scope != 'profile_resolver' || evidence.source != 'live_probe')
		return { text: 'не проверен' };
	let stamp = evidence.checked_at;
	if (type(stamp) != 'int' || stamp <= 0 || stamp > now)
		return { text: 'не проверен' };
	let age = now - stamp;
	if (age > 120)
		return { text: `нет свежей проверки · ${age} с назад` };
	if (evidence.state == 'DOWN')
		return { text: `проверка неуспешна · ${age} с назад`, failed: true };
	if (evidence.state == 'OK')
		return { text: `ответ получен · ${age} с назад` };
	return { text: 'не проверен' };
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

	if (type(data) != 'object')
		return 'Статус временно недоступен.';

	let now = time();
	let main_state = status_state(data?.vpn?.main?.state);
	let torrent_state = status_state(data?.torrent?.state);
	let wan_state = status_state(data?.network?.wan?.state);
	let main_process = status_state(data?.vpn?.main?.xray_process);
	let torrent_process = status_state(data?.torrent?.xray_process);
	let main_local = main_process == 'DOWN' || main_state == 'DOWN' ? 'DOWN' : main_process;
	let torrent_local = torrent_process == 'DOWN' || torrent_state == 'DOWN' ? 'DOWN' : torrent_process;
	let direct = status_egress(data?.network?.direct_egress, 'UNKNOWN', now, wan_state);
	let main = status_egress(data?.vpn?.main?.egress, main_local, now, wan_state);
	let torrent = status_egress(data?.torrent?.egress, torrent_local, now, wan_state);
	let main_node = status_text(data?.vpn?.main?.configured_node?.name, 'неизвестен');
	let torrent_node = status_text(data?.torrent?.configured_node?.name, 'неизвестен');
	let updated = status_text(data?.generated_at?.local, 'неизвестно');
	let router_dns = status_state(data?.dns?.state);
	let redmi_process = status_state(data?.redmi?.xray_process);
	let redmi_dns = status_profile_dns(data?.redmi?.dns, redmi_process, now);
	let warnings = [];
	if (wan_state == 'DOWN') push(warnings, '⚠️ WAN: канал провайдера недоступен');
	if (router_dns == 'DOWN') push(warnings, '⚠️ DNS роутера: проверка не прошла');
	if (main_local == 'DOWN') push(warnings, '⚠️ MAIN VPN: служба недоступна');
	if (torrent_local == 'DOWN') push(warnings, '⚠️ Torrent: служба недоступна');
	if (redmi_process == 'DOWN') push(warnings, '⚠️ REDMI: Xray недоступен');
	if (redmi_dns.failed) push(warnings, '⚠️ REDMI: DNS профиля не отвечает');
	let attention = length(warnings) ? join('\n', warnings) + '\n\n' : '';

	return `🏠 CUDY Home Gateway
🕒 Снимок на ${updated}

${attention}🌐 Канал провайдера (WAN): ${wan_state}
Выход WAN: ${direct}
🌍 DNS роутера: ${router_dns}

🛡 Служба MAIN VPN: ${main_process}
Настроенный узел MAIN: ${main_node}
Активный узел по данным PassWall2: ${status_text(data?.vpn?.main?.active_node?.name, 'неизвестен')}
Выход MAIN: ${main}

⬇️ Служба Torrent: ${torrent_process}
Настроенный узел Torrent: ${torrent_node}
Выход Torrent: ${torrent}

📱 REDMI
Правила: ${status_state(data?.redmi?.routing_policy?.state)} · Xray: ${redmi_process}
Kill Switch: ${status_state(data?.redmi?.kill_switch?.state)}
DNS профиля: ${redmi_dns.text}
Интернет REDMI: не проверен

🖥 ASATA (устройство/правила): ${status_state(data?.asata?.state)}
🔗 Служба Tailscale: ${status_state(data?.tailscale?.state)}

Возраст проверок — на момент обновления сообщения.
Версия: ${status_text(data?.gateway_version, 'неизвестна')}`;
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
    let rows = [ '🧪 Результаты vtest', '' ];
    if (summary != null)
        push(rows, `Подходят для VPN: ${count(summary.eligible)} из ${count(summary.nodes)} узлов`);
    if (type(summary?.top) == 'array' && length(summary.top) > 0) {
        push(rows, 'Лучшие узлы по последнему отчёту');
        for (let item in slice(summary.top, 0, 3)) {
            if (type(item?.country) == 'string' && match(item.country, /^[A-Z]{2}$/) &&
                (type(item.mbps) == 'int' || type(item.mbps) == 'double') &&
                type(item.latency_ms) == 'int')
                push(rows, `• ${item.country} · ${item.mbps} Мбит/с · ${item.latency_ms} мс`);
        }
    }
    if (speed != null)
        push(rows, `Замеры скорости: ${count(speed.samples)}, успешных: ${count(speed.success)}, с ошибкой: ${count(speed.failed)}`);
    if (type(cap?.attempts) == 'int' && cap.attempts > 0) {
        let total = count(cap.attempts);
        push(rows, `Доступность, успешных попыток из ${total}`);
        push(rows, `Google ${count(cap.google)} · ChatGPT ${count(cap.chatgpt)} · OpenAI ${count(cap.openai)} · HTTPS ${count(cap.https)}`);
    }
    else if (cap != null)
        push(rows, `Проверка доступа: ${count(cap.nodes)}, подходят: ${count(cap.eligible)}`);
    if (speed == null && summary == null && cap == null)
        push(rows, 'Нет читаемого отчёта последнего теста.');
    if (type(data?.history) == 'array')
        push(rows, `Сохранённых запусков: ${length(data.history)}`);
    let recovery = run_gateway([ 'recovery-history' ]);
    if (recovery.code == 0) {
        let observed;
        try { observed = json(recovery.output); } catch (err) {}
        let reviews = observed?.reviews;
        if (observed?.schema_version == 1 && type(reviews) == 'array' && length(reviews) > 0) {
            let decision = reviews[length(reviews) - 1]?.decision;
            let labels = {
                KEEP_MAIN: 'оставить текущий узел',
                WAIT_FOR_WAN: 'дождаться проверки WAN',
                REVIEW_CANDIDATES: 'проверить резервы',
                INSUFFICIENT_EVIDENCE: 'недостаточно данных'
            };
            if (type(decision) == 'string' && index(keys(labels), decision) >= 0)
                push(rows, 'Последнее наблюдение MAIN — ' + labels[decision]);
        }
    }
    push(rows, '', 'Автовосстановление MAIN в Home Gateway ещё не включено.',
        'Обновление перечитывает сохранённый отчёт.');
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

🏠 Главная — состояние интернета и служб. Возраст замеров указан на момент снимка.
🧪 Результаты vtest — последний сохранённый отчёт о скорости и доступности узлов.
⚙️ Действия — перезапуски с отдельным подтверждением. Переход в другой раздел запрашивает отмену.
📊 За сутки и За неделю — история сохранённых наблюдений.

Команды /status, /vtest, /actions, /summary, /history и /help открывают те же разделы.`;
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

function history_view(period) {
    let result = run_gateway([ 'history', period == 'week' ? 'week' : 'day' ]);
    if (result.code != 0 || !length(trim(result.output)) || length(result.output) > 3500)
        return '📊 История пока недоступна. Наблюдение и сохранение проверяются отдельно.';
    return result.output;
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
		view == 'actions' ? view_data.text : view == 'vtest' ? build_vtest() : view == 'help' ? help_view() : index([ 'day', 'week' ], view) >= 0 ? history_view(view) : build_status(),
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
		view == 'actions' ? view_data.text : view == 'vtest' ? build_vtest() : view == 'help' ? help_view() : index([ 'day', 'week' ], view) >= 0 ? history_view(view) : build_status(),
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
	if (index([ '/start', '/status', '/vtest', '/actions', '/help', '/summary', '/history' ], text) >= 0)
		run_gateway([ 'actions', 'cancel', `${from_id}`, `${chat_id}` ]);

	switch (text) {
    case '/summary':
        send_dashboard(chat_id, 'day');
        break;
    case '/history':
        send_dashboard(chat_id, 'week');
        break;
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
	    index([ 'status', 'vtest', 'actions', 'help', 'day', 'week' ], parts[1]) >= 0) {
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
