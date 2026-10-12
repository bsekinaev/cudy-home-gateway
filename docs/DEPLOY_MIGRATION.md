# HGDEPLOY1 → HGDEPLOY2: отдельная миграция, P0

Production migration **BLOCKED**. Здесь реализованы read-only legacy preflight и
Linux host-only rehearsal настоящих файловых операций/rollback. Python на CUDY
не устанавливается; rehearsal CLI не имеет SSH и требует disposable lab marker.
Ни один новый механизм не запускается автоматически из Gateway, Telegram или CD.

## Подтверждённый владельцем baseline 11.10.2026

CUDY TR3000, OpenWrt 25.12.5, BusyBox ash 1.37.0, Gateway 0.5.0-dev,
selftest 58 PASS/0 FAIL, Telegram procd running. HGDEPLOY2/actions/notifications
отсутствуют; latest COMMITTED, active отсутствует; оба SHA manifests проходят,
18 файлов, inventory-version отсутствует, deployment state root/0700.
Это не приёмка нового кода и не разрешение на установку.

Owner private sysupgrade archive: readable/SHA256 PASS, 137 записей (133 files,
4 links), содержит PassWall2/vtest/ASATA. Separate HG archive содержит 3 files и
2 dirs, SHA PASS, исходные 0700/0600. **Sysupgrade исключает /etc/home-gateway:**
critical persistence blocker. Ни один restore не проверен. Архивы не запрашивать,
не помещать в GitHub, CI, artifacts или Telegram.

## Реализовано вне роутера

* `legacy-preflight.sh EXPECTED_RECEIVER_SHA256`: только bounded reads, exact
  18-path manifests, COMMITTED/no active/no format marker, backup/live hashes,
  владельцы/права, no symlink/hardlink, отсутствие двух новых модулей. Не запускает
  receiver или сервисы. SHA receiver должен быть заранее независимо подтверждён.
* `migration_lab.py --lab-root ...`: private fsynced old/new snapshots, SHA-pinned
  exact candidate manifest (20 runtime + 3 receiver/init files), durable receipt,
  atomic per-file replace, отдельные PREPARING/PREPARED/APPLYING/COMMITTED/
  RESTORING/ROLLED_BACK. Legacy journal никогда не преобразуется и не помечается.
* Original latest pointer сохраняется в отдельном receipt; после commit новый
  receiver начинает без latest. Исходный legacy transaction/backup остаётся
  побайтно и с прежними правами. Rollback возвращает старые 18 файлов, receiver,
  wrapper/init и latest, удаляет только два собственных добавленных модуля.
* После interrupted APPLYING автоматический повторный apply запрещён: только
  verified rollback. Файлы могут иметь только собственные old/new hashes, любые
  drift/corruption/unsafe permissions останавливают работу до записи.
* Общий receiver lock во время записей не имеет PID: оба настоящих receiver
  отвергают такой incomplete lock даже при `recover`. Это durable fence до
  окончания/verified rollback. Busy/unknown lock не удаляется.
* После успешной миграции повторный apply проверяет 20 файлов и возвращает
  ALREADY_COMMITTED. После нового v2 deployment миграционный rollback запрещён:
  сначала требуется отдельное согласованное восстановление той транзакции.

28 isolated tests PASS: реальные FS/rename/fsync/flock, BusyBox ash legacy
apply/rollback/preflight, SIGKILL, interrupted rollback, exact inventories,
corrupted manifests/receipts/snapshots, traversal/symlink/hardlink, missing files,
drift/modes, повторный запуск и conflict с новым deployment. Caller/owner mismatch
проверяется на реальной stat metadata с test identity boundary: Work namespace
позволяет только UID 0, поэтому chown на другую UID здесь не утверждается.

Fixture `fixtures/legacy-engine-18.sh` — исходный public receiver из `c921c2d`,
SHA256 `4b1f9ea568167a67f24470615b31efe4b9fd7a68374e666443ad31945e58922e`.
Публичный `v0.5.0-dev` receiver уже содержит **19**, поэтому нельзя считать его
точной копией установленного 18-file receiver.
Owner evidence от 12.10.2026: SHA256 production
`/usr/libexec/home-gateway-deploy/engine.sh` совпадает с указанным SHA256 fixture.
Проверен файл из GitHub PR #18 на exact HEAD
`966c9b4498019b1ceaac83236c974c30e3362024`: base64 декодирован без преобразования
переводов строк, SHA256 вычислен локально. Это подтверждает identity engine по
сообщённому владельцем digest; router read/execute не выполнялись.
Mismatch gate не сработал. При любом последующем несовпадении — STOP до выяснения
причины; перепривязка pin к неизвестному receiver запрещена.
Production migration остаётся BLOCKED: wrapper/init identity и metadata,
coordinator, disposable OpenWrt/procd/boot/restore acceptance и резервный LAN
не подтверждены этим digest. Service/ucode fixtures не являются доказательством
procd/target semantics; production runtime отдельно проверяется pinned ucode/ash CI.
Host BusyBox 1.36.1 не доказывает BusyBox 1.37.0 target PASS.

