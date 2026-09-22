# Telegram read-only

Этап `0.4` добавляет Telegram как read-only control plane. Он не меняет маршрутизацию, PassWall2, nftables, DNS или другие части data plane.

## Секреты

Telegram provisioning хранится только на роутере:

```text
/etc/home-gateway/secrets/telegram.token
/etc/home-gateway/secrets/telegram.user_id
/etc/home-gateway/secrets/telegram.chat_id
```

Файлы должны принадлежать `root` и иметь права `0600`. Token и whitelist не хранятся в Git. Token не должен попадать в логи и не передаётся `curl` через argv.

`telegram.user_id` и `telegram.chat_id` должны содержать только числовой Telegram ID без дополнительных символов.

## Транспорт

По умолчанию Telegram Bot API вызывается через существующий MAIN SOCKS:

```text
127.0.0.1:1082
```

Переопределения доступны только для диагностики через переменные окружения:

- `HG_TELEGRAM_TOKEN_FILE`
- `HG_TELEGRAM_PROXY`

## Диагностические команды

```sh
gateway telegram get-me
gateway telegram get-updates
gateway telegram get-updates OFFSET TIMEOUT
gateway telegram send-message CHAT_ID TEXT [REPLY_MARKUP]
gateway telegram edit-message CHAT_ID MESSAGE_ID TEXT [REPLY_MARKUP]
gateway telegram answer-callback CALLBACK_QUERY_ID [TEXT]
```

## Poller

На целевом OpenWrt установлен ucode `2026.01`, где `fs.popen()` принимает строковую команду. Poller shell-quote'ит каждый аргумент перед передачей в `/bin/sh -c`; Telegram payload не исполняется как shell-код.

Poller:

- принимает `message` и `callback_query` через long polling;
- допускает только один `user_id` и `chat_id`;
- фиксирует следующий `update_id` до обработки update;
- отбрасывает сообщения старше 120 секунд;
- поддерживает `/start` и `/status`;
- отправляет inline dashboard с кнопкой `🔄 Обновить`;
- отвечает на callback через `answerCallbackQuery`;
- обновляет dashboard через `editMessageText`, не создавая новое сообщение при refresh;
- хранит callback nonce, timestamp и `message_id` в runtime state;
- отклоняет callback старше 120 секунд, callback от старого dashboard и повторный callback после ротации nonce;
- использует runtime lock, чтобы loop-mode имел единственного активного poller;
- не изменяет data plane.

Runtime-файлы:

```text
/tmp/home-gateway/telegram.offset
/tmp/home-gateway/telegram.callback
/tmp/home-gateway/telegram-poller.lock
```

Они намеренно находятся в `/tmp`. После reboot старые Telegram updates отсекаются по времени, а callback старого dashboard не проходит из-за отсутствующего runtime state.

## procd

Постоянный poller запускается сервисом:

```text
/etc/init.d/home-gateway-telegram
```

Сервис использует procd и respawn. Сначала сервис проверяется вручную через `start`; автозапуск включается только после успешного runtime/restart теста.
