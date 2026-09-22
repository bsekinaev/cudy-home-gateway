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
gateway telegram send-message CHAT_ID TEXT
```

## Poller

`telegram-poller.uc` использует `fs.popen()` с argv-массивом, поэтому входные значения не интерпретируются shell. Poller:

- принимает updates через long polling;
- допускает только один `user_id` и `chat_id`;
- фиксирует следующий `update_id` до обработки сообщения;
- отбрасывает сообщения старше 120 секунд;
- поддерживает `/start` и `/status`;
- не изменяет data plane.

Runtime offset хранится в `/tmp/home-gateway/telegram.offset`. Callback-кнопки, TTL/nonce для callback и procd deployment добавляются следующей итерацией `0.4`.