## План будущей установки и rollback — только для согласования

1. Подтвердить резервный проводной LAN-доступ (сейчас подтверждён только Wi-Fi SSH).
   Сохранить оба owner private backups вне роутера; не запускать restore/sysupgrade.
2. Получить отдельное разрешение на конкретное окно/операции. Independently pin
   установленный receiver/wrapper/init, exact 18 inventory/metadata; неизвестный
   receiver или лишняя запись означает STOP и новый offline audit.
3. Завершить OpenWrt migration service/admission coordinator: исключить CD/boot
   recovery, подтвердить отсутствие текущего receiver и конкурирующих writers,
   сохранить состояние procd и запретить restart PassWall2/MAIN/ASATA/Torrent/Redmi.
   Rehearsal tool этого не выполняет и на CUDY не запускается.
4. На disposable OpenWrt с ash 1.37.0 проверить coordinator, real rc.common/procd,
   pinned ucode, space budgets, boot interruption и сохранение Telegram состояния.
5. Подготовить private old receiver/runtime/legacy journal/metadata/pointers и
   /etc/home-gateway snapshot. Отдельный migration journal/fence; не менять формат
   исходного журнала, не подделывать inventory-version, не заменять только receiver.
6. Установить проверенный согласованный 20-file runtime и receiver в этом окне,
   проверить SHA/uid/gid/mode/ash/ucode, post-check и Telegram running. Внести
   /etc/home-gateway/ в persistence; приватно проверить фактический sysupgrade list
   и inclusion всех трёх файлов. Новый bootstrap уже содержит allowlist path, но
   повторный bootstrap старого CUDY запрещён и проблема ещё не исправлена на target.
7. При сбое выполнить migration-specific verified rollback под той же exclusion:
   old 18 runtime + старый receiver/wrapper/init + исходный latest; убрать только
   actions/notifications, вернуть прежнее состояние Telegram. Не менять VPN/UCI/nft.
   Если есть новый deployment, drift или corrupt private snapshot — STOP/LAN repair.
8. Сохранить independent observed results. Reboot/sysupgrade/restore/soak/active
   vtest/MAIN changes требуют отдельных разрешений. Stable tag до приёмки запрещён.

Точная следующая задача: port coordinator на BusyBox/OpenWrt без Python и
подтвердить wrapper/init identity и metadata; затем isolated procd/boot
fault tests. Только после этого предлагать владельцу конкретный production apply.

Review fixes: own stale temporaries проверяются по exact snapshot prefix, metadata
и reserved names, только под migration/deploy fence; symlink/unrelated data
не удаляются. Actual SIGKILL до rename + relative-root refusal regressions.

## Upstream ash 1.37.0 regression

Дополнительный host CI builds официальный BusyBox 1.37.0 source archive, pin SHA256
3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4.
Source получен по HTTPS официального busybox.net; это recorded source hash,
не подтверждение vendor signature или fingerprint binary установленного CUDY.
Defconfig без tc (obsolete host CBQ headers); все используемые shell/FS/process
applets сохранены. Повторяются repository state/CLI и deploy/migration suites.
Это upstream Linux build, не target OpenWrt patches/config/procd/reboot PASS.
Ручное безопасное продолжение на host: ./scripts/ci/check-busybox137.sh.

Review: reset-preparation валидирует partial private tree и текущий legacy,
сохраняет flock inode/RESETTING phase до окончания очистки. Fence снимается
атомарным rename intact directory в receipt-owned sibling, cleanup повторяемый.
Interrupted prepare/reset/fence teardown negative tests; target migration BLOCKED.

Fence acquisition готовится в receipt-owned sibling и публикуется Linux
renameat2(RENAME_NOREPLACE), без unsafe fallback; own partial stage recoverable.
Legacy/rollback validation повторяется после acquisition под exclusion.
28 migration regressions включают actual SIGKILL pre-publish и foreign lock race.

Pre-mutation refusal на PREPARED/COMMITTED/ROLLED_BACK снимает только свой
fence; interrupted APPLYING/RESTORING остаётся fenced. Newer deployment/drift
не блокируется отвергнутым rollback. 28 migration tests PASS.

Temporary validation включена в conditional-unfence для pre-mutation refusal;
COMMITTED repeat также revalidates после acquisition. 28 migration tests PASS.
