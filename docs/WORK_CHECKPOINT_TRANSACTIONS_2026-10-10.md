# Контрольная точка MAIN planning — Issue #7

Принятой новой версии нет: runtime `0.5.0-dev`. Real CUDY не изменён.
Ветка `feature/0.8-main-transactions`; исходная база main
`620bfd190394ca601b4dc31b2a7cd354b3edfd77` (PR #12).
PR #13 ASATA и PR #14 Safe Actions проходят текущий review/CI; перед merge
этой ветки требуется обновление на их фактический merged main.

Реализован production read-only UCI planner в существующем vpn.sh и CLI.
Строгий named-node input, profile/port/enabled/autoswitch checks, pending-edit
refusal, bounded/time-limited reads, fixed sanitized JSON. Все mutating modes
fail closed. Отдельные наблюдения не выдаются за preflight или snapshot.
9 automated contracts PASS на actual BusyBox ash с isolated UCI process boundary.
Initial baseline: 120 PASS (46 notifications/ASATA + 23 vtest + 9 planner +
13 release + 29 deploy); merged regression/GitHub HEAD CI будут записаны отдельно.

Stage 0.8 частичный: snapshot/apply/postcheck/rollback/recovery/journal отсутствуют.
0.9 backup/restore и 1.0 target regression/soak/acceptance не завершены.
Private originals не опубликованы. Блокеры и точные действия описаны в
MAIN_TRANSACTIONS.md; исходники реальных PassWall2 helpers нужны для безопасного
candidate runner, replacement ASATA требует координации external writers.

Следующая точная команда: `git fetch origin`; обновить эту ветку на merged main
после PR #13/#14, повторить `PATH=/tmp/cudy-bin:$PATH ./scripts/ci/check.sh`,
release/deploy tests, publish PR и проверить CI HEAD. Затем получить/audit
PassWall2 helpers без секретов; реализовать private snapshot/journal и isolated
candidate preflight. Не запускать `apply` на реальном CUDY без owner approval.

11 октября: ветка объединена с main после PR #14
87cff2aa8043730f9b70836e27a01c52b9f8779b. CI/help conflicts разрешены с сохранением
MAIN planner, actions, ASATA CLI и обоих suites. ACCEPTANCE.md сохранён и уточнён.
Read-only planner остаётся partial: реального preflight/snapshot/apply/rollback
MAIN нет; planner всегда fail closed. Новые private PassWall helpers предоставлены,
но shared runtime/eval/asynchronous process ownership требуют отдельного адаптера.
CUDY/MAIN/nft/sysupgrade не изменялись. GitHub CI/review merged tree обязательны.

Фактически проверенный combined набор после merge #14: 165 PASS =
64 notifications/ASATA + 23 vtest + 9 MAIN planner + 24 actions + 13 release +
32 deploy. Full CI_RESULT=PASS; ash/ucode compile PASS. Следующее действие:
проверить новый HEAD #15 CI/review, merge без bypass, обновить #16 на свежий main.
