# CUDY Home Gateway

Лёгкий control plane для домашнего шлюза на OpenWrt: наблюдение за состоянием сети, безопасная диагностика, уведомления в Telegram и ограниченный набор подтверждаемых действий.

> Проект не заменяет маршрутизацию и не является частью data plane. Сбой Telegram-бота или control plane не должен нарушать работу интернета, PassWall2/Xray, DNS, Tailscale и пользовательских политик.

## Цели

- единый CLI `gateway` для статуса и безопасных действий;
- машинный JSON API поверх CLI;
- health engine со состояниями `OK / DEGRADED / DOWN / UNKNOWN / MAINTENANCE`;
- Telegram UI на русском с inline-кнопками и живым dashboard;
- интеграция с существующим `vtest` без автоматической смены MAIN;
- транзакционные изменения конфигурации с snapshot, post-check и rollback;
- журнал действий, защита от replay и блокировки параллельных операций;
- локальные резервные копии с ротацией.

## Принципы безопасности

- только один разрешённый Telegram user/chat;
- никакого `/exec`, shell-консоли, произвольного UCI или nftables из Telegram;
- секреты не хранятся в Git и не выводятся в логи;
- опасные действия требуют подтверждения и имеют TTL;
- Telegram не используется как единственный аварийный канал администрирования;
- текущая стабильная конфигурация роутера остаётся независимой от проекта.

## Технологический подход

Системный слой проектируется для OpenWrt/BusyBox и использует штатные инструменты (`ash`, `uci`, `ubus`, `nft`, `curl`, `jsonfilter`, `procd`). Read-only preflight подтвердил наличие `ucode`, поэтому Telegram orchestration и state machine проектируются на `ucode`, а небольшие системные adapters остаются на BusyBox shell.

## Статус

`0.3 — Status & System / completed`

Реализован единый read-only статус для WAN/direct egress, MAIN VPN, Torrent, Redmi, ASATA, Tailscale, DNS/AdBlock-Fast и системных ресурсов. Human-readable и JSON режимы проверены на целевом CUDY, включая безопасные negative-tests для критичных состояний; финальный selftest проходит без ошибок. Data plane не изменялся.

Следующий этап — `0.4 Telegram read-only`.

## Документация

- [Архитектура](docs/ARCHITECTURE.md)
- [Инженерные решения](docs/DECISIONS.md)
- [План релизов](docs/ROADMAP.md)
- [Результаты preflight](docs/PREFLIGHT.md)

## Лицензия

MIT.
