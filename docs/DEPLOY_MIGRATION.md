# HGDEPLOY1 → HGDEPLOY2: отдельная миграция, P0

Production migration **BLOCKED**. Здесь реализованы read-only legacy preflight,
Linux host-only rehearsal файловых операций/rollback и native ucode/BusyBox
journal/fence primitives. Полного production installer ещё нет. Python на CUDY
не устанавливается; rehearsal CLI не имеет SSH и требует disposable lab marker.
Ни один новый механизм не запускается автоматически из Gateway, Telegram или CD.

## Подтверждённый владельцем baseline 12.10.2026

CUDY TR3000 256MB v1, OpenWrt 25.12.5, kernel 6.12.94, ash 1.37.0,
Gateway 0.5.0-dev: selftest 58 PASS/0 FAIL, doctor 11 OK/0 WARN/0 FAIL.
Telegram отвечает на read-only status; это не acceptance dispatcher/actions.
RAM 212 MiB, overlay 145.3 MiB. Working VPN/DNS/ASATA не изменять;
MAIN route и Redmi egress UNKNOWN не считать неисправностью.
Legacy latest COMMITTED, active отсутствует, 18 файлов, inventory-version
отсутствует, deployment state root/0700. Ethernet SSH проверен ранее;
для ручного migration window нужен доступный резерв восстановления.

Владелец исправил sysupgrade inclusion `/etc/home-gateway/`, сохранив исходный
sysupgrade.conf. `sysupgrade -l`: 139 entries, 3 HG files. Настоящий backup:
140 entries, 3 private HG files, TAR.GZ читается; CUDY/Windows SHA совпадают,
Windows tar.exe verification PASS. SHA256:
`986ceab1b0ed4eb06df359adf5f333348f25d929d27d4aed456452c07259ef33`.
WINDOWS_BACKUP_VERIFICATION=PASS; **RESTORE=NOT_TESTED**.
Существуют независимые owner-private backups. Архивы/секреты не запрашивать
и не публиковать в GitHub, CI или Telegram.

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

40 isolated tests PASS: реальные FS/rename/fsync/flock, BusyBox ash legacy
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
Owner identity PASS для всех трёх c921c2d файлов; wrapper SHA256
`d8694eb76c86f16dbae2599e8d68e20dfcf9d8334a488f0f407c84264099946f`,
recovery init SHA256 `5b747dff42649914e4b231de2d5ade0171eedad40d5fb53f43e4d869d08a2630`.
Оба digest независимо пересчитаны из точных git blobs c921c2d и совпали.
Production migration остаётся BLOCKED: coordinator, target metadata/preflight,
disposable OpenWrt/procd/boot/rollback acceptance и доступный recovery window. Service/ucode fixtures не являются доказательством
procd/target semantics; production runtime отдельно проверяется pinned ucode/ash CI.
Host BusyBox 1.36.1 не доказывает BusyBox 1.37.0 target PASS.

## План будущей установки и rollback — только для согласования

1. Обеспечить доступный резерв восстановления в окне: Ethernet SSH уже проверен ранее.
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
   проверить SHA/uid/gid/mode/ash/ucode, post-check и Telegram running. Сохранить
   уже исправленный владельцем /etc/home-gateway/ persistence; inclusion трёх
   файлов и backup integrity подтверждены. Повторный bootstrap запрещён.
7. При сбое выполнить migration-specific verified rollback под той же exclusion:
   old 18 runtime + старый receiver/wrapper/init + исходный latest; убрать только
   actions/notifications, вернуть прежнее состояние Telegram. Не менять VPN/UCI/nft.
   Если есть новый deployment, drift или corrupt private snapshot — STOP/LAN repair.
8. Сохранить independent observed results. Reboot/sysupgrade/restore/soak/active
   vtest/MAIN changes требуют отдельных разрешений. Stable tag до приёмки запрещён.

Точная следующая задача: port coordinator на BusyBox/OpenWrt без Python и
проверить target metadata без повторного запроса подтверждённых identity; затем isolated procd/boot
fault tests. Только после этого предлагать владельцу конкретный production apply.

