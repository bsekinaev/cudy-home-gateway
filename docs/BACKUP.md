# Backup & Hardening — 0.9 work in progress

Доступна **offline-проверка приватного backup на Linux workstation с Python 3.10+**.
Это не router backup/restore engine, не автоматический collector и не подтверждение
полноты CUDY. Runtime inventory не расширен; Python на роутер не устанавливается.

```sh
python3 scripts/backup/verify.py /private/backup.tar.gz \
  --sha256 OWNER_CONFIRMED_SHA256 --inventory /private/inventory.json
```

SHA256 должен быть получен владельцем через доверенный канал при создании/передаче
backup. Самостоятельно вычисленный hash неизвестного архива не доказывает provenance.
Inventory — приватный JSON array **всех ожидаемых paths: regular files и только пять exact symlink mappings ниже**, относительно
корня, без `/`, `.` или `..` компонентов. Он задаётся владельцем по фактическому
снимку и `sysupgrade -l`, а не угадывается utility. Archive и inventory должны быть
regular, принадлежащими caller/root, без любых group/other permissions; no-follow
и nonblocking open предотвращают symlink/FIFO input. CLI печатает только fixed
reason/counts/bytes/hash, без исходных filenames, содержимого или traceback.

Проверяются SHA256 до tar parse, compressed ≤8 MiB, полный decompressed stream
(включая metadata/padding) ≤16 MiB, member ≤2 MiB, ≤1024 entries. Разрешены regular
files/directories в `etc/`, `usr/lib/home-gateway/`, persisted deployment receiver, отдельные Gateway/ASATA/vtest
entrypoints. Запрещены absolute/traversal/duplicate paths, special file types,
generic symlink/hardlink, PAX, special mode bits и второй concatenated tar после end marker.
Неизвестный/большой archive требует отдельного review формата, а не обхода лимитов.

Результат VERIFIED означает **только соответствие предоставленному inventory**:
`completeness=OWNER_INVENTORY_ONLY`, `transaction_consistent=false`,
`restore_supported=false`. Проверяемый archive не извлекается, не выполняется и не изменяется.
Указанный inventory может быть неполным; schema/snapshot consistency state и
production restore этим инструментом не доказываются.

## Согласованность и полнота будущего backup

Нужно сохранять согласованно весь `/etc/home-gateway/` (policy, secrets и state),
включая notifications.jsonl, incidents.jsonl, notification-dedup.json,
notification-compaction.json/snapshot при наличии, actions.json. Нельзя смешивать
снимки разных моментов и терять dedup receipts. Backup coordinator должен учитывать
порядок notification/incident/actions locks и external UCI/nft writers. Снимки
runtime `/tmp` после reboot не заменяют persistent state.

Full relevant inventory включает фактические UCI/config/credentials, Gateway
runtime/receiver/recovery, sysupgrade allowlist, ASATA worker/init/enable link,
vtest/provider dependencies и сохранённую конфигурацию data plane/Tailscale.
Нужно сверить его на CUDY; исходники трёх scripts не заменяют private config backup.
Archive с секретами никогда не загружается в Git, Actions artifacts, issues или
Telegram. Пять последних архивов должны храниться в private owner storage с audit,
проверкой до rotation и crash-safe metadata; этот runtime engine ещё отсутствует.

## Почему restore пока blocked

Получена private копия установленного sysupgrade 11.10.2026; её local hash и
статический аудит перечислены в PASSWALL_SOURCE_AUDIT_2026-10-11.md. Совпадение
с текущим target hash ещё ждёт владельца. Restore fallback извлекает tar в /,
а platform hooks не предоставлены: это не безопасная Gateway транзакция.
Для target restore нужны inventory/path/type validation, private pre-restore
snapshot, journal, post-check/rollback/recovery и LAN доступ.
Нельзя запускать restore/reboot/sysupgrade на CUDY без отдельного owner approval.

Этап 0.9 остаётся partial: collector, last-five rotation/audit, согласованность и
restore ещё не реализованы. 30 tests используют настоящий gzip/tar/hash/private FS
с public synthetic contents, включая corruption/bombs/links/FIFO/privacy. Они не
являются проверкой реального backup или восстановления роутера.

## Границы формата архива

Physical tar headers проверяются до tarfile: разрешены обычные regular/directory
и только exact managed init/vtest symlinks ниже. Sparse/PAX/GNU extension headers
отклоняются, включая пустые скрытые headers. Набор ожидаемых paths обязан точно
совпасть с inventory; дополнительный allowlisted файл запрещён.

### Persisted init/vtest links и raw tar validation

30 offline tests PASS, включая фактический BusyBox 1.36.1 tar -czf. Для четырёх
repository-managed enable links (S94/K09 deploy-recover, S95/K10 Telegram)
разрешён только SYMTYPE с точным relative target ../init.d/соответствующий-service,
size=0 и явным включением path в owner inventory. Замена этих paths regular file
или иная ссылка отвергаются. Пятый mapping: `usr/bin/vtest` только SYMTYPE,
size=0, target `/root/vless-auto.sh`, с явным owner inventory.
Остальные symlinks/hardlinks запрещены. Owner inventory
теперь означает exact expected paths: обычные файлы плюс только эти approved links.

