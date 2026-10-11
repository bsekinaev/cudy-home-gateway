# Контрольная точка Issue #7 — 11 октября 2026

Принятая новая версия отсутствует: runtime 0.5.0-dev. CUDY/MAIN/nft/sysupgrade,
production deploy и v1.0.0 tag не изменены.

PR #14 merged 87cff2aa8043730f9b70836e27a01c52b9f8779b:
https://github.com/bsekinaev/cudy-home-gateway/pull/14
HEAD 2d45916, CI 38133278411 SUCCESS, repeat review без новых findings.
156 actual local tests PASS. Resource quarantine/latest maintenance/shared paths/
legacy journals исправлены. Target opt-in/bootstrap/LIVE ждут владельца.

PR #15 merged 8a8a37de5443bee5ee988a3b0623bb3589a8a07d:
https://github.com/bsekinaev/cudy-home-gateway/pull/15
HEAD c54fd4b, CI 38133879687 SUCCESS, review без findings.
165 actual combined tests PASS. Read-only planner/ACCEPTANCE.md; полноценные
MAIN snapshot/preflight/apply/postcheck/rollback/reboot recovery не реализованы.

PR #16 fresh merged-main HEAD 58b90e875e40ce3d4d5e0e7f6fdfbbd15f686962:
https://github.com/bsekinaev/cudy-home-gateway/pull/16
Все 6 findings исправлены, 17 backup tests/182 combined PASS; GitHub CI/review
этого HEAD требуется проверить перед merge. Host-only verifier — partial 0.9.

Новый ownership primitive: фиксированный Xray/config fd, seccomp no new processes
с native threads; trusted paths, no inherited FD, PDEATHSIG, exact unreaped child
signals, timeout/cancel, global lock/crash fence/run consumption. 18 native tests
PASS (actual C/ELF/processes), включая alternate syscall ABI. Default disabled,
не установлен и не включён в release inventory. Provider run всё ещё blocked.
Фактическая полная CI проверка baseline #15 с primitive: 133 state/CLI/native
contracts, плюс release/deploy checks; это не target acceptance. Private originals
не попали в GitHub; 15 manifest SHA и 4 новых hashes/7 ash syntaxes проверены.

Продолжение: проверить #16 CI/review и merge; git fetch origin; объединить свежий
main в feature/0.6-provider-ownership, сохранить все suites, повторить CI/review.
Затем закончить audited config generator/pinned native cross-build/curl budgets,
worker progress/results/notifications, offline backup vault/restore и writer
coordination. Owner LIVE gates перечислены в ACCEPTANCE.md; stable tag запрещён.

## Дополнение после review

Исправлены четыре findings: bounded post-KILL wait с сохранением fence,
prelaunch cancel/exec-grant handshake, inherited SIGCHLD=IGNORE и signal mask.
18 actual native tests PASS; production runner не активирован.
Новый baseline владельца 11.10: HGDEPLOY1, 18 файлов, COMMITTED, active ABSENT;
HGDEPLOY2/actions/notifications ABSENT. Миграция P0 — отдельная ветка.
Штатный backup исключает /etc/home-gateway: critical blocker.
PR16 исправлен до 23 backup tests, текущий HEAD 1a3a835; CI/review проверять заново.
