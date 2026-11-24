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

## Исправление Windows stdin framing — 22.11.2026

Первый запуск владельца вернул 127: PowerShell 5.1 добавляет CRLF после строки
pipeline. После успешного ucode shell интерпретировал оставшийся CR как команду.
Прежний native-тест проверял LF внутри script, но отбрасывал хвост при проверке.

Builder теперь добавляет явный exit 0 после heredoc; set-e сохраняет ненулевой
статус самого collector. RED-тест воспроизвёл sh: CR: not found /127, GREEN
проверяет dash и BusyBox ash с реальным Windows-хвостом, а также сохранение
ошибки collector 23. Windows-тест теперь сравнивает весь stdin вместе с CRLF.
Старый пакет остаётся неизменным; исправленный пакет выдаётся в новой папке r2.

## Совместимость вывода маршрутов — 24.11.2026

Owner r2 report подтвердил DHCP, логический интерфейс UP, адрес CGNAT и NO
пересечения wan/lan, но показал MISSING route. После этого владелец подтвердил,
что интернет работает; отдельно сообщил о звонках Telegram через шлюз.

Выявлен воспроизводимый дефект probe: iproute2 скрывает dev при фильтре dev,
а parser требовал это поле. [Первичный источник](https://github.com/iproute2/iproute2/blob/main/ip/iproute.c):
filter.oifmask=-1 подавляет печать RTA_OIF. BusyBox в тестовом образе поле сохранял.
Теперь probe читает main-table default routes без device filter и выбирает
WAN-устройство сам; маршруты других устройств по-прежнему не принимаются.
Numeric 0.0.0.0/0 поддержан, неприписываемый устройству default становится UNKNOWN.

Три новых теста RED/GREEN. Дополнительно реальный iproute2-v7.0.0 в изолированном
network-none контейнере с собственной loopback route воспроизвёл старый MISSING
и новый PRESENT; адреса/маршруты хоста и CUDY не менялись. Наличие маршрута
на CUDY после исправления требует нового отчёта; исправление форматтера само
по себе не доказывает фактическое состояние маршрутизации владельца.
