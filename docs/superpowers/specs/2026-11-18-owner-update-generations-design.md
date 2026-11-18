# Повторяемые owner updates HGDEPLOY2

Конкретизация одобренного следующего пункта roadmap: поддержать обновление
уже установленного d2039b6, затем доставить подготовленный Telegram status.
Владелец подтвердил работу /status и интернета на компьютере и REDMI.
Кабельный резерв доступен по требованию, подключается при потере основного доступа.

## Почему отдельные поколения

V1 принимает только исходный 6259245 и отсутствие /etc/home-gateway-owner-update.
Его COMMITTED journal уже существует. Повторный запуск или очистка этого журнала
не являются поддерживаемым обновлением. Перенос старого журнала также создаёт
неоднозначность для принятого S07 boot guard.

Выбран additive generation protocol: V1 journal, guard, исходная миграция и
исторические transactions сохраняются. Новые поколения используют отдельный
root /etc/home-gateway-owner-series и S06 boot guard. Это единственный выбранный
путь; повторная миграция и обычный CD не подходят по существующим recovery gates.

## Поддерживаемый объём

- Full pinned inventory: прежние 20 runtime paths, modes и SHA256.
- Изменять можно только observer/UI leaf files: telegram-poller.uc, dns.sh,
  health.sh, redmi.sh, status.sh. Непустой delta; остальные runtime/control pins
  неизменны. Первый пакет меняет только Telegram status.
- 14 migration/deploy control pins остаются привязаны к исходной принятой версии.
- Не изменяются UCI, nftables, routing, PassWall/Xray, Tailscale, secrets,
  notification policy, Telegram cursor, action state и приватные пользовательские данные.
- Safe Actions должны быть выключены; EXECUTING/UNKNOWN блокируют обновление.
  Updater координируется с actions.lock и deployment serial; не вызывает
  мутирующий actions show ради preflight. Привилегированные внешние writers
  во время owner maintenance window не запускаются.
- Windows PowerShell 5.1, стандартные ssh/scp и .NET; Python на компьютере
  владельца не требуется. Stages остаются Preflight/Apply/Verify/Rollback/Recover.

## Пакет и родитель

Формат HG_OWNER_UPDATE_V2. Source и baseline — immutable Git commits;
builder выполняется из source checkout, зависимости соответствуют ему.
Runtime blobs, updater/inspector/guardian, modes и complete file inventory
связаны manifest SHA256. Unknown paths, symlink/hardlink/PAX/GNU extension,
duplicate entries, неверный mode/size, drift и zero delta отвергаются.
Ограничения: compressed <=8 MiB, expanded <=8 MiB, file <=262144 bytes,
manifest <=65536 bytes, bounded entry count/depth. Wrapper проверяет USTAR
и все file hashes до remote extraction; на target проверка повторяется.

Начальный parent — принятый V1 d2039b6:
archive SHA256 a39fb710909661d6c03c4f2f73f3b7645017b14a07999c80666de6735b926eed,
manifest SHA256 430383e3b0bfff46fbee688068cfea4e1446ca4491d6ded83d67ef1179e6b0df.
Первый V2 пакет включает bounded bootstrap witness из этого V1 kit. В VM
используется VM_ONLY witness того же source, с другим profile/pin.
V1 inspector выполняет только read-only journal validation; current parent
runtime отдельно сравнивается с 20 baseline pins. Старый V1 journal остаётся
COMMITTED и не становится указателем на новую установленную версию.

Последующий V2 parent связывается с approved parent manifest, его source,
candidate inventory и generation receipt. Bootstrap witness сохраняется один
раз, без рекурсивного вложения старых пакетов. Старые runtime backups и journals
не переписываются. Parent kit/manifest — input builder с явным SHA256.

OWNER_MANUAL выдаётся только после exact-source CI, независимого review без
блокеров и полного native owner-series VM report. VM_ONLY закрыт x86/disposable
marker gate и не может применяться на CUDY. Source fixture commits допускаются
только в VM_ONLY и явно отмечаются в report; production payload точно из Git.

## Durable layout

Root /etc/home-gateway-owner-series (0700):
- generations/<id>/ — один журнал на попытку, включая сохранённый manifest,
  parent manifest identity, source/parent, kit pin, phase, logs и historical hashes;
- active — только единственный незавершённый/незавершённо-финализированный id;
- current — установленное Apply-поколение, отсутствует для исходного V1;
- latest — последняя завершённая операция, включая отдельный rollback receipt;
- candidate transactions — в прежнем /etc/home-gateway-deploy/<txid>, с full
  20-file runtime backup и manifests, совместимыми с текущим admission.

ID — tx. и 32 hex символа UUID операции. Windows сохраняет UUID в session до
первого RPC, поэтому потеря ответа не теряет identity попытки. Повторный Apply
после rollback требует новой session/UUID; старый id никогда не replay.
Не более 32 retained operations;
при лимите/нехватке места отказ без удаления evidence. Очистка/архивирование —
отдельная будущая процедура. Full backup/staging + reserve 8 MiB учитываются
до publication; RAM reserve >=64 MiB сверх пакета/staging. Historical inventory
ограничен 2 MiB/4096 строками; checksum читает файл, не огромный shell argument.

