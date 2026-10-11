# vtest — offline adapter и аудит 0.6

Статус: **частичная реализация, этап 0.6 не принят**.
Исходник VLESS Smart Test 3.0.1-final предоставлен владельцем, SHA256 подтверждён:
`cab3ffda3cdbdff192c3a91729b806c3998f2340418306ce5c4af67573fb6279`.
Приватный оригинал не публикуется и не выполняется на рабочем хосте.

```sh
gateway vtest --json
```

Команда никогда не вызывает provider, включая его `status`. Она читает metadata,
cron и offline TSV observations. `integration=BLOCKED`, `state=UNKNOWN`,
`run_supported=false` сохраняются: наличие lock directory не доказывает живой
процесс, наличие результатов не доказывает успешное завершение последнего запуска.
`null` означает отсутствующие, нечитаемые или неподтверждённые данные.

## Подтверждённый контракт

- `quick [N]`: speed benchmark; лимит N касается числа нод, не времени/трафика.
- `run [N]` / `test [N]`: полный benchmark; команды `full` у provider нет.
- `cap` / `capability`: проверки возможностей кандидатов.
- `status`: выполняет сетевые probes, для offline dashboard запрещён.
- `watch`: бесконечный tail; не вызывается Gateway.
- `stop`: завершает процессы и выполняет cleanup; требует отдельного LIVE approval.
- `recalc`: меняет производные файлы; не является чистым read-only.
- `apply` / `auto`: provider отвергает; Gateway не меняет MAIN по результатам.

На CUDY `/usr/bin/vtest` — symlink на `/root/vless-auto.sh`. Для fingerprint
принимается только эта точная пара путей, без второго symlink. Совпадение digest
выставляет `provider.source_confirmed=true`; это не разрешает выполнение. Другие
symlink fail closed. Regular files по-прежнему проверяются как metadata.

## Данные и ограничения

Результаты: `/root/vless-auto/latest.tsv`, `latest-summary.tsv`,
`latest-capability.tsv`; история — `history/YYYYMMDD-HHMMSS.tsv`.
Адаптер проверяет точные заголовки и число колонок реального provider,
числовые поля, status OK/FAIL и eligible YES/NO. Отдаёт только счётчики samples,
success/failed и nodes/eligible. Результаты/история выдаются только при подтверждённом provider SHA256; stale files
при missing/replaced provider дают null. Имена, node IDs, адреса, location, error и stdout
не попадают в JSON или Telegram. История содержит до 20 timestamp IDs и счётчиков,
в обратном порядке; summary/capability archive не выдаются как отдельные запуски.

Каждый входной TSV ограничен 256 KiB и 4096 строками; используются приватные
0600 RAM snapshots, limit+1 capture и повторная проверка размера. Нет `wc -c`
для неограниченного чтения. Неоконченная последняя строка, неверная схема,
ошибка reader/parser и symlink дают null. Snapshot удаляется на EXIT/INT/TERM;
после SIGKILL приватный bounded файл может остаться до reboot.
History traversal ограничен timeout 2 секунды и бюджетом 8 KiB для всех entries
до suffix filtering. Превышение или ошибка даёт null. Archive rows обязаны
соответствовать run ID имени файла; mixed-run rows отвергаются.
Файлы читаются независимо: это не транзакционный snapshot нескольких результатов.
Во время записи можно видеть предыдущую сводку вместе с более свежими samples;
UI прямо обозначает их как наблюдения, а не завершённый запуск.

Provider fingerprint: stat до чтения, приватный complete snapshot до 256 KiB,
проверенный SHA256. Cron до 64 KiB; только boolean, без содержимого/аргументов.
Telegram `/vtest` и кнопка используют существующие user/chat whitelist, freshness,
message ID, nonce и TTL 120 секунд. Запускающих кнопок пока нет.
Trusted local overrides: `HG_VTEST_PATH`, `HG_VTEST_CRONTAB`,
`HG_VTEST_RESULTS_DIR`, `HG_TELEGRAM_SECRETS_DIR`, `HG_TELEGRAM_RUNTIME_DIR`;
Telegram не управляет путями.

