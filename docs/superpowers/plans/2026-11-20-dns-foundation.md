# DNS Foundation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Ограничить время локальной DNS-пробы и проверять настроенный порт без ложного успеха другого resolver.

**Architecture:** Первый небольшой выпуск общей DNS-основы перед обнаружением REDMI endpoint. Реальный BusyBox nslookup проверяется на loopback fixture; адаптер остаётся read-only. Никаких новых runtime paths или служб.

**Tech Stack:** POSIX/BusyBox ash, nslookup, timeout, Python unittest для стенда.

**Spec:** [Общий проект](../specs/2026-11-20-internet-observability-revised-design.md), [программа](../../OBSERVABILITY_PLAN.md).

## Global Constraints

- Работа только в изолированной копии, без подключения к production CUDY.
- Пять разрешённых runtime leaves и 20 runtime paths не расширяются.
- Ошибка инструмента/невалидная конфигурация даёт UNKNOWN, не ложное OK.
- Успех локального DNS не доказывает интернет REDMI или свежий upstream answer.
- Общий deadline запроса: TERM через 3 с, KILL ещё через 1 с; это бюджет одной задачи, не всего цикла.

## Review Focus

- Нестандартный порт: отвечающий другой resolver не должен давать успех.
- Нет ответа: probe возвращается в пределах общего deadline.
- Невалидный порт/домен: не запускается некорректный запрос.
- Отсутствует timeout/nslookup: сбор продолжается с UNKNOWN.
- NXDOMAIN и NOERROR без IPv4-ответа не считаются успешным A-запросом.

### Task 1: Bounded DNS adapter

**Files:** Modify `src/usr/lib/home-gateway/dns.sh`; create `scripts/observability/test_dns.py`; modify `scripts/ci/check.sh`.

**Interfaces:** `hg_dns_probe DOMAIN PORT` sets `HG_DNS_PROBE_STATE` (OK/DOWN/UNKNOWN) and `HG_DNS_PROBE_REASON`; queries only 127.0.0.1 using BusyBox server:port. `hg_dns_collect` consumes these results for configured dnsmasq port.

- [x] Write UDP loopback fixture tests: valid A reply, NXDOMAIN, empty NOERROR, silence, invalid port/domain, unavailable tools; collection uses configured port.
- [x] Run `python3 -m unittest discover -s scripts/observability -v` in networkless pinned BusyBox container: observe failures for absent helper/current port handling.
- [x] Implement smallest helper and integrate collect. Use explicit A request and outer BusyBox timeout; validate args before execution, preserve UNKNOWN for unavailable tools. No dependency install on router.
- [x] Run new suite and repository `scripts/ci/check.sh`; inspect failures, don't weaken existing gates. Commit tested changes.

### Task 2: Owner preparation and evidence

**Files:** Create `scripts/observability/{router-dns-preflight.sh,check-dns.ps1,test_preflight.py,test_runner.ps1,README.md}`, `docs/WAN_RELOCATION.md`, `docs/reports/OBSERVABILITY_DNS_FOUNDATION_20261120.md`; update `docs/OBSERVABILITY_PLAN.md`.

**Interfaces:** Human checklist only; private OpenWrt config backup is distinct from runtime kit. Lab report names exact tested tools, outcomes and remaining admission work.

- [x] Write relocation preparation/restore checklist, subnet conflict check and owner acceptance; cable remains emergency reserve.
- [x] Record actual lab results and missing target-specific proof. This foundation alone is not complete REDMI monitoring or release acceptance.
- [x] Verify local documentation links and diff whitespace; run whole-branch review and commit corrections.

## Delivery boundary

Following work: discover REDMI runtime resolver safely, expose scope/freshness in health/status/Telegram, then exact-source release gates and owner kit. No installer is labelled ready from unit tests alone. User has authorized continuing this sequence; no additional confirmation needed for reversible development.

## Execution ruling

Owner discovery is necessary before REDMI endpoint implementation: upstream generated
configuration is not evidence of the installed version. Added a standalone read-only
helper with allowlisted output and Windows 5.1 offline tests; it does not install
this adapter or mutate the router. Continue endpoint work after the owner report.
