# P0 migration checkpoint — 11.10.2026

Проверены GitHub: #14/#15 merged; main 8a8a37de5443bee5ee988a3b0623bb3589a8a07d.
#16 open, #17 draft. Owner baseline учтён в DEPLOY_MIGRATION.md. Никаких операций
на CUDY/MAIN/nft/UCI/сервисах/reboot/sysupgrade/restore не выполнено.

Реализованы read-only BusyBox preflight и host-only durable migration rehearsal:
exact 18 legacy → 20 runtime + receiver, сохранён исходный legacy rollback,
новый журнал/fence, interrupted recovery, идемпотентность и drift refusal.
28 actual migration tests PASS. Runtime version остаётся 0.5.0-dev, production
migration BLOCKED до coordinator и disposable OpenWrt/procd/boot acceptance.
Missing /etc/home-gateway sysupgrade inclusion остаётся target blocker; новый
bootstrap allowlist исправлен, существующий CUDY не перебутстрапливать.

Следующее действие: проверить CI/review этого PR; исправить findings; port
production migration coordinator, сохранив exact legacy bytes/pointers и disabled
CD/boot admission. Перед merge повторно сверить main/PR16, объединить свежий main,
повторить ash/pinned ucode/release/deploy/migration suites. Сначала завершить PR16.

Review fixes: own stale temporaries проверяются по exact snapshot prefix, metadata
и reserved names, только под migration/deploy fence; symlink/unrelated data
не удаляются. Actual SIGKILL до rename + relative-root refusal regressions.

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

12.10: owner engine digest MATCH опубликован в dfd7d33; production gate не снят.
34 migration tests PASS: private staged temporaries вместо shared pathname,
foreign empty/prefix refusal, phase-specific rollback ownership, canonical latest,
bound full legacy journal и GID. Private staging same-filesystem rename проверяется
на host; production coordinator/procd/boot и mount layout остаются BLOCKED.
