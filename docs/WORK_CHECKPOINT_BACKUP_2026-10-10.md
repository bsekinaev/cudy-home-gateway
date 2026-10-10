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
