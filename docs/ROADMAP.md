# План релизов

## 0.1 — Foundation

- read-only preflight целевого роутера;
- фиксация runtime и ограничений;
- структура проекта;
- базовые правила безопасности и хранения секретов.

## 0.2 — Gateway CLI

- `gateway status`;
- `gateway status --json`;
- `gateway doctor`;
- `gateway selftest`.

## 0.3 — Status & System

- WAN, DNS, MAIN, egress;
- Torrent, Redmi, ASATA, Tailscale;
- uptime, load, RAM, flash, time sync;
- состояния OK/DEGRADED/DOWN/UNKNOWN/MAINTENANCE.

## 0.4 — Telegram read-only

- BotFather и secrets provisioning;
- long polling;
- русский inline dashboard;
- whitelist user/chat;
- защита от replay и устаревших callbacks.

## 0.5 — Health & Alerts

- локальные проверки;
- адаптивные внешние проверки;
- incident journal;
- queued recovery summary;
- mute и категории уведомлений.

## 0.6 — vtest

- чтение текущего cron-run;
- история результатов;
- quick/full/capability запуск;
- уведомления без автоматической смены MAIN.

## 0.7 — Safe Actions

- подтверждения;
- action locks;
- безопасные restart отдельных компонентов;
- MAINTENANCE-state.

## 0.8 — Transactions

- preflight ноды;
- snapshot;
- смена MAIN;
- post-check;
- transaction journal;
- rollback после ошибки/crash.

## 0.9 — Backup & Hardening

- sysupgrade backup;
- SHA256 и проверка архива;
- ротация последних 5 архивов;
- audit log;
- release rollback самого control plane.

## 1.0 — Stable

- soak-test без функциональных изменений;
- документация установки и восстановления;
- демонстрационный сценарий для портфолио.
