# Private backup vault — Issue #7, 11 октября 2026

Runtime 0.5.0-dev; новая принятая версия отсутствует. Реальный CUDY/MAIN/nft,
deploy/restore/sysupgrade, stable tag не изменены. Исходные приватные архивы
не копировались в GitHub; тесты используют synthetic configuration contents.

Разработан Linux host-only vault: owner-confirmed hash/exact inventory verify,
private 0700/0600 trusted paths/no chmod shared directories, kernel exclusion,
fsynced files before SQLite FULL catalog/audit commit, last-five rotation,
explicit orphan recovery; corruption pauses before deletion/rotation.
27 actual vault tests PASS (57 вместе с final verifier 30); final verifier #16 HEAD 5ccd9a55b5a042d948d98cd8b0cb8a06f0a455ca
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

Полная local regression после reconcile: 209 actual PASS = 164 state/CLI +
13 release + 32 deploy. PR19 retarget main для CI; merge зависит от PR16.
Latest verifier doc contract объединён; новый HEAD CI/review проверять заново.

Review P1 исправлен: consistent catalog rollback/empty index+audit никогда не
приводят к удалению unknown копий; они QUARANTINED. GC требует ROTATED receipt,
metadata и digest retirement archives, иначе pauses before deletion.
52 current backup tests PASS; старый combined209 относится к предыдущему HEAD.

Read-back new pair hash/inventory verification выполняется до catalog rotation
commit; injected archive/manifest storage faults сохраняют старые пять references
и файлы. 49 actual backup tests PASS (21 vault + 28 verifier).

12.10: latest review missing-retired-archive closed; complete-pair verification
перед удалением, orphan inventory retained. 52 backup tests PASS на host ash1.37.

Exact archive SHA+canonical inventory hash retry идемпотентен. После commit GC
errors дают STORED_CLEANUP_PENDING/ALREADY_STORED_CLEANUP_PENDING, без повторной
rotation и без ложного failed import. 27 vault / 30 verifier = 57 tests.

Review: каждый mkdir fsync parent до descent; новый distinct import блокируется
до устранения retained cleanup errors, retirement receipts не теряются на ротации.
show проверяет retired SHA и сообщает CLEANUP_PENDING/QUARANTINED; 105 blocked
imports не изменяют references/audit. 55 backup tests PASS.

Active post-commit corruption возвращает COMMITTED_INTEGRITY_ERROR (committed
true, integrity_error true, CLI failure), не cleanup-only success; старые
archive copies не удаляются. Partial cleanup retries retain cleanup_pending.
57 backup tests PASS, без router restore claim.
