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

`0.5 — Health & Alerts / in progress`

Health Core нормализует WAN, DNS, MAIN и service/policy observations. Incident State добавляет debounce/hysteresis и persistent journal. Adaptive external confirmation вызывает secondary egress provider только после неуспешного primary probe. Data plane не изменяется.

Notification Dispatcher объединён в main через PR #6 после успешного CI: retry,
MAIN/Torrent delivery, recovery summary, CLI mute/categories и sysupgrade allowlist.
Доставка выключена по умолчанию. Добавлена crash-safe compaction с dedup receipts. Приёмка на CUDY ожидается;
CI каждой новой ветки проверяется отдельно. `0.5.0-dev` пока не является стабильным релизом.

[Установка и ограничения диспетчера](docs/NOTIFICATIONS.md).

## Документация

- [Архитектура](docs/ARCHITECTURE.md)
- [Инженерные решения](docs/DECISIONS.md)
- [План релизов](docs/ROADMAP.md)
- [Матрица приёмки v1.0.0 и блокеры](docs/ACCEPTANCE.md)
- [MAIN Transactions: read-only planner и ограничения](docs/MAIN_TRANSACTIONS.md)
- [Health Core](docs/HEALTH.md)
- [Incident State](docs/INCIDENTS.md)
- [Аудит vtest и блокеры 0.6](docs/VTEST.md)
- [Safe Actions и migration 0.7](docs/SAFE_ACTIONS.md)
- [Приватные backup: проверка и ограничения 0.9](docs/BACKUP.md)
- [Adaptive External Probes](docs/ADAPTIVE_PROBES.md)
- [CI/CD](docs/CI_CD.md)
- [Telegram read-only](docs/TELEGRAM.md)
- [Результаты preflight](docs/PREFLIGHT.md)

## Лицензия

MIT.
