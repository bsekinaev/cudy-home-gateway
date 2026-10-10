# Контрольная точка 0.7 — Issue #7

Новой принятой версии нет: runtime остаётся `0.5.0-dev`. Production CUDY/MAIN,
reboot/sysupgrade и stable tag не изменялись.

PR #12 merged: `620bfd190394ca601b4dc31b2a7cd354b3edfd77`.
Offline vtest parser/history/privacy, 3 review fixes; CI run 38081844690 SUCCESS.
PR #13 ASATA: https://github.com/bsekinaev/cudy-home-gateway/pull/13.
Review fixes: root ownership/trusted ancestors, запрет stale-handle delete,
missing-only insert, KILL escalation, busy doctor WARN; existing marked repair
blocked до writer coordination. HEAD/CI/review проверяются перед merge.

Ветка `feature/0.7-safe-actions`: allowlist restart Tailscale/uhttpd, disabled by
policy; UUID token TTL120, user/chat/message/boot binding, cancel, durable EXECUTING,
CLOEXEC/kernel/per-service locks, UNKNOWN recovery без retry, bounded audit,
Tailscale-only MAINTENANCE, Telegram /actions с prepare/confirm/result UI.
Production init вызывается с его rc.common shebang. Никаких произвольных commands.

20 Safe Actions tests PASS, включая production CLI/ucode/poller с isolated service
и Telegram boundaries, настоящий SIGKILL после durable consume, replay/TTL/identity,
corruption, OS locks, health projection, rc.common invocation. На baseline #12:
46 notifications/ASATA + 23 vtest + 20 actions + 13 release + 30 deployment = 132.
После объединения ASATA ожидаемый набор 148; считать только фактически проверенный
merged tree/HEAD CI. Shell syntax и target ucode compile PASS.

Runtime inventory расширен actions.uc до 20 файлов; wire HGDEPLOY2. Legacy wire
rejected before apply; safe_live требует existing regular new module. Receiver
bootstrap на CUDY не выполнялся. Owner migration/LIVE-план: SAFE_ACTIONS.md.

Не завершены: LIVE 0.5/0.7, vtest safe process ownership/helpers/progress/alerts,
exact redmi failed staging. 0.8 MAIN transactions, 0.9 backup/restore,
1.0 target regression/soak и all-critical acceptance не реализованы/не приняты.

Точное продолжение: проверить актуальные HEAD/CI/review #13 и PR ветки 0.7,
исправить findings, merge без bypass, записать ссылки на фактические merge/CI.
Затем `git fetch origin` и `git switch -c feature/0.8-main-transactions origin/main`:
начать с UCI inventory/dry-run/snapshot/journal/crash recovery; preflight новой
ноды требует проверенного temporary-SOCKS provider/PassWall helpers. Не реализовывать
ложный successful preflight заглушкой и не выполнять MAIN apply на CUDY.
