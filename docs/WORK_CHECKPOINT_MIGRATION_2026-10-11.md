# P0 migration checkpoint — 11.10.2026

Проверены GitHub: #14/#15 merged; main 8a8a37de5443bee5ee988a3b0623bb3589a8a07d.
#16 open, #17 draft. Owner baseline учтён в DEPLOY_MIGRATION.md. Никаких операций
на CUDY/MAIN/nft/UCI/сервисах/reboot/sysupgrade/restore не выполнено.

Реализованы read-only BusyBox preflight и host-only durable migration rehearsal:
exact 18 legacy → 20 runtime + receiver, сохранён исходный legacy rollback,
новый журнал/fence, interrupted recovery, идемпотентность и drift refusal.
17 actual migration tests PASS. Runtime version остаётся 0.5.0-dev, production
migration BLOCKED до coordinator и disposable OpenWrt/procd/boot acceptance.
Missing /etc/home-gateway sysupgrade inclusion остаётся target blocker; новый
bootstrap allowlist исправлен, существующий CUDY не перебутстрапливать.

Следующее действие: проверить CI/review этого PR; исправить findings; port
production migration coordinator, сохранив exact legacy bytes/pointers и disabled
CD/boot admission. Перед merge повторно сверить main/PR16, объединить свежий main,
повторить ash/pinned ucode/release/deploy/migration suites. Сначала завершить PR16.
