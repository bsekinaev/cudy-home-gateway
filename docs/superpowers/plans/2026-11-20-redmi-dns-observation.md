# REDMI DNS Observation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans task-by-task.

**Goal:** Проверять DNS актуального профиля REDMI независимо от телефона и показывать ограниченное доказательство в Telegram.

**Architecture:** dns.sh предоставляет bounded loopback A-query через BusyBox nslookup и отдельные timeout/awk. redmi.sh обнаруживает единственный dns-in в generated config, связывает с Xray PID/starttime и UDP socket inode через procfs, сверяет конфигурацию и UCI node до/после запроса. Отсутствие доказательства — UNKNOWN, без подмены MAIN.

**Tech Stack:** BusyBox ash/nslookup, системные timeout/awk/sha256sum, существующий ucode/fs; тесты Python UDP fixture и synthetic procfs.

**Spec:** [Переработанный проект](../specs/2026-11-20-internet-observability-revised-design.md).

## Global Constraints

- Только пять разрешённых runtime leaf-файлов, без новых служб и runtime paths.
- Не подключаться к production CUDY; owner выполняет тесты/установку.
- Порт 2004 из owner-отчёта — пример, discovery не закрепляет его константой.
- Не отключать Kill Switch и не переключать локацию; отсутствие телефона не ошибка.
- UNKNOWN или смена контекста не превращаются в успех или доказанный сетевой сбой.
- DNS-ответ не доказывает интернет телефона или свежесть upstream resolver.

## Review Focus

- Похожий config path другого процесса не должен подтверждать нужный профиль.
- Нужный порт у другого PID не должен проверяться как REDMI.
- Смена node/config/process во время запроса аннулирует результат.
- Без системных tools возвращается UNKNOWN, сбор не зависает.
- Успех DNS не меняет egress=UNKNOWN или подпись клиентского интернета.

### Task 1: Tool compatibility

**Files:** `dns.sh`, `scripts/observability/test_dns.py`.
**Interfaces:** сохранить `hg_dns_probe DOMAIN PORT` и state/reason.

- [x] Воспроизвести отсутствие awk/timeout applets при наличии отдельных команд.
- [x] Использовать отдельные timeout/awk, проверять capability, сохранить BusyBox nslookup.
- [x] Выполнить тесты правильного порта, deadline, неподдержанного инструмента и неверного имени.

### Task 2: Runtime-bound REDMI probe

**Files:** `redmi.sh`, create `scripts/observability/test_redmi_dns.py`.
**Interfaces:** `hg_redmi_dns_snapshot` prints `port|pid|starttime|socket_inode|config_sha256|node` only for one verified loopback UDP owner; no raw config. `hg_redmi_dns_collect` sets `HG_REDMI_DNS_STATE/REASON/PORT/CHECKED_AT/SOURCE`; snapshot comparison brackets `hg_dns_probe`. Test-only config/proc overrides follow existing HG_REDMI_RUNTIME_CONFIG convention.

- [ ] Write tests with real UDP resolver and controlled procfs for valid tunnel/legacy, wrong owner/path, duplicate endpoints/processes, missing files, changed config/node/starttime, absent tools, silence.
- [ ] Observe RED, implement bounded parser, exact arguments and socket ownership, compare context before/after.
- [ ] Integrate collect after existing config/process/policy checks; DNS failure makes ready policy DEGRADED, never egress OK. UNKNOWN remains explicit.
- [ ] Run all new tests and existing source contracts; commit.

### Task 3: Scope in status, health and Telegram

**Files:** `status.sh`, `health.sh`, `telegram-poller.uc`, tests in `scripts/observability` and `scripts/vtest/test_status_evidence.py`.
**Interfaces:** additive `redmi.dns` object with state, reason, scope=`profile_resolver`, port, checked_at, source. Existing egress/client proof unchanged. Health reason distinguishes DNS failure/unverified from policy readiness.

- [ ] Write failing scope/UI tests; implement additive JSON and concise DNS line with observation age.
- [ ] Test absent legacy fields, failed/unknown probe, stale/context-changed evidence and unchanged client-internet wording.
- [ ] Run repository CI, independent review and release gates before owner kit. Do not label source installable from unit tests alone.

## Owner report received

20.11.2026, report 13:18:17 Moscow: profile acl_A2dNs; dns-in tunnel,
loopback true, port 2004. BusyBox version unknown, nslookup A supported,
BusyBox timeout-k/awk unsupported, router DNS port 53. This is metadata,
not an active DNS response or proof that standalone tools are missing.
