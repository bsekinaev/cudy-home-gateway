# План релизов

## 0.1 — Foundation ✅

* read-only preflight целевого роутера;
* фиксация runtime и ограничений;
* структура проекта;
* базовые правила безопасности и хранения секретов.

**Статус:** завершён 21.09.2026. Data plane не изменялся.

---

## 0.2 — Gateway CLI ✅

* `gateway status`;
* `gateway status --json`;
* `gateway doctor`;
* `gateway selftest`.

**Статус:** завершён 21.09.2026. Regression-test: `version`, `status`, `status --json`, `doctor`, `selftest` — успешно; data plane не изменялся.

---

## 0.3 — Status & System ✅

* WAN, DNS, MAIN, egress;
* Torrent, Redmi, ASATA, Tailscale;
* uptime, load, RAM, flash, time sync;
* состояния OK/DEGRADED/DOWN/UNKNOWN/MAINTENANCE.

**Статус:** завершён 21.09.2026. Human/JSON status, fault-injection negative-tests, `doctor` и `selftest` проверены на целевом CUDY; data plane не изменялся.

---

## 0.4 — Telegram read-only ✅

* BotFather и secrets provisioning;
* long polling;
* русский inline dashboard;
* whitelist user/chat;
* защита от replay и устаревших callbacks.

**Статус:** завершён 22.09.2026. На целевом CUDY проверены long polling, inline refresh через `editMessageText`, whitelist, stale/replay/TTL callbacks, singleton lock, procd respawn и autostart. Data plane не изменялся.

---

# 0.5 — Health & Alerts ← текущий этап

## Реализовано ✅

* Health Core: нормализованные local/service observations;
* incident journal + hysteresis/debounce;
* freshness-aware и адаптивные внешние проверки;
* persistent notification queue;
* queued notification projection из incident events;
* CI checkpoint: GitHub Actions static/runtime-contract checks;
* CD checkpoint: read-only Tailscale router smoke проверен;
* release bundle: сборщик, manifest/SHA256, строгая проверка и CI artifact проверены;
* controlled install/rollback и workflow CD реализованы.

## Реализовано в отдельной ветке; приёмка ожидается

* notification dispatcher: durable attempt/receipt, bounded batch, flock/CLOEXEC;
* Telegram adapter с MAIN SOCKS и безопасным Torrent fallback;
* retry/backoff и глобальная пауза Telegram retry_after;
* recovery summary, CLI mute/categories, opt-in procd worker;
* идемпотентный Gateway sysupgrade persistence allowlist;
* строгая проверка канонической семантики ASATA nft rule в status collector;
* 46 notification/ASATA tests, включая SIGKILL, corrupt state, compaction/redo и transport parser;
* подробности: `docs/NOTIFICATIONS.md`.

## Остаётся до закрытия 0.5

* PR #6: CI SUCCESS, review выполнен, merge `93586f1`;
* compaction/dedup: PR #8 объединён (`3339492`), CI SUCCESS; 43 notification/ASATA tests PASS;
* LIVE delivery/reboot/procd/sysupgrade inventory, только после разрешения владельца;
* оригинальный ASATA keeper приватно изучен; независимый checker в PR #13,
  любой нужный repair заблокирован до координации external nft writers;
* разбор target-only ошибки redmi.sh в последнем CD plan;
* окончательная LIVE-приёмка ротации/persistence; backlog capacity остаётся fail-closed;

## Приёмка

* активация и финальная приёмка на CUDY ожидаются (`docs/DEPLOYMENT.md`).

---

## 0.6 — vtest

Частично: `gateway vtest --json`, SHA256/cron metadata, offline TSV сводки,
история до 20 запусков и Telegram view. Исходник получен, hash подтверждён;
23 adapter/authorization tests PASS. Runner/progress/alerts остаются BLOCKED:
нужны аудит PassWall helpers, ограничение cleanup и crash-safe process ownership.
Provider `status` не вызывается, поскольку выполняет сетевые probes.
См. `docs/VTEST.md` и `docs/SOURCE_AUDIT_2026-10-10.md`. Этап не принят.

* чтение текущего cron-run;
* история результатов;
* quick/full/capability запуск;
* уведомления без автоматической смены MAIN.

---

## 0.7 — Safe Actions

Разработаны disabled-by-default allowlist, durable TTL/nonce/message/boot confirmations,
replay protection, kernel locks/CLOEXEC, UNKNOWN crash recovery, bounded audit,
Tailscale-only MAINTENANCE и Telegram /actions. LIVE и HGDEPLOY2 bootstrap не приняты;
подробности `docs/SAFE_ACTIONS.md`.

* подтверждения;
* action locks;
* безопасные restart отдельных компонентов;
* MAINTENANCE-state.

---

## 0.8 — Transactions

**Статус:** разработан только read-only UCI planner; preflight/snapshot/apply/
rollback/recovery ещё blocked. См. [MAIN_TRANSACTIONS.md](MAIN_TRANSACTIONS.md).

* preflight ноды;
* snapshot;
* смена MAIN;
* post-check;
* transaction journal;
* rollback после ошибки/crash.

---

## 0.9 — Backup & Hardening

* sysupgrade backup;
* SHA256 и проверка архива;
* ротация последних 5 архивов;
* audit log;
* release rollback самого control plane.

---

## 1.0 — Stable

* soak-test без функциональных изменений;
* документация установки и восстановления;
* демонстрационный сценарий для портфолио.
