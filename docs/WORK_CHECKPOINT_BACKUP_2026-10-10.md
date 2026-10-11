# Контрольная точка backup verification — Issue #7

Runtime 0.5.0-dev; CUDY не изменён, v1.0.0 не создан/не принят.
Ветка feature/0.9-backup-verification от main 136ba4e4db65dab817bd6a1eacb42a92d9d2eca3
(merged PR #13). PR #14 Safe Actions и PR #15 MAIN planner ожидают final merged cycle.

Реализован host-only production verifier private tar.gz: SHA256, owner inventory,
no-follow/nonblocking private inputs, compressed/decompressed/member/entry limits,
traversal/duplicate/link/special/PAX/trailing tar отказ, sanitized fixed output.
Никакого извлечения, SSH, backup collector или target restore. VERIFIED не означает
full/transaction-consistent CUDY backup; эти flags явно false.
12 tests PASS, настоящие gzip/tar/hash/filesystem, никаких private originals.
Full CI checks и GitHub HEAD CI записываются после публикации/fresh main.

Изучен upstream OpenWrt sysupgrade, но installed target version ещё не получена.
Прямой sysupgrade restore не подменяет transactional recovery. Stage 0.9 collector,
last-five rotation/audit/restore остаются незавершёнными; подробности BACKUP.md.
Все LIVE/reboot/sysupgrade/soak по-прежнему требуют отдельного разрешения владельца.

Следующее действие: завершить CI/review/merge #14 и #15, обновить эту ветку на fresh
main, combined regression, publish PR и GitHub CI/review. Затем implement private
backup coordinator с notification/incident/actions locks, actual inventory/space
limits, immutable archives, проверкой перед last-five rotation, journal/recovery
и isolated restore tests. Получить audited target helper versions без secrets.

11 октября: после повторного review добавлены sanitized ValueError/RecursionError
для corrupt JSON inventory и persisted deployment runtime paths (CI smoke/receiver).
Каталоги-предки private inventory допустимы, без ослабления exact regular-file set.
17 actual offline tests PASS, включая malformed 5000-digit/deep JSON CLI и реальный
формат persisted Gateway inventory. Последний published HEAD перед этими fixes:
65f81791df15d6cde5d0205f629ae41f056aaa3c. Stage 0.9/LIVE не принят.

Обновлено на main после #15: 8a8a37de5443bee5ee988a3b0623bb3589a8a07d.
CI conflict разрешён с сохранением backup, planner и actions suites. README ссылается
на BACKUP.md и ACCEPTANCE.md. Фактические проверки merged tree: 182 PASS =
64 notifications/ASATA +23 vtest +17 backup +9 planner +24 actions +13 release +
32 deploy; full CI_RESULT=PASS, BusyBox 1.36.1 ash/pinned ucode syntax PASS.
Перед merge нужны новый HEAD CI/review. CUDY/MAIN/restore не изменены.
Точное продолжение: проверить GitHub CI/review #16, закрыть исправленные 6 findings,
merge без bypass; затем native ownership PR и remaining backup/transaction adapters.

Повторный review merged HEAD нашёл 3 дополнительные границы: exact managed init
symlinks, nonzero member padding и raw directory separators до normalization.
Исправлено: 21 actual backup tests PASS, включая actual BusyBox tar. Generic links
по-прежнему запрещены; target inventory/hooks/LIVE не приняты. Новый CI/review HEAD
требуется проверить перед merge. Full stage 0.9 completion не заявляется.
