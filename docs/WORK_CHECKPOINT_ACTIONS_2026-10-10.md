# Контрольная точка 0.7 — Issue #7

Новой принятой версии нет: runtime остаётся `0.5.0-dev`. Production CUDY/MAIN,
reboot/sysupgrade и stable tag не изменялись.

PR #12 merged: `620bfd190394ca601b4dc31b2a7cd354b3edfd77`.
Offline vtest parser/history/privacy, 3 review fixes; CI run 38081844690 SUCCESS.
PR #13 ASATA merged: `136ba4e4db65dab817bd6a1eacb42a92d9d2eca3`.
https://github.com/bsekinaev/cudy-home-gateway/pull/13; HEAD a04514a264edeb24d4b1db811175d19655922b37,
CI 38083925353 SUCCESS и review completed без новых findings.
Единый lstat-backed uid/type/mode, trusted parent до create, kernel locks,
KILL escalation, busy doctor WARN. Все nft mutations fail closed до writer
coordination, включая missing insert; полный repair/LIVE не принят.

Ветка `feature/0.7-safe-actions`: allowlist restart Tailscale/uhttpd, disabled by
policy; UUID token TTL120, user/chat/message/boot binding, cancel, durable EXECUTING,
CLOEXEC/kernel/per-service locks, UNKNOWN recovery без retry, bounded audit,
Tailscale-only MAINTENANCE, Telegram /actions с prepare/confirm/result UI.
Production init вызывается с его rc.common shebang. Никаких произвольных commands.

20 Safe Actions tests PASS, включая production CLI/ucode/poller с isolated service
и Telegram boundaries, настоящий SIGKILL после durable consume, replay/TTL/identity,
corruption, OS locks, health projection, rc.common invocation. На baseline #12:
46 notifications/ASATA + 23 vtest + 20 actions + 13 release + 30 deployment = 132.
После объединения ASATA ожидаемый набор 149 (63 + 23 + 20 + 13 + 30);
считать только фактически проверенный merged tree/HEAD CI. Shell syntax и target ucode compile PASS.

Runtime inventory расширен actions.uc до 20 файлов; wire HGDEPLOY2. Legacy wire
rejected before apply; safe_live требует existing regular new module. Receiver
bootstrap на CUDY не выполнялся. Owner migration/LIVE-план: SAFE_ACTIONS.md.

Не завершены: LIVE 0.5/0.7, vtest safe process ownership/helpers/progress/alerts,
exact redmi failed staging. 0.8 MAIN transactions, 0.9 backup/restore,
1.0 target regression/soak и all-critical acceptance не реализованы/не приняты.

PR #14: https://github.com/bsekinaev/cudy-home-gateway/pull/14; initial HEAD
c18384b4a5f8f67e6fb93de529b366aea2a2be65, CI 38083489420 SUCCESS, review no findings.
Теперь требуется CI/review объединённого дерева. PR #15 read-only planner MAIN
уже открыт, но stage 0.8 остаётся partial (snapshot/apply/recovery отсутствуют).

Точное продолжение: проверить актуальные HEAD/CI/review PR #14,
исправить findings, merge без bypass, записать ссылки на фактические merge/CI.
Затем `git fetch origin` и обновить существующую `feature/0.8-main-transactions`
на merged main:
начать с UCI inventory/dry-run/snapshot/journal/crash recovery; preflight новой
ноды требует проверенного temporary-SOCKS provider/PassWall helpers. Не реализовывать
ложный successful preflight заглушкой и не выполнять MAIN apply на CUDY.

## Восстановление и review fixes — 11 октября 2026

После потери временных worktrees восстановлены 4 исправления #14: durable UNKNOWN
resource quarantine + только local authorised acknowledge; latest-only maintenance;
отказ от chmod shared leaf в actions/ASATA; inventory-version и exact manifests
до любых recovery/rollback phase/pointer/service mutations. Parent validation до
mkdir; UNKNOWN records сохраняются при retention. Legacy journal требует matching
старого receiver по LAN до bootstrap, не auto conversion.

Актуальная local regression восстановленного дерева: 156 PASS = 64 notification/
ASATA + 23 vtest + 24 actions + 13 release + 32 deploy. BusyBox 1.36.1 ash,
закреплённый ucode 85922056ef7abeace3cca3ab28bc1ac2d88e31b1, full CI checks PASS.
Доказаны actual SIGKILL/orphan fence, terminal replay, failure после DONE,
shared directory mode unchanged, legacy/missing inventory без остановки service.
До merge необходимы GitHub CI/review нового опубликованного HEAD.
CUDY/MAIN/nft/sysupgrade не изменялись; полной target приёмки нет.
