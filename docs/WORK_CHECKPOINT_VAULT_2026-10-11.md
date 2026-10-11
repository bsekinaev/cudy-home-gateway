# Private backup vault — Issue #7, 11 октября 2026

Runtime 0.5.0-dev; новая принятая версия отсутствует. Реальный CUDY/MAIN/nft,
deploy/restore/sysupgrade, stable tag не изменены. Исходные приватные архивы
не копировались в GitHub; тесты используют synthetic configuration contents.

Разработан Linux host-only vault: owner-confirmed hash/exact inventory verify,
private 0700/0600 trusted paths/no chmod shared directories, kernel exclusion,
fsynced files before SQLite FULL catalog/audit commit, last-five rotation,
explicit orphan recovery; corruption pauses before deletion/rotation.
17 actual vault tests PASS (44 вместе с final verifier 27); final verifier #16 HEAD 5ccd9a55b5a042d948d98cd8b0cb8a06f0a455ca
проверяется отдельно и должен быть объединён после последнего GitHub CI/review.
Kernel SIGKILL SQL recovery подтверждён; before/after file/catalog fault boundaries
проверены на реальной FS, без production fault injection hooks.

Не завершены: collector/coherent router snapshot, external writer coordination,
full owner inventory, central audit, controlled restore/rollback и target gates.
Нельзя считать retained archive полным backup CUDY без owner inventory/coherence.
CLI не вызывает network/provider/sysupgrade и не извлекает архив.

Продолжение: дождаться merge #16, git fetch origin; merge origin/main в
feature/0.9-private-vault; повторить backup и combined suites, commit/PR/CI/review.
После этого private transactional restore plan/engine на offline filesystem,
не root extraction sysupgrade -r. Owner LIVE разрешение остаётся обязательным.

Дополнительно: missing catalog над existing archives никогда не reinitialize;
audit receipts проверяются для всех active копий, logical index deletion pauses
before GC; audit retention проверена фактическими 105 import/rotation operations.

Новый owner baseline: sysupgrade исключает /etc/home-gateway; vault это не исправляет.
P0 migration/preflight — отдельный PR18. No private archive requested/published.
