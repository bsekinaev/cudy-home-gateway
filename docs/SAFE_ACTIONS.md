# Safe Actions — разработка 0.7

Разработано и проверяется автоматически; **LIVE не принято**. CUDY не изменён.
Выполнение по умолчанию отключено. Allowlist: только `restart-tailscale` и
`restart-uhttpd`. Tailscale restart прерывает remote access: нужен резервный LAN.
Нет network/firewall/DNS/PassWall2 restart, MAIN switch или пользовательских commands.
Restart самого Telegram worker не добавлен: безопасная отмена собственного procd
процесса требует отдельного detached executor и recovery, которые не проверены.

```sh
gateway actions show
gateway actions prepare restart-tailscale USER CHAT MESSAGE
gateway actions confirm TOKEN USER CHAT MESSAGE
gateway actions cancel USER CHAT
```

Последние три требуют текущую user/chat whitelist из private Telegram files.
Prepare не выполняет действие. Kernel UUID без fallback даёт nonce 128 bit,
TTL 120 секунд. Токен привязан к action, user, chat, message ID и boot ID.
Reboot, обратный clock jump, TTL expiry, другой identity/message — отказ.
Новая подготовка того же action отменяет предыдущую. Cancel переводит pending
в CANCELLED. Отсутствующий/удалённый terminal token никогда не запускается заново.

Confirm под kernel flock и per-service lock durably сохраняет EXECUTING до exec.
Lock fd CLOEXEC: init subprocess не сохраняет lock при гибели engine. Crash после
EXECUTING даёт UNKNOWN при следующем locked recovery, без автоматического retry.
Невозможно гарантировать exactly-once завершение внешнего restart после crash;
UNKNOWN требует проверки оператора. DONE/FAILED/UNKNOWN являются terminal.
Init вызывается как executable, включая shebang `/bin/sh /etc/rc.common`, затем
проверяется service status. Restart timeout 30 секунд, status 10, kill-after 2;
тайм-аут/принудительное завершение трактуется как UNKNOWN. Output init не логируется.

State/audit — `/etc/home-gateway/state/actions.json`, atomic rename + sync,
0600, max 128 records/128 KiB. Retention: до 100 terminal и 20 pending плюс новая
запись; pending не удаляются из-за размера, при лимите backpressure. Audit хранит
фазы и времена вместе с receipts; stdout show скрывает token/user/chat/message.
Это bounded audit, не внешняя система хранения долгосрочных доказательств.
Corrupt/oversized/symlink/writable state, invalid phase или invalid service — pause.
Root/runtime/state ownership и trusted ancestors проверяются; chmod не заменяет
проверку владельца. Trusted local overrides нужны для изолированных roots и не
поступают из Telegram. На production вызывающий root требует root-owned paths.

MAINTENANCE ограничен текущим boot и максимумом 120 секунд от старта. Для Tailscale
он влияет только на tailscale health, не WAN/DNS/MAIN. После успеха — до 30 секунд
settling в рамках этого максимума; failure/UNKNOWN не скрывают health indefinitely.
Incident Engine уже игнорирует MAINTENANCE при open/recover debounce.

## Telegram и включение владельцем

`/actions` и dashboard button открывают меню. При disabled нет prepare buttons.
Menu callback проверяет identity, message, nonce, timestamp/TTL; confirm проверяет
durable token binding engine. `/start`, `/status`, `/vtest`, `/actions` отменяют
предыдущие pending запросы. Результат fixed text, без stdout/paths/credentials.
В рамках whitelist Telegram вызывает только именованные prepare/confirm/cancel.

Owner opt-in: private regular `/etc/home-gateway/actions.enabled` с `1` либо trusted
local `HG_ACTION_EXECUTION_ENABLED=1`. Создание policy на CUDY — отдельное разрешение,
в этой работе не выполнено. Тесты используют isolated init/Telegram/hash boundaries;
production вызывает реальные init scripts, а не тестовые handlers.

## Deployment migration — требует владельца

Добавлен `actions.uc`: trusted inventory теперь 20 runtime files. Клиент и receiver
используют **HGDEPLOY2**. Предыдущий протокол rejected до apply. Старый receiver
не совместим с новым клиентом; нельзя автоматически менять receiver на production.
`safe_live` требует существующий regular `actions.uc`, не создаёт его скрытно.

Для первого обновления владелец должен отдельно одобрить bootstrap:
проверить manifest SHA256/mode для нового module, подготовить новый trusted receiver
и rollback старого receiver/inventory, установить новый module в LAN maintenance
окно, затем выполнить plan до apply. Policy оставить disabled. Никто не запускал
production workflow/SSH/receiver update в этой работе. Проверки receiver migration,
init/procd, Tailscale/LAN recovery и sysupgrade/reboot остаются LIVE BLOCKED.
