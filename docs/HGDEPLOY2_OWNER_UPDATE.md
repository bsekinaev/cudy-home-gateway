# HGDEPLOY2 — owner update и stabilization

## Подтверждённое состояние

Production source `62592457237e7f026786c086d1ca6fdd4b6c095d`, RC-B 20261020.2,
transaction `786dbec9-f1b6-4732-9ea4-23df99d372ed`: COMMITTED, embedded и отдельный
Owner Verify PASS; selftest 62/0, doctor 11 OK / 0 WARN / 0 FAIL.
Это owner-supplied LIVE evidence; Work к production не подключался.

[PR #30](https://github.com/bsekinaev/cudy-home-gateway/pull/30) уже merged:
head `701bcd44dd0210395cbba1e48581044e4abf6b26`, merge
`f30a1be3d31c422291e588e4dd50c4c154260585`.
[Exact-head CI](https://github.com/bsekinaev/cudy-home-gateway/actions/runs/39518047357)
SUCCESS 12/12; Codex review этого HEAD завершён без findings.
Этот runtime на CUDY не установлен.

Baseline source сохранён durable tag `hgdeploy2-production-baseline-20261020.2`
на исходном SHA. Это сохранение production source, не новый runtime release.
Чистый checkout с полной историей и tags должен содержать этот объект.

## Целевой аудит

В source baseline `scripts/deploy/engine.sh` и `transport.py` уже используют
HGDEPLOY2 / 20 файлов. HGDEPLOY1/18 сохраняется в legacy fixtures для репетиции.
Нельзя выводить текущий формат production receiver только из старого CD описания.

`migration-admission.sh --telegram-start` проверяет новый HG2 deployment,
полный manifest, backup и неизменные receiver pins. Оригинальный native anchor
проверяется по историческому handoff; его нельзя переписывать для новой версии.
Обычный receiver admission не заменяет точный source/runtime preflight.

Два ограничения обычного receiver:

- `recovery.init` на boot вызывает `engine.sh recover` и автоматически восстанавливает
  незавершённую установку. Для нового owner path требуется явная recovery-команда.
- `engine.sh restore` оставляет latest transaction в `ROLLED_BACK`. Terminal Telegram
  admission без active transaction требует `COMMITTED`, поэтому такой rollback
  нельзя считать полностью принятым post-migration update path.

## Кандидат updater

`scripts/owner_update/build_kit.py` выпускает только `VM_ONLY` пакет.
Production profile и production runner отсутствуют до завершения acceptance.
**READY_FOR_OWNER_MANUAL_UPDATE=NO. Не загружать VM kit на CUDY.**

Пакет содержит exact-source baseline и candidate inventory по 20 файлов,
14 baseline control pins, SHA256 каждого файла и отдельный package manifest.
Допустимый runtime delta — только `/usr/lib/home-gateway/telegram-poller.uc`.
Unknown files, symlink, неверные modes, несовпадающий source/inventory/pin
отклоняются. Inspection runner PowerShell только проверяет локальный архив.

Кандидат сохраняет полный проверенный runtime backup в новой HGDEPLOY2 transaction,
отдельный update journal и hashes исторического migration/native anchor evidence.
Оригинальная COMMITTED transaction, receipt и retirement archives не переписываются.
Перед публикацией отключаются только S94 deployment recovery и S95 Telegram boot links.
Runtime меняется через staging + sync + rename. Telegram останавливается и запускается
через procd; admission использует полный candidate manifest новой transaction.

Explicit rollback/recover возвращает исходный poller и original latest anchor;
это возврат к работавшему HGDEPLOY2. HGDEPLOY1 migration rollback не вызывается.
Guest reboot не должен повторять apply или автоматически восстанавливать runtime.
Отключённый Telegram до явного recovery допустим как fail-closed control-plane failure.
Terminal rollback записывается после восстановления boot links. Проверка workers
требует одновременно poller и notifications, их running state, PID и exact command
в procd и `/proc`; общий service running не считается достаточным.

VM-only selftest не доказывает CUDY doctor: кандидат явно печатает
`OWNER_UPDATE_DOCTOR=NOT_TESTED_VM`. Owner profile обязан выполнять doctor до и после
обновления; без этой реализации и новых gates production выпуск запрещён.

## Проверки и границы

Сценарий `owner-update` в `scripts/openwrt/run_vm.py` использует OpenWrt 25.12.5,
procd PID1, native ucode и BusyBox ash. Базовый HG2 готовится отдельным baseline
RC-B VM kit из exact source; это только disposable guest, не повторная LIVE migration.
Сценарий включает apply, rollback, drift/unknown manifest/foreign lock refusal,
SIGKILL до/после публикации и при rollback, настоящий guest reboot и explicit recovery.
Network config hashes, nft rules и route state сравниваются до/после.

Отчёт привязан к exact source commit. Наличие сценария не означает его PASS.
Старые migration VM результаты не являются evidence нового updater.
Не публиковать GO до полного успешного отчёта, exact-head CI и review.

Дополнительно нужны проверки всех torn journal/pointer writes, SIGKILL во время
частичного staging, повторной recovery и достаточного persistent space. Отказ
с сохранением evidence безопаснее продолжения из неизвестного состояния, но
сам по себе не доказывает завершённое recovery acceptance.

## Read-only owner preflight

Следующие команды выполняет владелец из существующей доверенной LAN SSH-сессии.
Они не устанавливают runtime и не меняют boot links. Сначала подтвердить рабочий
резервный доступ. Не использовать старый migration Apply или CD apply.

```sh
cat /etc/openwrt_release
ubus call system board
gateway version
cat /etc/home-gateway-migration/phase
cat /etc/home-gateway-deploy/latest
test ! -e /etc/home-gateway-deploy/active
test ! -e /tmp/home-gateway-deploy.lock
sh /usr/libexec/home-gateway-deploy/migration-admission.sh --telegram-start
gateway selftest
gateway doctor
gateway status --json
gateway notifications --json
ubus call service list '{"name":"home-gateway-telegram"}'
df -k /overlay /tmp
free
```

Ожидаются COMMITTED, runtime `0.5.0-dev`, успешная admission, два procd workers,
отсутствие active deployment/foreign lock. Эти observations не заменяют полный
pinned updater preflight. При несоответствии сохранить вывод и остановиться.
Не удалять migration locks, не исправлять SHA вручную.

Команды production update/rollback пока не выдаются: production kit не выпущен.
Нельзя заменять их прямым SCP poller или повторным запуском RC-B installer.

## Read-only owner soak — 24–72 часа

Начало и конец: сохранить время, uptime, gateway version/status/doctor/selftest,
notification summary, procd worker status, RAM, overlay и CPU load. Рекомендуемые
точки: T0, +1ч, +6ч, +24ч, +48ч и +72ч. Повторять следующие read-only наблюдения:

```sh
date -Iseconds
uptime
gateway status --json
gateway notifications --json
gateway incidents --json
ubus call service list '{"name":"home-gateway-telegram"}'
cat /proc/loadavg
free
df -k /overlay /tmp
```

Проверить непрерывность обоих workers, рост pending/error queue и повторные рестарты,
свободные RAM/overlay, WAN/DNS/VPN observations и PassWall2/Xray/Tailscale status.
Записывать для каждого инцидента время, симптом, component, duration, recovery и
действие владельца. Секреты и private backup не публиковать; приватный SSH output
оставлять локально и передавать только отредактированную сводку.

Telegram LIVE после будущего owner update: `/start`, `/status`, `/vtest`, `/actions`,
`/help`; Home со старого сообщения; Refresh в vtest; отсутствие дубля при
`message is not modified`; fallback для недоступного сообщения; TTL и one-shot actions.
Никаких автоматических vtest run и смены MAIN.

Без production fault injection. Reboot и sysupgrade — после отдельного согласования.
Soak/status не доказывают independent E2E traffic или реальный backup restore.
