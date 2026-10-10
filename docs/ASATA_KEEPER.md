# Независимый ASATA keeper

Разработано для 0.5; **на CUDY не установлено и LIVE не принято**.
Это самостоятельная реализация в `asata.sh`, оригинал владельца не публикуется.
Runtime inventory не расширяется; обычный deploy Gateway не запускает keeper.

```sh
gateway asata-keeper check
```

Read-only nft check проверяет единственное правило `ASATA-UDP-DIRECT` первым в
`inet passwall2 PSW2_MANGLE`: ровно source `192.168.1.140`, `meta l4proto udp`,
`counter`, `return`, comment; никаких дополнительных условий/verdict/mark.
Имена таблицы/цепочки и адрес фиксированы, аргументы пользователя не становятся
nft expressions. Доктор использует эту проверку, collector учитывает порядок.

Коды: 0 — OK; 1 — NEEDS_REPAIR; 2 — usage; 70 — disabled/ошибка/неподтверждённый
input; 73 — lock busy. Check не делает repair и не возвращает batch наружу.

## Repair и worker

Repair и loop disabled без trusted local `HG_ASATA_KEEPER_AUTHORIZED=1`.
Этот opt-in не является согласием владельца: включать его на production можно
только после отдельного разрешения и подготовки backup/rollback.
Команды `repair` и `loop` отсутствуют в Telegram allowlist.

Repair получает kernel flock и приватный RAM snapshot цепочки, до 64 KiB.
Парсер требует таблицу/цепочку, завершённую структуру, корректные числовые handles,
до 32 помеченных правил. При missing/malformed/oversize input ничего не меняется.
Batch содержит только delete помеченных handles и insert точного правила первым;
чужие правила не удаляются. Весь batch передаётся одним `nft -f`, без отдельного
удаления перед вставкой. Race с удалением chain/handle даёт failure всей batch.
После применения повторный bounded read обязан показать единственное точное
первое правило. Только тогда печатается REPAIRED и fixed audit message в syslog.
Это не заменяет общий persistent action audit этапа 0.7.

Вызовы nft ограничены timeout 5 секунд. Kernel lock не имеет stale PID-directory.
Владение fd сохраняется у bounded nft child до его завершения; после SIGKILL parent
оно может удерживаться до 5 секунд. Loop имеет отдельный singleton flock,
итерации каждые 10 секунд; после SIGKILL parent sleep child может удерживать loop
lock до 10 секунд. Это ограниченная задержка recovery, не бесконечный stale lock.
Процесс group stop предпочтителен; target procd поведение требует LIVE проверки.
Приватные snapshots удаляются EXIT/INT/TERM; SIGKILL может оставить bounded RAM
каталог до reboot. Keeper не меняет UCI и не перезапускает data plane.

## План установки владельцем (не выполнен)

1. Сохранить оригинальные keeper/init и nft chain listing приватно, проверить SHA.
2. Проверить kernel nft atomic batch и target BusyBox/timeout/flock на изолированном
   стенде. Поведение реального ядра не моделируется boundary tests.
3. В согласованное окно остановить старый procd keeper. Не запускать оба worker.
4. Через LAN доступ проверить `check`, отдельно разрешить один repair и проверить
   rule order, ASATA, MAIN/Torrent/DNS/Tailscale. При ошибке восстановить оригинал.
5. Новый procd worker должен запускать фиксированный `gateway asata-keeper loop`
   с local opt-in. Сохранение нового init/enable link в sysupgrade inventory
   проверяется владельцем до reboot/sysupgrade. Init пока не установлен/не enabled.

Автоматизированные tests используют production ash/module/timeout/flock и
изолированную nft process boundary. Они проверяют actual OS lock/crash/timeout,
точный batch, fail-closed и postcheck, но не доказывают Linux nft atomicity,
procd/sysupgrade или production rule compatibility. Stage 0.5 остаётся не принят.
