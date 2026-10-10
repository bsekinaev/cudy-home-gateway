# Контрольная точка ASATA — Issue #7

Новой принятой версии нет, `0.5.0-dev`. CUDY/MAIN не изменены, stable tag не создан.
Baseline: main `b718f950e77b1c50f29be99552b1b9836de7fc32`.
PR #12 с offline vtest adapter: commit `4c31c81598996a0e952b25e319ecac39fb26ede6`,
CI SUCCESS: https://github.com/bsekinaev/cudy-home-gateway/actions/runs/38081376088.
Его review ожидается; merge требует завершённой проверки актуального HEAD.

Ветка `feature/0.5-asata-keeper-hardening`: самостоятельный local opt-in keeper,
exact semantics и первое положение, bounded nft capture, atomic batch,
postcheck, kernel single-flight/recovery, fixed loop без автоматического enable.
Collector и doctor больше не принимают одного наличия comment.
Новых runtime paths нет. Исходники владельца не публикуются/не исполняются.

Локальные ash/ucode/CI checks PASS; 58 notification/ASATA + 14 baseline vtest tests
PASS (72). 13 release + 29 deployment PASS (114 всего на baseline). GitHub HEAD CI
проверяется после публикации.
Новые тесты выполняют production keeper с isolated nft boundary, а не на CUDY.

Не закрыты: LIVE keeper/procd/sysupgrade, exact failed redmi staging, vtest helper
source audit/cleanup ownership, 0.7 Safe Actions, 0.8 MAIN transactions,
0.9 private backup/restore, 1.0 target regression/soak/acceptance.

Точное продолжение: завершить review/merge #12, rebase ASATA на свежий main,
проверить все tests, опубликовать отдельный PR и дождаться CI/review. Затем
`git fetch origin` и ветка `feature/0.7-safe-actions` от main: durable TTL/nonce
confirmations, replay protection, per-resource locks, MAINTENANCE и fixed service
allowlist. Production execution остаётся forbidden без отдельного разрешения.
