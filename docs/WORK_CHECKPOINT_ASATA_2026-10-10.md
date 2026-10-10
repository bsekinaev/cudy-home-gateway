# Контрольная точка ASATA — Issue #7

Новой принятой версии нет, `0.5.0-dev`. CUDY/MAIN не изменены, stable tag не создан.
Baseline: main `b718f950e77b1c50f29be99552b1b9836de7fc32`.
PR #12 с offline vtest adapter: commit `4c31c81598996a0e952b25e319ecac39fb26ede6`,
CI SUCCESS: https://github.com/bsekinaev/cudy-home-gateway/actions/runs/38081376088.
PR #12 merged: `620bfd190394ca601b4dc31b2a7cd354b3edfd77`. Findings исправлены
в `3032e3daabee95289f4746968d6f3fdc6d4e70ed`, CI run 38081844690 SUCCESS;
повторный review завершён без новых замечаний.

Ветка `feature/0.5-asata-keeper-hardening`: самостоятельный local opt-in keeper,
exact semantics и первое положение, bounded nft capture, missing-rule insert без captured-handle deletes,
postcheck, kernel single-flight/recovery, fixed loop без автоматического enable.
Collector и doctor больше не принимают одного наличия comment.
Новых runtime paths нет. Исходники владельца не публикуются/не исполняются.

Локальные ash/ucode/CI checks PASS; 62 notification/ASATA + 23 vtest tests PASS (85). 13 release + 29 deployment PASS (127 всего после merge свежего main). GitHub HEAD CI
проверяется после публикации.
Новые тесты выполняют production keeper с isolated nft boundary, а не на CUDY.

Не закрыты: LIVE keeper/procd/sysupgrade, exact failed redmi staging, vtest helper
source audit/cleanup ownership, 0.7 Safe Actions, 0.8 MAIN transactions,
0.9 private backup/restore, 1.0 target regression/soak/acceptance.

Точное продолжение: PR #13 обновлён на свежий main после merge #12;
проверить актуальные CI/review #13, устранить findings и merge без bypass. Затем
`git fetch origin` и ветка `feature/0.7-safe-actions` от main: durable TTL/nonce
confirmations, replay protection, per-resource locks, MAINTENANCE и fixed service
allowlist. Production execution остаётся forbidden без отдельного разрешения.

PR #13: https://github.com/bsekinaev/cudy-home-gateway/pull/13
Исходный commit: ca975c5084d9ccf4bff0449f4437404222d19e0b.

Review #13: root-owned runtime/ancestors enforced; captured-handle deletion removed
because writer coordination is unavailable; TERM escalates to KILL; doctor busy
is WARN. Added ownership/ancestor/missing-insert/no-delete/doctor contention tests,
TERM-ignoring subprocess timeout fault test. Existing malformed marked rule repair
remains blocked pending PassWall writer coordination; do not claim full acceptance.
