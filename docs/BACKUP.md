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
Inventory — приватный JSON array **всех ожидаемых regular file paths**, относительно
корня, без `/`, `.` или `..` компонентов. Он задаётся владельцем по фактическому
снимку и `sysupgrade -l`, а не угадывается utility. Archive и inventory должны быть
regular, принадлежащими caller/root, без любых group/other permissions; no-follow
и nonblocking open предотвращают symlink/FIFO input. CLI печатает только fixed
reason/counts/bytes/hash, без исходных filenames, содержимого или traceback.

Проверяются SHA256 до tar parse, compressed ≤8 MiB, полный decompressed stream
(включая metadata/padding) ≤16 MiB, member ≤2 MiB, ≤1024 entries. Разрешены regular
files/directories в `etc/`, `usr/lib/home-gateway/`, отдельные Gateway/ASATA/vtest
entrypoints. Запрещены absolute/traversal/duplicate paths, special file types,
symlink/hardlink, PAX, special mode bits и второй concatenated tar после end marker.
Неизвестный/большой archive требует отдельного review формата, а не обхода лимитов.

Результат VERIFIED означает **только соответствие предоставленному inventory**:
`completeness=OWNER_INVENTORY_ONLY`, `transaction_consistent=false`,
`restore_supported=false`. Ничего не извлекается, не выполняется и не изменяется.
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

Изучен upstream [OpenWrt sysupgrade](https://github.com/openwrt/openwrt/blob/main/package/base-files/files/sbin/sysupgrade)
10.10.2026. Это **не исходник установленной версии CUDY**. В upstream backup `-b`
собирает tar/gzip по conffiles/hooks, restore `-r` вызывает platform hook либо
`tar -C / -x...`. Нельзя считать прямое root extraction безопасной транзакцией.
Для target restore нужны audited installed helpers, inventory/path/type validation,
private pre-restore backup, journal, post-check/rollback/recovery и LAN доступ.
Нельзя запускать restore/reboot/sysupgrade на CUDY без отдельного owner approval.

Этап 0.9 остаётся partial: collector, last-five rotation/audit, согласованность и
restore ещё не реализованы. 12 tests используют настоящий gzip/tar/hash/private FS
с public synthetic contents, включая corruption/bombs/links/FIFO/privacy. Они не
являются проверкой реального backup или восстановления роутера.

## Исправления review 11 октября 2026

Physical tar headers проверяются до tarfile: разрешены только обычные regular
и directory typeflags, sparse/PAX/GNU extension headers отклоняются, включая
пустые скрытые headers. Два нулевых end blocks обязательны именно после
последнего member; нулевое содержимое файла не заменяет end marker. Набор
regular paths должен точно совпадать с приватным owner inventory, без дополнительных
allowlisted файлов. 15 offline negative/positive tests PASS. LIVE не выполнено.

### Persisted init links и raw tar validation

21 offline tests PASS, включая фактический BusyBox 1.36.1 tar -czf. Для четырёх
repository-managed enable links (S94/K09 deploy-recover, S95/K10 Telegram)
разрешён только SYMTYPE с точным relative target ../init.d/соответствующий-service,
size=0 и явным включением path в owner inventory. Замена этих paths regular file
или иная ссылка отвергаются. Остальные symlinks/hardlinks запрещены. Owner inventory
теперь означает exact expected paths: обычные файлы плюс только эти approved links.

Physical headers проверяются до tarfile normalization: один стандартный trailing
slash directory допустим, повторные separators/traversal — нет. Nonzero member
padding отвергается. Два нулевых end blocks обязательны после последнего member.
Это не означает принятую полноту native sysupgrade backup остальных hooks/links.
