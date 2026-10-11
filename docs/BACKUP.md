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
Inventory — приватный JSON array **всех ожидаемых paths: regular files и только четыре approved init links ниже**, относительно
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
restore ещё не реализованы. 27 tests используют настоящий gzip/tar/hash/private FS
с public synthetic contents, включая corruption/bombs/links/FIFO/privacy. Они не
являются проверкой реального backup или восстановления роутера.

## Границы формата архива

Physical tar headers проверяются до tarfile: разрешены обычные regular/directory
и только exact managed init symlinks ниже. Sparse/PAX/GNU extension headers
отклоняются, включая пустые скрытые headers. Набор ожидаемых paths обязан точно
совпасть с inventory; дополнительный allowlisted файл запрещён.

### Persisted init links и raw tar validation

23 offline tests PASS, включая фактический BusyBox 1.36.1 tar -czf. Для четырёх
repository-managed enable links (S94/K09 deploy-recover, S95/K10 Telegram)
разрешён только SYMTYPE с точным relative target ../init.d/соответствующий-service,
size=0 и явным включением path в owner inventory. Замена этих paths regular file
или иная ссылка отвергаются. Остальные symlinks/hardlinks запрещены. Owner inventory
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