Review fixes (12.10): временные файлы создаются в отдельном private 0700 staging
в migration state, под kernel flock, с marker и точным target-derived inventory.
В shared runtime `.migration-new` считается чужим даже при пустом содержимом или
совпадающем prefix и никогда не удаляется. Snapshot prefix используется только
для принадлежащих этому private staging частичных записей. Реальный SIGKILL до
rename проверен. Rename требует одного filesystem; cross-device отказ сохраняет
fence для recovery, target mount layout не подтверждён.
Rollback PREPARED/ROLLED_BACK принимает только old/absent, COMMITTED только new,
APPLYING/RESTORING — old/new mixed state. Journal commit/was-running/format bound
до записи, exact receiver pin проверяется в prepare/load, GID mismatch rejected.
Read-only preflight требует canonical latest bytes, включая единственный LF.

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

12.10 additional review: preparation revalidates full legacy under the shared
fence before PREPARED, and preparation-only fences/reset are recoverable.
Canonical phase bytes are mandatory, preflight checks directory GID, and rollback
postcheck verifies all 18 runtime files plus engine/wrapper/recovery init.
39 migration + 32 deploy = 71 tests PASS on upstream BusyBox ash1.37.0.

Final preparation crash boundary: reset recovers receipt-owned acquisition
staging/pending marker via fence before removing receipt; actual SIGKILL during
preparation marker rename tested. 40 migration + 32 deployment = 72 PASS.

## Native journal и admission — 13.10.2026

`scripts/deploy/migration-state.uc` реализует private overlay journal, kernel
flock с CLOEXEC, checked BusyBox `fsync` файла/каталога и atomic same-filesystem
publication. Общий RAM fence — атомарный symlink на nonce-bound private fence;
rename между overlay и tmpfs не используется. Старый и новый receiver отвергают
PID-less fence. После потери RAM fence его можно восстановить; повтор APPLYING
запрещён. Неизвестный state, hardlinked symlink, nonce mismatch и оставшийся
`phase.new` требуют recovery, без автоматического удаления/повторного apply.

Receiver сериализует только публикацию/снятие PID lease коротким BusyBox flock
`/tmp/home-gateway-deploy.serial`. FD закрыт до запуска gateway/services. Cleanup
сверяет inode и PID владельца; foreign contents не удаляются рекурсивно. Это
защищает stale recovery от гонки второго recovery, сохраняя общий migration fence.
Read-only admission проверяет metadata одним ucode process; Telegram startup
проверяет exact 20-file manifest одним bounded checksum process. Непубликованные
`phase.new`/`admission.new` блокируют даже старый terminal receipt после reboot.

Local BusyBox ash 1.37.0 / pinned ucode: deployment 99 PASS, general 211 PASS,
release 21 PASS. Journal tests выполняют настоящие flock/fsync, SIGKILL и проверку
CLOEXEC, но не заменяют полный target migration/rollback acceptance. Native
state module пока не устанавливается на production и не публикует admission:
это обязанность будущего полного verifier/coordinator после проверки snapshots,
всех runtime/receiver bytes/metadata, legacy journal и latest.

Следующий незакрытый gate: production-compatible snapshot/apply/rollback и
legacy boot/service admission в едином coordinator, включая interrupted
RESTORING, полный 18→20→18 roundtrip и Telegram state preservation. Owner SHA,
backup inclusion и Windows integrity уже подтверждены; owner restore NOT_TESTED.

Native state/admission VM: source `1717823cad5f4e2ac683e8273b6053d536324abc`,
64 PASS / 0 FAIL, official networkless x86 OpenWrt25.12.5, procd PID1, ash1.37,
actual SIGKILL/CLOEXEC, overlay-vs-tmpfs fence, reboot re-acquisition and three
concurrent/stale receiver guard checks. Это synthetic state/admission acceptance,
не полный migration/rollback или owner restore PASS. GitHub VM input gate
отклонил изменившийся upstream index; прежний подписанный public `packages.adb`
с сохранённым SHA теперь vendored для воспроизводимости, без перепривязки pin.

State mutators и snapshot caller проверяют открытый kernel guard и точный root;
после close() или при root mismatch запись/fence/release запрещены.

## Native legacy snapshot — следующий coordinator компонент

`scripts/deploy/migration-snapshot.uc` выполняет prepare/verify под открытым
root-bound state guard и owned fence. До snapshot writes проверяются exact18
runtime inventory, все три неизменные c921c2d pins, live/backup manifest hashes,
canonical latest/COMMITTED/commit/was-running и safe metadata. Сохраняются old18,
receiver/wrapper/recovery init, latest и весь current legacy transaction с backup
и bounded logs. Старый journal, inventory-version и live runtime не изменяются.