Physical headers проверяются до tarfile normalization: один стандартный trailing
slash directory допустим, повторные separators/traversal — нет. Nonzero member
padding отвергается. Два нулевых end blocks обязательны после последнего member.
Это не означает принятую полноту native sysupgrade backup остальных hooks/links.

Inventory ограничен 256 KiB: этот bound вмещает 1024 paths по 240 ASCII characters
в обычном JSON encoding. Capacity test проверяет maximum-length USTAR paths и
соответствующий tar. Linkname raw field также проверяется на zero padding до
tarfile truncation; undeclared target bytes отвергаются.

Baseline владельца 11.10.2026 подтвердил vtest link `usr/bin/vtest -> /root/vless-auto.sh`.
Verifier допускает только это точное соответствие (всего пять известных mappings,
не требование иметь все пять ссылок). Имена tar members по-прежнему относительные.
Штатный backup исключает три файла `/etc/home-gateway`; отдельный private backup
проверен владельцем по SHA256, restore не проверен. Это critical release blocker.

Raw numeric fields mode/uid/gid/mtime/checksum/size/device проверяются одинаково,
NUL допускает лишь последующее zero/space padding, device values=0. uname/gname
имеют zero padding. Magic/version — canonical USTAR, GNU ordinary header without
prefix/extensions или zero V7 metadata; inconsistent representations запрещены.

Gzip parser проверяет reserved flags/FHCRC/CRC/trailer каждого member,
не только первого. ≤64 gzip members; общий decompressed bound остаётся 16 MiB.
30 tests — новые flags/second-member/member-count negative regressions.

## Private vault — отдельная host-only реализация

`scripts/backup/vault.py` хранит уже полученные private archives после полной
проверки SHA256/exact inventory. Ничего не собирает с роутера и не извлекает tar.
Linux/Python 3.10+, dedicated directory 0700, все archive/inventory/catalog/lock
files 0600, no symlinks/hardlinks/неизвестные files. Existing shared directories
не chmodded. Архивы, реальные inventory и SQLite database никогда не публикуются.

```sh
python3 scripts/backup/vault.py import --vault /private/gateway-vault \
  --archive /private/backup.tar.gz --sha256 OWNER_CONFIRMED_SHA256 \
  --inventory /private/inventory.json
python3 scripts/backup/vault.py show --vault /private/gateway-vault
python3 scripts/backup/vault.py recover --vault /private/gateway-vault
```

Kernel lock исключает concurrent vault writers. Files fsynced до commit каталога;
SQLite FULL/DELETE transaction атомарно сохраняет import, active last-five index
и audit retirement. До commit старые references сохраняются; после commit старые
files удаляются только когда новые и оставшиеся active copies проверены. Crash
может оставить private unreferenced files: `recover` проверяет active index и
удаляет только свои файлы с retained ROTATED receipt и проверенным archive SHA256.
Unknown unreferenced pairs сохраняются, даже если copies/audit исчезли вместе;
show/recover сообщают QUARANTINED и unreferenced_preserved.
SQLite hot journal восстанавливается при explicit writable open/recover.
Read-only show не выполняет GC. Corrupt active archive/inventory/catalog blocks
import/rotation/GC; generic stdout не раскрывает private paths/contents.

Audit: до 200 committed import/retirement events. Это bounded private catalog log,
не central Gateway audit и не доказательство незавершённого import. Orphan copies
до SQLite commit не становятся accepted backup; recovery не заявляет успешный
router restore. Последние пять references сохраняются, orphan files после crash
могут временно увеличивать disk count до recovery. Catalog не доказывает coherent
snapshot источника: transaction_consistent=false, restore_supported=false.

23 isolated vault tests PASS + verifier tests: actual files/SQLite, 7-copy rotation,
crash before/after catalog commit, actual SIGKILL SQL transaction, corruption,
private permissions, cross-process kernel lock, path injection и bounded audit.
Это доступная часть 0.9; collector/coordinated snapshot/target restore still BLOCKED.

Read-back new pair hash/inventory verification выполняется до catalog rotation
commit; injected archive/manifest storage faults сохраняют старые пять references
и файлы. 53 actual backup tests PASS (23 vault + 30 verifier).

Retirement GC разрешён лишь для complete archive+inventory pair после SHA проверки
архива; incomplete пары сохраняются QUARANTINED. Manifest удаляется раньше
archive: crash оставляет сохранённый архив, не metadata без проверенного archive.

Exact archive SHA+canonical inventory hash retry идемпотентен. После commit GC
errors дают STORED_CLEANUP_PENDING/ALREADY_STORED_CLEANUP_PENDING, без повторной
rotation и без ложного failed import. 23 vault / 30 verifier = 53 tests.
