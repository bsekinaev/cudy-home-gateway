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
target-revision ucode compile, whitespace/secret scan PASS. Новый GitHub CI надо
проверить после публикации PR. Runtime inventory остаётся 19 файлов.

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

## Точное следующее действие

Опубликовать commit/PR ветки `feature/0.5-state-compaction`, проверить CI её HEAD,
провести итоговый review и merge после SUCCESS. Затем отдельная ветка 0.6; доступные
read-only части разрабатывать, неизвестное поведение внешнего vtest помечать BLOCKED.
Версию 0.5 и тем более 1.0 не объявлять принятой до снятия соответствующих блокеров.
