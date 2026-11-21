# WAN Readiness Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Дать владельцу отдельную проверку нового WAN без установки runtime и изменения сети.

**Architecture:** Короткий ucode collector читает ubus WAN/LAN и фактический default IPv4 route. Отчёт содержит только выбранные поля без IP, MAC, логинов и полной конфигурации. Windows runner использует существующий owner-session исключительно как SSH identity, подаёт LF/UTF-8 script через stdin и проверяет source/schema. Пакет строится из точного Git commit. Это первая часть согласованного WAN-направления, а не обновление установленного мониторинга.

**Tech Stack:** OpenWrt ucode/ubus/ip, PowerShell 5.1, Python unittest, pinned offline test image.

**Spec:** [Утверждённый WAN scope](../specs/2026-11-20-internet-observability-revised-design.md), [памятка](../../WAN_RELOCATION.md).

## Global Constraints

- Прежний WAN-порт, новый провайдер или вышестоящий роутер; настройки меняет владелец.
- Агент не подключается к CUDY. Нет UCI writes, restart, updater или backup export.
- Не считать наличие адреса доказательством DNS/интернета; нет активных внешних проб.
- Протоколы DHCP/static/PPPoE; IPv6-only и неизвестный протокол обозначаются явно.
- Данные и диагностический пакет не меняют текущий runtime 1fc822c.

## Review Focus

- PPPoE default route без via не является отсутствующим маршрутом.
- Пересечение подсетей проверяется по диапазонам, а не совпадению строк.
- Повреждённые, отсутствующие и слишком большие ответы не становятся OK.
- Произвольные поля ubus, stderr и адреса не попадают в отчёт.
- SSH source/schema mismatch не сохраняется как успешная диагностика.

### Task1: Read-only collector

- [x] Написать RED tests для DHCP/static/PPPoE, отсутствующего маршрута, неизвестного протокола, IPv6-only, overlap/unknown LAN, malformed/oversize и privacy.
- [x] Реализовать scripts/observability/router-wan-probe.uc, фиксированные команды чтения и строгую проекцию HG_WAN_READINESS_V1.
- [x] Выполнить tests на настоящем ucode; никаких проб рабочего WAN.

### Task2: Owner package

- [x] scripts/observability/check-wan.ps1: проверенный session identity, deadline 20s, LF stdin, source/schema verification, private local report.
- [x] scripts/observability/build_wan_probe.py: committed sources, immutable output, CHECK-WAN.cmd, SOURCE, SHA256SUMS и ZIP.
- [x] Tests packaging/source, PowerShell syntax и fake SSH без роутера; обновить WAN_RELOCATION.md.
- [x] Независимый review: исправлен false READY для network/broadcast адресов; tests RED/GREEN.
- [ ] Сформировать source-bound пакет после финальных проверок и передать владельцу для проверки без установки.

## Следующий этап, не входящий в этот пакет

Изменение runtime network.sh: protocol/route semantics и привязка интерактивного кэша к сети; безопасный путь обновления от установленного 1fc822c. Новый runtime потребует отдельного source-bound CI/native/review/owner acceptance. Этот probe не исправляет runtime и не заявляет успешный перенос провайдера.

## Проверенные границы

Первый probe использует стандартные логические wan/lan и основную IPv4 route table.
Физический линк, DNS, доступность шлюза и интернет явно UNVERIFIED. READY —
состояние локального IPv4-пути, а не доказательство работы провайдера. Эти решения
ограничивают безопасную первичную проверку; runtime и список 20/14 не меняются.