Snapshot file permissions сохраняются, его directories private0700; reads
сверяют lstat с открытым FD и metadata после read. Все copies fsynced и проходят
SHA readback; source повторно проверяется до publication. Receipt связан с nonce
state marker. Verify требует exact snapshot tree, trusted pins, canonical journal,
metadata и согласованные runtime/backup manifests. Неизвестные files/empty dirs,
symlink/hardlink, corruption или partial receipt/snapshot означают STOP.

Бюджет:128 files, source sum≤8MiB, each≤256KiB; free space≥2×source+1MiB reserve.
Partial snapshot после fsync failure/SIGKILL сохраняется fenced; auto-adoption и
повтор prepare запрещены. После snapshot phase остаётся PREPARING: PREPARED и
admission нельзя публиковать до полного candidate/coordinator verification.
Private snapshots не входят в git/CI artifacts. Это не runtime apply/rollback,
не owner restore PASS и не готовая production installation procedure.

Review hardening: initial journal создаётся в unique private nonce staging и
публикуется только целиком после file/dir fsync. Прерванный pre-publication stage
не принимается и не удаляется; явный retry создаёт свежий nonce под тем же flock,
не блокируя неизменный runtime. SIGKILL и fsync failure до publication проверены.
Каждый transition требует owned persistent/RAM fence, release запрещён при
pending admission.new, cleanup receiver bounded waits≤5s за transient serial
holder. Child-FD regression теперь требует реального выполнения gateway check.

Дополнительное review: persistent fence тоже публикуется целиком из fresh nonce
private staging после checked fsync. Прерванный stage остаётся без adoption/
cleanup; explicit retry создаёт свежий stage под journal flock. Fsync failure и
actual SIGKILL до fence publication покрыты отдельными regression tests.

Review/portability follow-up: native guard and private journal files are created
with explicit mode 0600 at open(2), before chmod; failure of the first chmod
must leave a private reusable empty guard. Receiver cleanup uses at most five
integer sleep(1) retries. Fractional sleep syntax is not a target prerequisite.

Owner evidence 2026-10-13: exact dc8d5a4 native module SHA256
`6aff5c92a974db85fb89ab273f76ccc69f282a3eb347bbe5053230146fa8ac0e`
(9809 bytes) matched Windows/CUDY. Nine native batch functional checks and
source/isolation passed, then harness sleep 0.1 failed. SIGKILL recovery, final
isolation and cleanup are NOT confirmed. Do not rerun the old harness or remove
`/tmp/hg-native-batch.apCLFG`/signal a PID without verified object/process identity.
`native-batch-inventory.uc` is an owner-executed bounded read-only metadata step;
it never follows symlinks, signals processes or removes locks. Its kernel-holder
PID output is observational and is not authorization to kill a process.
Production remains BLOCKED; tmpfs ARM tests are not flash/reboot migration gates.

Terminal admission hardening: receipt V2 binds phase, exact journal UUID and
persistent guard inode; V1 prototypes are refused, never automatically converted.
Guard/marker are typed/bounded/read-only checked under kernel serialization.
Telegram rc.common keeps FD8 exclusively locked from start_service through real
procd publication and service_started postcheck; PID1-spawned workers do not
inherit the guard. Failure before instance construction is reported by the hook.
Guard inode stability on real CUDY overlay across reboot is an unclosed target
gate: any changed identity must fail closed, not silently refresh the receipt.
Legacy18 boot/service guard installation still requires the full coordinator.

## Native candidate staging — продолжение 14.10.2026

`migration-candidate.uc` сохраняет отдельно pinned manifest из20 runtime и3
receiver files: exact inventory/SHA/UID/GID/mode/physical ancestors, bounded reads,
private flash copy с checked file/dir fsync, source/readback revalidation и atomic
receipt publication. Source может быть на tmpfs; cross-FS rename не используется.
Unknown extras, links, metadata/hash/pin mismatch, insufficient space, partial
fsync/SIGKILL snapshot и replay отвергаются. Snapshot verification не разрешает
apply и не публикует admission: phase остаётся PREPARING, legacy runtime неизменен.

Этот scope RUNTIME20_RECEIVER3 ещё не включает полный control package/early boot
guard/service quiescence. Это НЕ production installer и НЕ verified18→20→18
rollback. Host candidate8 regressions и dedicated networkless officialVM23
scenario используются наряду с baseline и legacy-snapshot VM; raw images,
console и snapshots не публикуются. Full coordinator остаётся critical blocker.
