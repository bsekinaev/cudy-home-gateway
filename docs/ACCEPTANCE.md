# Приёмка v1.0.0 — открыта

Runtime остаётся `0.5.0-dev`. Эта таблица фиксирует инженерные доказательства,
а не заменяет проверку нового HEAD и приёмку владельцем. **v1.0.0 не готов.**
PASS ниже относится только к указанному automated/isolated scope. BLOCKED означает,
что требуемый production контракт или LIVE evidence ещё отсутствует. Старые
11 OK / 58 PASS на CUDY не подтверждают работоспособность нового кода.

| Критерий | Automated scope | Полная приёмка / что осталось |
|---|---|---|
| 0.5 dispatcher, receipts, retry/429, MAIN → Torrent, privacy | PASS: notification contracts в CI | BLOCKED: реальная Telegram доставка, SOCKS, procd/reboot |
| 0.5 compaction/dedup crash recovery | PASS: fault-injection/redo/locks | BLOCKED: persistent flash/reboot подтверждение |
| 0.5 ASATA полная семантика/order | PASS: [PR #13](https://github.com/bsekinaev/cudy-home-gateway/pull/13), CI 38083925353 | BLOCKED: target nft compatibility; любой repair требует координации writers |
| 0.5 sysupgrade persistence | PASS: allowlist generation contracts | BLOCKED: actual inventory/restore после owner-approved sysupgrade |
| Ошибка target staging redmi.sh | BLOCKED | Нужны exact failed release artifact и staging bytes, не installed old script |
| 0.6 last/history/private aggregates/Telegram read-only | PASS: [PR #12](https://github.com/bsekinaev/cudy-home-gateway/pull/12), CI 38081844690 | BLOCKED: target fingerprint/result observations |
| 0.6 quick/full/capability/progress/result alerts | BLOCKED | Audit реальных PassWall helpers; owned process cleanup/locks и bounded runner |
| 0.7 allowlist/TTL/identity/replay/audit/locks | PASS: 24 actual-engine/service-boundary tests, [PR #14](https://github.com/bsekinaev/cudy-home-gateway/pull/14) | BLOCKED: target rc.common/procd/service behavior, owner opt-in |
| 0.7 crash outcome и MAINTENANCE | PASS: actual SIGKILL/OS flock/health projection | BLOCKED: target persistence/reboot; UNKNOWN никогда не auto-retry |
| 0.8 read-only configuration planner | PASS: 9 BusyBox ash contracts, [PR #15](https://github.com/bsekinaev/cudy-home-gateway/pull/15), initial CI 38084049196 | Observation only, всегда preflight/apply blocked |
| 0.8 preflight/snapshot/apply/postcheck/rollback/recovery | BLOCKED | Реальные audited adapters, writer coordination, LAN/Tailscale recovery, durable journal |
| 0.9 full private backups/SHA256/last-five/restore/audit | Partial: offline verifier в PR #16 (17 tests), engine BLOCKED | Runtime backup engine и isolated restore/fault tests ещё не реализованы |
| Control-plane release/deploy integrity/recovery | PASS: release/deploy tests | BLOCKED: HGDEPLOY2 receiver/module bootstrap + target smoke/rollback |
| 1.0 full target negative/reboot/crash regression | BLOCKED | Только отдельное разрешение/изолированный стенд; production destructive tests запрещены |
| 1.0 длительный soak без functional changes | BLOCKED | Согласовать duration/metrics/start/end; реального soak не было |
| 1.0 documentation/release notes/stable version/tag | BLOCKED | Final behavior/limits после всех critical PASS; tag только после приёмки |

## Необходимые доказательства от владельца

* Приватно сравнить SHA256 exact failed artifact `redmi.sh` и failed staging bytes;
  не присылать credentials или полный private UCI. Зафиксировать только sanitized
  hashes, byte/syntax comparison и проверенную причину.
* Предоставить обезличенные helper sources/version для `utils.sh` и `app.sh`
  PassWall2. Передавать их как private input, не в публичный issue или CI.
* Согласовать окно и отдельные операции на CUDY. Сначала LAN access, приватный
  backup и tested rollback; не включать delivery/actions/keeper автоматически.
* Проверить actual `sysupgrade -l` inventory приватно: список может содержать
  секретные пути. Backup archive нельзя прикладывать к GitHub/CI/Telegram.
* После isolated tests провести контролируемые target smoke и safe observation.
  Не моделировать Telegram disconnect, nft/UCI corruption или убийство data plane
  на production. Результат каждой операции записывать с HEAD и timestamp.

Изменение MAIN, restore конфигурации, reboot и sysupgrade требуют отдельного
разрешения владельца. Ни одна строка BLOCKED не может быть закрыта предположением,
старым target selftest или успешным host mock test.

## Baseline владельца 11.10.2026 и новый P0

| Критерий | Offline | CUDY / блокер |
|---|---|---|
| HGDEPLOY1 18 → HGDEPLOY2 20 | 24 migration rehearsal tests, read-only BusyBox preflight | BLOCKED: production coordinator, exact receiver identity, target procd/boot |
| /etc/home-gateway sysupgrade inclusion | Новый bootstrap содержит allowlist path; existing persistence contracts | FAIL в owner backup: отсутствуют 3 HG files; исправление/restore не применены |
| Резервный LAN-доступ | Не проверяется host CI | BLOCKED: Wi-Fi SSH подтверждён, кабельный резерв не проверен |

Подробный план установки/rollback: [DEPLOY_MIGRATION.md](DEPLOY_MIGRATION.md).
Штатный backup 137 entries / 133 files / 4 links и отдельный HG backup
проверены владельцем по чтению/SHA, не по restore. Private archives не публиковать.

Review fixes: own stale temporaries проверяются по exact snapshot prefix, metadata
и reserved names, только под migration/deploy fence; symlink/unrelated data
не удаляются. Actual SIGKILL до rename + relative-root refusal regressions.

Review: reset-preparation валидирует partial private tree и текущий legacy,
сохраняет flock inode/RESETTING phase до окончания очистки. Fence снимается
атомарным rename intact directory в receipt-owned sibling, cleanup повторяемый.
Interrupted prepare/reset/fence teardown negative tests; target migration BLOCKED.
