# Контрольная точка 10.10.2026 — Issue #7

Завершённой новой версии нет: остаётся `0.5.0-dev`; 0.5 ожидает LIVE-приёмки.
Роутер не изменялся, stable tag не создан.

## GitHub

PR #6: https://github.com/bsekinaev/cudy-home-gateway/pull/6
Текущий HEAD был проверен заново: CI SUCCESS, открытых review threads/reviews нет.
Проведён code review доставки/receipts/429/locks/coalescing. PR переведён из draft
и объединён через GitHub с expected-head SHA; защиты ветки не обходились.
Merge: https://github.com/bsekinaev/cudy-home-gateway/commit/93586f1d2fc52064978ca94960e12fd0ceb443ca
CI: https://github.com/bsekinaev/cudy-home-gateway/actions/runs/38074302925

## Следующая итерация 0.5

Ветка `feature/0.5-state-compaction`, от актуального main `93586f1`.
Добавлены bounded compaction incident/notification JSONL, dedup index и committed
receipt snapshot; durable redo для нескольких файлов; восстановление до producer tick;
блокировка параллельного writer; сохранение pending/inflight и активных инцидентов.
Исправлен recovery duration после удаления полной OPEN receipt. Production использует
реальный ucode/fs и штатный Telegram adapter, тестовые faults находятся только в tests.

Проверки текущей итерации: 43 notification/ASATA tests PASS, 13 release tests PASS,
29 deployment tests PASS под BusyBox ash — всего 85. CI script PASS, ash syntax,
target-revision ucode compile, whitespace/secret scan PASS. GitHub CI PR #8 SUCCESS: https://github.com/bsekinaev/cudy-home-gateway/actions/runs/38075242934
PR #8 объединён: https://github.com/bsekinaev/cudy-home-gateway/commit/33394920fb5094bf768321c31dd11c90cdfb9a81. Runtime inventory остаётся 19 файлов.

## Незавершённое и блокеры

- LIVE Telegram/SOCKS/procd/reboot/sysupgrade/flash не выполнены. Старые doctor/selftest
  не являются доказательством нового runtime. Только отдельное разрешение владельца.
- ASATA collector проверяет nft семантику; исходника внешней keeper в Git нет.
  Для hardening нужны `/usr/bin/asata-udp-direct` и `/etc/init.d/asata_udp_direct`,
  с удалёнными секретами. Collector не считается заменой keeper.
- Target-only redmi.sh CD plan failure остаётся BLOCKED: нет доступа к точному
  target staging. Нужны SHA256 и byte-for-byte comparison staged файла с **тем же**
  release artifact, target `sh`/BusyBox version и полный syntax stderr. Старый
  установленный redmi.sh для сравнения не подходит. Новый production CD не запускался.
- Внешний `/usr/bin/vtest` подтверждён старой документацией, но его исходника и формата
  результатов в Git нет. Перед интеграцией запуска нужен аудит: аргументы, side effects,
  пути результатов, cron и cancellation. Запрещено угадывать API или автоматически менять MAIN.
- 0.6–1.0 ещё не завершены; soak/приёмка стабильной версии не выполнены.

## Частичная разработка 0.6

Ветка `feature/0.6-vtest-inspection` от нового main `3339492`.
Реальный read-only CLI читает наличие/SHA256 внешнего vtest и наличие cron,
Telegram `/vtest`/кнопка показывают readiness с whitelist/nonce/TTL. State/results/history
явно UNKNOWN/null; запуск fail-closed без выполнения внешнего скрипта. 10 новых tests
PASS, CI script PASS; всего текущая регрессия 95 PASS (43 + 10 + 13 + 29).
README/ROADMAP/VTEST описывают частичную готовность. Stage 0.6 не завершён.

## Точное следующее действие

Опубликовать commit/PR `feature/0.6-vtest-inspection`, проверить CI текущего HEAD,
провести review/merge после SUCCESS. Получить точный внешний vtest, сверить SHA256
через `gateway vtest --json` на стороне владельца, аудит side effects/API; затем
реализовать run/history/progress/timeout/notifications по фактическому контракту.
Отдельно снять LIVE/ASATA/redmi staging блокеры 0.5. После завершения доступной 0.6 —
отдельные ветки 0.7–1.0. Версия остаётся 0.5.0-dev; v1.0.0 не создавать до приёмки.