## Блокеры runner

Исходник вызывает привилегированные `/usr/share/passwall2/utils.sh` и
`/usr/share/passwall2/app.sh run_socks`. Точные private copies предоставлены 11 октября 2026 и статически проверены.
Аудит: [PASSWALL_SOURCE_AUDIT_2026-10-11.md](PASSWALL_SOURCE_AUDIT_2026-10-11.md).
Их наличие не разрешает запуск: eval, shared runtime, asynchronous launch и
неполученные Lua generators требуют безопасного отдельного адаптера.
Cleanup использует широкий `busybox pgrep -f` и TERM/KILL; требуется ограничить
владение процессами и исключить MAIN/Torrent. Lock directory/PID требует защиты
от stale lock, PID reuse и SIGKILL. До этого quick/full/capability возвращают 70.
У quick/full значительный трафик; запуск после boot не должен повторять benchmark.
TLS verification и capability semantics требуют отдельной проверки.

Следующая реализация: безопасное владение process tree, lock/timeout/crash recovery,
аудит PassWall helpers, progress и delivery результата. Нельзя заменять benchmark
проверкой наличия curl или успешным doctor. LIVE — только с разрешением владельца.

## Native ownership primitive — partial, не активирован

`native/vtest-supervisor.c` реализует управление собственным foreground Xray child:
фиксированные binary/run root, no shell/pgrep/PID input; kernel flock; fsync RAM
fence + run consumption до fork; no retry after crash. PR_SET_PDEATHSIG закрывает
parent death race. PID нельзя переиспользовать до waitpid; сигналов после reap нет.
Seccomp проверяет syscall architecture, отвергает alternate ABI и новые процессы
(fork/vfork/non-thread clone/clone3); native threads разрешены. Descriptor cleanup
через close_range, core/file/CPU/FD limits; TERM затем KILL; fixed JSON output.
SIGCHLD disposition и signal mask сбрасываются. До exec child ждёт разрешение
по private pipe; pending cancel до grant не запускает provider и не расходует run.
После KILL ожидание ограничено двумя секундами; unreaped child оставляет
RECOVERY_REQUIRED и crash fence, без ложного сообщения об остановке.

22 native isolated tests компилируют тот же код с фиксированным fixture executable:
SIGKILL parent, timeout с TERM-ignoring child, cancel, unrelated service preservation,
concurrency/replay/global fence, fork rejection/threads, descriptor cleanup и
unsafe directories/config/FIFO/symlink. Fixture — только compile-time test boundary,
production путь фиксирован `/usr/bin/xray`, default DISABLED.

Этот helper НЕ устанавливается, не включён в release/runtime inventory, не вызывается
Gateway/Telegram. Cross-build и actual Xray/Go/seccomp/kernel behavior на disposable
OpenWrt пока не проверены. Отсутствуют pinned executable/config generator, audit
UCI schemas, curl/TLS/traffic/memory budget, worker journal/progress/notifications
и owner-authorized target acceptance. Crash fence нельзя автоматически снимать:
high-level recovery должен подтвердить отсутствие owned process, либо дождаться
reboot (без benchmark auto rerun). Stage 0.6 не принят, run_supported=false.

Дополнительное review: EINTR при intent persistence повторяется до sync;
prelaunch cancel очищает собственный intent/fence. Fixture PID публикуется
атомарным rename; test readiness не наблюдает пустой PID file.

Review: cancellation handler и grant используют один always-lock-free atomic
state после unblock; authorization linearizes at CAS, pipe transport следует
после уже принятого решения. fork failure сохраняет one-shot intent, но снимает
global active fence, так как child не существует. 22 native tests PASS.

pipe2/signal-mask resource failure до fork снимает own global fence, сохраняя
one-shot intent; child отсутствует. EMFILE regression, 22 native tests PASS.
