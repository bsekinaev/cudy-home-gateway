# Telegram read-only

Этап `0.4` добавляет Telegram как read-only control plane. Он не меняет маршрутизацию, PassWall2, nftables, DNS или другие части data plane.

## Секреты

Bot token хранится только на роутере:

```text
/etc/home-gateway/secrets/telegram.token
```

Файл должен принадлежать `root` и иметь права `0600`. Token не хранится в Git, не должен попадать в логи и не передаётся `curl` через argv.

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
```

Они предназначены для provisioning и тестирования API. Долгоживущий poller, whitelist user/chat, callback TTL/nonce и inline dashboard добавляются следующими итерациями этапа `0.4`.
