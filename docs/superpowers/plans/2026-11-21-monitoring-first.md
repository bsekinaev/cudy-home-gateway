# Monitoring First Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Поставить в первую очередь независимый мониторинг, уведомления и историю.

**Architecture:** Развивать существующий notifications worker; poller остаётся
отдельным процессом. Сохранить журнал инцидентов и очередь, добавить свежие
измерения и ограниченное хранение без изменений маршрутизации.

**Tech Stack:** OpenWrt ash/ucode/procd, Python unittest, OpenWrt VM, Windows 5.1.

**Spec:** [Согласованный проект](../specs/2026-11-20-internet-observability-revised-design.md).
Приоритет владельца от 21.11: пункты мониторинга/сообщений/истории прежде WAN.

## Global Constraints

- Всё на CUDY; Telegram без web UI и внешнего наблюдателя.
- Автоуведомления WAN/DNS/MAIN/REDMI круглосуточно, один сбой / одно восстановление.
- 7 суток подробностей / 30 суток сводок; до 15 минут несохранённого хвоста допустимо.
- UNKNOWN не означает recovery; повтор кэша не новое измерение; телефон не обязан присутствовать.
- Агент не подключается к рабочему роутеру; owner устанавливает проверенный пакет.
- Старт от установленного 62b5c4a; старые package contracts не ослаблять.

## Review Focus

- Доставка OFF, mute, ошибка очереди не останавливают независимое наблюдение.
- Зависший Telegram не вытесняет очередную проверку.
- Повтор кэша и рестарт не создают ложные подтверждения или recovery.
- Переполнение/отказ flash явно сокращает полноту, не выдаёт пропуск за доступность.
- Откат runtime не перематывает историю или очередь.

### Task 1: Collect while delivery is OFF

**Files:** notifications.uc; scripts/notifications/test_notifications.py.
**Interfaces:** Существующий gateway incidents tick вызывается worker независимо
от delivery enabled; очередь восстанавливается и отправляется только после tick.
Это первый инкремент, не готовая реализация независимого расписания или истории.

- [x] Процессный regression test с настоящим ucode worker и фиктивным gateway:
  disabled/muted/categories off, повреждённая очередь, отказ tick, singleton lock.
- [x] Наблюдать RED при выключенной доставке, затем устранить gating измерений.
- [x] Выполнить notifications suite: 50 tests PASS; ucode production module выполнялся в процессных тестах.

### Task 2: Fresh samples and bounded scheduling

**Files:** health.sh, network.sh, vpn.sh, incidents.uc, notifications.uc;
component tests и VM budget scenario.
**Interfaces:** Уникальные boot/incarnation/sequence samples, uptime timestamps,
context identity; cached evidence сохраняет ID; 3 новых сбоя / 2 успеха.

- [ ] В тестах закрепить повтор кэша, stale, UNKNOWN, restart, context switch.
- [ ] Ограничить весь цикл измерений и слот доставки; измерить полный бюджет,
  включая MAIN/fallback/429/backlog, и подтвердить либо явно пересмотреть цель 2–4 минуты.
- [ ] Не выдавать этот этап завершённым после одного исправления enabled gating.

### Task 3: Early history and query summaries

**Files:** history module (явный новый inventory), gateway, notifications worker,
telegram-poller.uc, tests хранения и восстановления.
**Interfaces:** Ограниченные samples/события, 7/30 суток, flush <=15 минут;
coverage/gaps/unknown отдельно от uptime. Summary только по запросу.

- [ ] RED/GREEN для ротации, частичной записи, заполнения, часов и reboot gaps.
- [ ] Сохранение подтверждённых событий отдельно; предел размера согласовать
  по фактическому RAM/flash/atomic-write budget, не назначать 8 MiB без замера.
- [ ] Telegram сводка за сутки/неделю и инциденты с покрытием и задержкой доставки.

### Task 4: Delivery and release

**Files:** notifications.uc, telegram.sh, owner package host/router inventory,
VM scenarios, Windows runner tests, README/release docs.
**Interfaces:** Прямая установка от 62b5c4a; scope WAN/DNS/MAIN/REDMI;
после полного offline отчёт с ID и наблюдаемыми границами, без лавины OPEN.

- [ ] Проверить grouping/catch-up/OFF/mute/429 и сохранение Kill Switch проблемы.
- [ ] Расширить только необходимый package scope, с явным handling новых файлов
  и rollback/recover; старые V1/V2 пакеты остаются в прежнем контракте.
- [ ] Exact-source CI/native crash/reboot gates, review, owner installer;
  отдельные owner Preflight/Apply/Verify, затем естественное наблюдение 24–72 часа.
