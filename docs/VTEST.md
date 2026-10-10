# vtest — аудит перед интеграцией 0.6

Статус: **частичная реализация, этап 0.6 не принят**.
Внешний `/usr/bin/vtest` был отмечен в preflight и cron, но его исходника,
CLI-контракта и формата результатов нет в этом репозитории.

```sh
gateway vtest --json
```

Размер проверяется через `stat` до чтения; hash/cron input дополнительно ограничен
`head -c`. Для provider создаётся приватный (0600) временный RAM snapshot
лимит+1 byte: oversized/failed capture не получает digest; snapshot удаляется при
штатном выходе, INT/TERM. SHA256 относится к полностью прочитанному snapshot.
После SIGKILL может остаться приватный bounded tmp-файл, удаляемый при reboot.
Ошибки reader/hash/parser передаются через BusyBox ash pipefail в
subshell; частичный/пустой digest после ошибки не публикуется. `wc -c` для этой проверки не используется.

Команда читает только metadata и SHA256 regular файла `/usr/bin/vtest` размером
до 256 KiB. Она проверяет наличие vtest-команды в root crontab до 64 KiB, не выводя
аргументы или содержимое cron/script. Symlink не считается проверенным provider.
Это fingerprint для сопоставления с предоставленным исходником, не доказательство
безопасности. Provider не выполняется даже для получения status.

JSON имеет `integration=BLOCKED`, `state=UNKNOWN`, `latest=null`, `history=null`,
`run_supported=false`. Null здесь означает **данные недоступны**, а не пустую историю
или IDLE. Наличие cron не означает успешные cron-runs.

`gateway vtest run quick|full|capability` пока возвращает 70 и не выполняет команду.
Другие аргументы возвращают 2. Нет автоматической смены MAIN или изменения UCI/nft.

Telegram `/vtest` и кнопка показывают эту readiness-информацию. Применяются существующие
user/chat whitelist, freshness, message ID, callback nonce и TTL 120 секунд. Никакие
provider/cron contents и raw stdout внешнего vtest не пересылаются. Запускающих кнопок
пока нет. Trusted overrides `HG_VTEST_PATH`, `HG_VTEST_CRONTAB`,
`HG_TELEGRAM_SECRETS_DIR`, `HG_TELEGRAM_RUNTIME_DIR` предназначены для local CLI/test;
Telegram не управляет этими путями.

## Для завершения

Нужен точный исходник внешнего vtest, соответствующий полученному SHA256, без секретов.
Аудит должен установить:

- реальные аргументы quick/full/capability/status, exit codes и JSON/text schema;
- пути current/history/progress, поведение cron и гарантии single-flight;
- subprocess tree, безопасную отмену/timeout и очистку temporary Xray;
- отсутствие изменения MAIN/UCI/nft, restart data plane и утечки node credentials;
- реальные ограничения CPU/RAM/длительности и возможность isolated fault tests.

После этого: адаптер результата, bounded persistent history, runner lock/timeout,
crash recovery, Telegram progress/result notifications и автоматизированная приёмка.
Не заменять node VPN tests проверкой наличия curl или успешным запуском gateway doctor.
LIVE только после отдельного разрешения владельца. Stage 0.6/release tag не считать готовыми.

14 автоматизированных tests выполняют production CLI/poller с изолированной Telegram
границей. Они проверяют отсутствие вызова provider, fingerprint/bounds, privacy,
whitelist, stale message, nonce и TTL. Они не доказывают работоспособность внешнего vtest.
