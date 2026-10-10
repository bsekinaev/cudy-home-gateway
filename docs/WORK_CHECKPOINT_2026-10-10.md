# Контрольная точка 10.10.2026 — Issue #7

Завершённой новой версии нет. Остаётся `0.5.0-dev`; 0.5 ожидает LIVE-приёмки,
0.6 реализована частично. 0.7–1.0 ещё не реализованы. Production CUDY не изменялся,
MAIN не переключался, stable tag не создавался.

## Опубликованные результаты

- PR #6: https://github.com/bsekinaev/cudy-home-gateway/pull/6 — проверен актуальный
  HEAD, CI SUCCESS, code review доставки/receipts/429/locks/coalescing, merge:
  https://github.com/bsekinaev/cudy-home-gateway/commit/93586f1d2fc52064978ca94960e12fd0ceb443ca
  CI: https://github.com/bsekinaev/cudy-home-gateway/actions/runs/38074302925
- PR #8: https://github.com/bsekinaev/cudy-home-gateway/pull/8 — bounded compaction
  JSONL, dedup index + committed receipt snapshot, durable redo, producer lock,
  recovery до tick, исправленная длительность summary после удаления OPEN receipt.
  Commit: https://github.com/bsekinaev/cudy-home-gateway/commit/93e7fd2f76944832226ad446f38375f298dc642c
  Merge: https://github.com/bsekinaev/cudy-home-gateway/commit/33394920fb5094bf768321c31dd11c90cdfb9a81
  CI SUCCESS: https://github.com/bsekinaev/cudy-home-gateway/actions/runs/38075242934
- PR #9: https://github.com/bsekinaev/cudy-home-gateway/pull/9 — read-only vtest
  metadata/SHA256/cron inspection, Telegram view с whitelist/nonce/TTL. UNKNOWN/null
  для недоступных результатов; запуск заблокирован до аудита фактического provider.
  Commit: https://github.com/bsekinaev/cudy-home-gateway/commit/4a522bc75cabb59f5ce1edc75829c7c5f8d938ce
  Merge: https://github.com/bsekinaev/cudy-home-gateway/commit/f6392fa071dc0a1e01df5d466cc295365ff041e8
  CI SUCCESS: https://github.com/bsekinaev/cudy-home-gateway/actions/runs/38075742730
- PR #10: https://github.com/bsekinaev/cudy-home-gateway/pull/10 — исправление review:
  строгое чтение последнего transport suffix, malformed body/metadata не разрешает
  ложный fallback; message_id=0 не считается подтверждением.
  Runtime commit: https://github.com/bsekinaev/cudy-home-gateway/commit/dd5f6fefe8a161013a2b9d45855a10421e902b61
  PR #10 объединён после CI SUCCESS: https://github.com/bsekinaev/cudy-home-gateway/actions/runs/38076049798
  Merge: https://github.com/bsekinaev/cudy-home-gateway/commit/ca22d5160d2b45a556d7e7348ab337f8e9607f8e

## Проверки объединённого кода

102 PASS: 46 notification/ASATA + 14 vtest CLI/Telegram + 13 release + 29 deployment
под BusyBox ash. CI script PASS; target-revision ucode compile, ash syntax,
whitespace/secret scan PASS. Runtime inventory остаётся 19 файлов. Production не
содержит тестовых заглушек. HTTP/Telegram boundaries и faults изолированы в tests.

Crash/redo проверен на каждом publication boundary, включая committed receipt snapshot,
с потерей RAM-состояния, producer lock, corrupt/missing dedup, bounds/backpressure.
Это автоматизированные simulation, не LIVE reboot/sysupgrade/power-loss на CUDY.
Exactly-once sendMessage недостижим: потеря ответа/receipt может дать at-least-once duplicate.

## Блокеры приёмки

1. LIVE Telegram/SOCKS/procd/reboot/sysupgrade/flash требуют отдельного разрешения.
   Старые doctor 11 OK/selftest 58 PASS не подтверждают новый runtime.
2. Внешняя ASATA keeper отсутствует в Git. Нужны точные `/usr/bin/asata-udp-direct`
   и `/etc/init.d/asata_udp_direct` без секретов. Hardened collector не заменяет keeper.
3. Target-only redmi.sh CD plan error не разобрана: нет точного staging файла/доступа.
   Нужны byte-for-byte comparison staging с тем же release artifact, SHA256, версия
   target sh/BusyBox и syntax stderr. Старый installed файл не подходит для сравнения.
4. Исходник внешнего `/usr/bin/vtest` и формат current/history/progress отсутствуют.
   Для run/timeout/cancellation требуется аудит реальных аргументов, subprocess tree,
   cron lock и side effects. VPN node tests не заменяются gateway doctor.
5. 0.7 Safe Actions, 0.8 MAIN transactions, 0.9 backup/restore и 1.0 regression/soak
   остаются следующими этапами. Их критерии не объявлены выполненными.

## Исправление позднего review PR #9

Review P2 появился после merge #9: BusyBox `wc -c` читает весь поток, поэтому не
ограничивает чтение oversized provider/cron. Ветка `feature/0.6-bounded-inspection`
от main `ca22d51`: `stat` проверяет размер до чтения, `head -c` ограничивает hash/cron
input. Новый test запрещает `wc` и проверяет 100 MiB sparse provider без его чтения.
Review #11 также потребовал не принимать digest после ошибки head. Добавлен
subshell pipefail для hash/cron; partial reader и failed hasher fault tests PASS.
Повторный review #11 выявил рост provider после stat: bounded private snapshot
читает limit+1, проверяет размер и success до hash; race test PASS.
GitHub CI этой ветки проверяется отдельно перед merge; связанный thread #9 закрывается
только после публикации исправления. Версия/блокеры не меняются.

## Точное продолжение

Опубликовать PR `feature/0.6-bounded-inspection`, проверить HEAD/CI/review, merge только
после SUCCESS и закрыть связанное замечание #9. Затем:

```sh
git fetch origin
git switch -c feature/0.6-vtest-runner origin/main
```

Получить внешний vtest без секретов, сверить fingerprint через `gateway vtest --json`
на стороне владельца, прочитать исходник и реализовать run/history/progress/timeout/
result notifications по его реальному контракту. Снять ASATA/redmi/LIVE блокеры
0.5 отдельно. Каждый следующий этап — отдельная ветка, Russian commits, PR, CI и
checkpoint; не создавать v1.0.0 до полной приёмки.