Terminal receipts неизменяемы. Успешный Apply остаётся COMMITTED исторически,
даже после возврата. Rollback создаёт отдельную operation с собственным backup
текущего runtime, меняет current на parent и latest на rollback receipt; старые
phase/logs/raw transactions не переписывает. Guardian пишет логи в RAM.

Каждый новый журнал содержит closed, bounded hash inventory исторической
миграции, V1 journal/anchor, прежних поколений и parent transaction. Проверяется
точное множество файлов, metadata и hash. Логи/состояние текущей попытки не
включаются в её собственный historical hash snapshot. Secrets/cursors/queues
не копируются и не восстанавливаются.

## Протокол

1. Read-only preflight: target, parent manifests/history/runtime, controls,
   no active/foreign deployment, parent procd workers, actions disabled, space,
   selftest/doctor. Не исправлять обнаруженный drift.
2. Kernel serial + actions exclusion; staged complete authenticated RAM lease
   публикуется rename. Ownership: boot ID + PID + /proc starttime; stale numeric
   PID не является доказательством живого writer.
3. PREPARING: durable owned intent, verified full parent backup и historical
   snapshot. Partial preparation recoverable по exact owned prefixes; неизвестные
   bytes сохраняются и блокируют recovery. Ранее runtime/boot links не меняются.
4. Полный PREPARED journal, проверенный S06 guard и durable active pointer
   должны существовать до quarantine/publication. До этого reboot может
   продолжить исходный проверенный parent; Apply не replay.
5. Quarantine S94/S95; startup FD8 exclusion дожидается допущенных init starts.
   Quiesce доказывает остановку именно обоих Telegram workers. Publication
   changed files через собственный staged sibling, sync и rename.
6. При mixed runtime только baseline/candidate bytes и owned prefixes;
   unknown bytes не восстанавливаются автоматически. Receiver и init fenced.
7. Postflight, startup guardian ready, candidate startup через procd; полная
   проверка обоих PIDs/commands/respawn. Guardian при гибели writer берёт serial
   и FD8, отзывает legacy pid, quiesces workers, не меняет runtime и не replay.
8. Candidate tx COMMITTED, raw latest, boot links, series latest/journal и
   active cleanup публикуются crash-consistently, затем lease retirement.
   Повторный Verify требует exact terminal state, pins, workers, doctor/selftest.

Оригинальный admission разрешает pid-bearing lease только при raw active.
Поэтому parent startup при rollback использует raw active=parent tx (его
COMMITTED receipt не меняется); после проверки workers active очищается,
lease снимается, final admission проверяется без pid-bearing fence.

Rollback создаёт новую операцию возврата к ближайшему parent текущего Apply,
не оригинальному 6259245 и не HGDEPLOY1. Recover незавершённой операции
возвращает её before identity и завершает только её ROLLED_BACK receipt.
Partial preparation до publication может завершиться ABORTED без runtime writes.
Terminal-before-lease retirement допускает только authenticated cleanup уже
принятого результата; после reboot можно запустить только этот exact runtime.
Для возврата полностью COMMITTED Apply нужен новый Rollback, не Recover.
Предыдущие sealed receipts не изменяются ни в одном из этих переходов.

S06 на boot только реконструирует PID-less fence для active generation,
включая interrupted terminal cleanup. Он не запускает Apply, rollback или service.
Проверенный V1 S07 guard остаётся неизменным и видит существующий новый fence.

## Проверки

Host: source-bound builder, parent archive/manifest validation, strict USTAR,
owner/VM separation, deterministic bundle, wrong source/ref, unknown file/mode,
lineage mismatch, limits и PowerShell syntax/parser regressions.

Native OpenWrt 25.12.5 procd PID1/ash/ucode, no network/shared directories:
- исходная migration + точная V1 d2039b6 установка в disposable VM;
- V1→V2 A реальный candidate, Verify, сохранность V1 evidence;
- V2 A→B, B rollback→A, новая B attempt, возврат A→V1, новый Apply после
  полного rollback chain; hashes всех прежних terminal receipts неизменны;
- missing parent/drift/unknown inventory/files/foreign locks/actions active;
- SIGKILL до intent, partial backup, PREPARED, guard/active/pointer publication,
  каждого changed file, CHECKING, startup и terminal cleanup;
- failed startup/postflight, PID reuse, delayed manual startup, interrupted
  recovery/handoff, repeated recovery, настоящий guest reboot и explicit recovery;
- private synthetic cursors/queues не rewound; network config/nft/routes unchanged.

Вторая generation fixture — deterministic Git child commit в disposable clone
с harmless observer comment, VM_ONLY; report отличает fixture от real candidate.
Первый production release допускает только real Git runtime и parent kit,
совпадающий с owner baseline. LIVE rollout выполняет владелец по отдельным stages.
