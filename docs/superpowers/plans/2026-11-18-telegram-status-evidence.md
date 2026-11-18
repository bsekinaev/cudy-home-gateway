# Telegram status evidence implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline; final independent review.

**Goal:** честно отображать область и возраст имеющихся проверок на главной Telegram.
**Architecture:** один status JSON snapshot; чистые bounded presentation helpers
в существующем poller; синтетическая gateway/Telegram граница для actual ucode tests.
**Tech Stack:** pinned ucode 85922056ef7abeace3cca3ab28bc1ac2d88e31b1, Python unittest.
**Spec:** ../specs/2026-11-18-internet-observability-design.md

## Global Constraints

Нет веб-панели, новых probes, collectors, network writes или LIVE установки.
Не менять nonce/TTL/whitelist, Safe Actions, routing и immutable owner kit.
Подтверждение egress: age<=300 с, valid timestamp/source/state, local state!=DOWN.

## Review Focus

- Старый cache и future/missing timestamp не создают положительного статуса.
- REDMI не наследует доказательства MAIN и process/policy не обозначают интернет.
- Локальный DOWN имеет приоритет над положительным cache.
- Неверные JSON types/oversized text не роняют poller и не вводят в заблуждение.
- Новое представление не обходит авторизацию и не запускает дополнительные CLI calls.

## Task 1: Actual poller regression tests

Files: scripts/vtest/test_status_evidence.py.
- [x] Написать synthetic gateway bridge, /status update и проверки текста/call list.
- [x] Выполнить tests на исходном poller; наблюдать RED по ложному REDMI OK/freshness.

## Task 2: Presentation helpers и главная

Files: src/usr/lib/home-gateway/telegram-poller.uc, docs/TELEGRAM.md.
- [x] Реализовать typed/bounded state, node/IP и timestamp presentation.
- [x] Отображать scope/freshness/local failures, сохранить navigation.
- [x] Запустить новые и существующие poller/navigation/auth tests; GREEN (52/52).

## Task 3: Review и проверяемый source checkpoint

- [x] Независимое ревью всего diff; закрыты замечания по dedicated process state,
      WAN DOWN, Unicode line/bidi controls, configured node и snapshot-relative age.
      Регрессии воспроизведены RED, затем полный набор 52/52 GREEN.
- [ ] Проверить whitespace, LF, runtime delta и CI; открыть отдельный draft PR.
- [ ] Отдельно зафиксировать, что установка на текущий d2039b6 требует нового
      проверенного update path и не покрыта прошлым owner kit.
