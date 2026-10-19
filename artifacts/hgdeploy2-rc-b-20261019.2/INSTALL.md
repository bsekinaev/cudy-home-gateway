# HGDEPLOY2 RC-B 20261019.2 — ручная установка

Установщик собран и принят на disposable OpenWrt VM. Source:
`908dd3222b81992d9fee056bd015a1266a0ce8d7`.
PR #26 merged: `3ff6b53cccecf48c55443dce5bc713598b19fc7c`.
[Exact-head CI](https://github.com/bsekinaev/cudy-home-gateway/actions/runs/39281114459): SUCCESS, 11/11.
Codex review: 👍 на PR 19.10.2026 15:38:30 UTC при неизменном HEAD; открытых замечаний нет. Это не formal GitHub APPROVED review.

## Исправление TARGET_MEMORY

TR3000 256MB v1 имеет 256 MB NAND и 512 MB DDR3 RAM. Проверка MemTotal теперь 450000–524288 kB; MemAvailable >=32768 kB. Обязательные exact model, mediatek/filogic, OpenWrt и BusyBox gates сохранены.
Native predicates и VM fixture для MemTotal=496724 / MemAvailable=253116: PASS. Это не результат нового Preflight на CUDY: его запускает владелец ниже.
Оба exact-head CI 39279251325 и 39281114459: SUCCESS, 11/11 каждый. Повторный запуск suites для выпуска не требовался.

Старый RC-B 20261019.1 не изменён. Его отказ был до Prepare/Apply: откат и удаление locks не нужны. Используйте новый Windows-каталог и новую session; старые данные сохраните. Не редактируйте старые pins/session и не обходите guards.

## GO / NO-GO

**Установщик: YES. Production GO сейчас: NO.**
До Prepare/Apply владелец должен подтвердить доступный **рабочий** резервный способ SSH/восстановления. Физическая возможность подключить Ethernet этого не доказывает. Не добавляйте `-RecoveryPathConfirmed`, пока это условие не выполнено.

`READY_FOR_OWNER_MANUAL_MIGRATION=NO` до owner GO.
Work не подключался к CUDY и не выполнял production-операций.
Проверенный вне роутера sysupgrade archive существует, но его restore НЕ испытывался. Не считать RESTORE=PASS.

## Immutable файлы

Publication commit: `7256d2f0280ad67f0bbea280ff2265c39ee0148e`.

- Bundle SHA256: `d10beec6bc376a819a04e51cff1b4c779f2f0e1dec0412f20b38c6d2100a8f56`
- owner-b.ps1 SHA256: `ac51be175303cbe7a9a9cdf79c64123250066e3929397036d39b3b8a944d6840`
- Manifest SHA256: `67b65f1ceabe1534ff74fba8f6c486e9d02bfce9a7e7999875bd11929df467a1`

[Полный manifest](https://github.com/bsekinaev/cudy-home-gateway/blob/7256d2f0280ad67f0bbea280ff2265c39ee0148e/artifacts/hgdeploy2-rc-b-20261019.2/manifest.json) содержит SHA256, UID/GID=0, mode и размер всех файлов пакета. `candidate/` содержит 20 runtime, три receiver-файла и migration.sha256. `controls/` содержит 11 control-файлов и controls.sha256. Native coordinator и installer входят в пакет; Python и тестовый C fault injector на роутер не устанавливаются.

## Windows PowerShell: скачать и выполнить только Preflight

SSH host key должен уже быть известен и проверен владельцем: runner использует StrictHostKeyChecking=yes. При ошибке host key STOP; не отключать проверку.

```powershell
$Dir = Join-Path $env:USERPROFILE 'CUDY-RC-B-20261019.2'
New-Item -ItemType Directory -Force $Dir | Out-Null
Set-Location $Dir
$Base = 'https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/7256d2f0280ad67f0bbea280ff2265c39ee0148e/artifacts/hgdeploy2-rc-b-20261019.2'
Invoke-WebRequest -UseBasicParsing "$Base/owner-b.ps1" -OutFile .\owner-b.ps1
if ((Get-FileHash .\owner-b.ps1 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'ac51be175303cbe7a9a9cdf79c64123250066e3929397036d39b3b8a944d6840') { throw 'Runner SHA256 mismatch; STOP' }
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$P = @{
  Target = 'root@192.168.1.1'
  BundleUrl = "$Base/cudy-hgdeploy2-rc-b-908dd3222b81992d9fee056bd015a1266a0ce8d7.tar.gz"
  BundleSha256 = 'd10beec6bc376a819a04e51cff1b4c779f2f0e1dec0412f20b38c6d2100a8f56'
  SessionFile = (Join-Path $Dir 'rc-b-session.json')
}
& .\owner-b.ps1 @P -Stage Preflight
```

ExecutionPolicy меняется только для текущего PowerShell-процесса после проверки SHA скрипта. Preflight скачивает/проверяет публичный пакет, загружает его в новый приватный /tmp каталог и читает текущую установку. Работающий Gateway, VPN и конфигурация не изменяются. Apply не запускается.

Сохраните каталог Windows целиком, особенно `rc-b-session.json`: source, pins, target, remote kit и nonce связаны между этапами. Не публикуйте приватную диагностику.

## После подтверждённого owner GO: отдельные этапы

Сначала прочитать весь этот план. Только после подтверждения рабочего recovery path:

```powershell
& .\owner-b.ps1 @P -Stage Prepare -RecoveryPathConfirmed
& .\owner-b.ps1 @P -Stage Apply -RecoveryPathConfirmed
& .\owner-b.ps1 @P -Stage Verify
```

Запускать по одной команде, продолжать только после PASS. В случае ошибки остановиться. Не запускать Apply повторно: runner сохраняет applyAttempted ДО SSH-вызова.

Prepare удерживает kernel guard, проверяет exact legacy 18+3, сохраняет snapshot/runtime/journal/latest и приватные checkpoints, готовит SHA-pinned candidate и 11 control-файлов, включает S08, предварительно карантинируя S95. Runtime ещё не переключается; старый работающий Telegram остаётся работающим.

Apply проверяет источник/nonce/boot identity, публикует guarded Telegram init первым, контролируемо останавливает только Gateway Telegram через procd, фиксирует приватное состояние без rewind, переключает 20+3 файла и новый HG2 latest/anchor. Запускает два новых worker только при исходном was_running=1, проверяет PID/UID/cmdline, файлы, private state, selftest и doctor. Только затем публикует COMMITTED/admission и возвращает исходное S95 enablement.

Не перезапускает PassWall2/Xray, не меняет nftables/UCI/routes/DNS. Не выполняет reboot/sysupgrade/restore. MAIN route UNKNOWN и Redmi egress UNKNOWN не являются основанием менять VPN.

Verify читает terminal receipt, runtime/receiver, controls, latest, private state и procd. После успешного Verify владелец дополнительно проверяет CLI/status, Telegram status, VPN/DNS/Tailscale обычным использованием. Пришлите результаты без секретов. До owner LIVE feedback новые функции не разрабатываются.

## Rollback и аварийное восстановление

При ошибке Apply/Verify, сохранившейся SSH-связи и наличии kit:

```powershell
& .\owner-b.ps1 @P -Stage Rollback
& .\owner-b.ps1 @P -Stage Verify
```

Rollback проверяет отсутствие drift/newer deployment до side effects, останавливает только проверенные Gateway workers, возвращает исходные 18 runtime и три trusted legacy receiver-файла, original latest/journal, запускает старый worker только при исходном running intent. Публикует ROLLED_BACK только после verification. Приватные секреты/offset/callback не перематывает назад.

При потере SSH: восстановить связь через подтверждённый recovery path. Не запускать Apply заново. После reboot /tmp kit исчезнет, но durable snapshot/guard/journal остаются. С теми же Windows session и pins:

```powershell
& .\owner-b.ps1 @P -Stage UploadRecovery
& .\owner-b.ps1 @P -Stage Rollback
& .\owner-b.ps1 @P -Stage Verify
```

UploadRecovery только загружает и проверяет ТОТ ЖЕ пакет; Apply/rollback автоматически не выполняются. Interrupted APPLYING/RESTORING никогда автоматически не replay. S08 восстанавливает fence, не меняя runtime; неизвестный state остаётся fail-closed.

При BUSY не удалять lock/fence и не убивать неизвестные процессы. При SHA mismatch, чужом/повреждённом snapshot, drift, неизвестном nonce или более новом HG2 deployment — STOP, сохранить evidence. Не repin receiver, не удалять /etc/home-gateway-migration, не использовать bootstrap. Если Prepare оборвался до захвата nonce в session, Apply запрещён; сохранить вывод для read-only разбора, не угадывать transaction.

После rollback намеренно остаются durable evidence и два recovery control-файла (migration-state.uc, home-gateway-migration init) с S08. Это сохраняет boot safety. Повторная установка поверх retained state запрещена до отдельно проверенного retirement. Owner RC-A labs /tmp/hgdeploy2-rc-a.BIBaCJ и /tmp/hg-native-main.cPHJib не удаляются и не используются как production backup.

## Реально пройденные испытания и ограничения

General 211/0; Deploy 220/0; Release 21/0; пакет и runners 17/0 (включая 8 hardware regressions).
OpenWrt 25.12.5 VM: root install/rollback 30/0; real SIGKILL Apply + reboot 28/0; real SIGKILL Rollback + reboot 29/0; overlay identity + reboot 10/0; service-cycle 30/0; control-cycle 36/0. Остальные exact-head отчёты в CI/acceptance.json. Повторения suites не суммируются.

procd — настоящий PID1, BusyBox ash 1.37.0, фактические poller/init и candidate runtime. Legacy CLI в networkless x86 VM синтетический; VM doctor не объявляется CUDY doctor PASS. Reboot — настоящий guest kernel reboot с supervised cold boot того же диска; не warm hardware reset CUDY. PowerShell protocol проверен на PowerShell 7/Linux с локальными SSH/SCP doubles, не на Windows 11. Native owner-kit hash/inventory check и воспроизводимая двукратная сборка PASS.

Оставшиеся owner gates: рабочий recovery path и ручная LIVE-приёмка. CUDY installation/rollback ещё не выполнены, sysupgrade archive restore — NOT_TESTED. `MIGRATION_DONE` не выставлен.

