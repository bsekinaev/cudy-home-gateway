# Notification Dispatcher — checkpoint 0.5

PR #6 объединён после успешного GitHub CI. Compaction объединена через PR #8 после CI SUCCESS. Приёмка на CUDY остаётся отдельной.
Версия остаётся `0.5.0-dev`. Диспетчер изменяет только control-plane state.

## Модель доставки

`incidents.jsonl` → projection → `notifications.jsonl` → Telegram `sendMessage`.
Каждый современный ID содержит `incident_id`, event и timestamp. Старые ID без timestamp
поддерживаются только как legacy; они больше не подавляют современные STATE_CHANGED.

Queue snapshot остаётся JSONL для совместимости с существующей установкой. Изменения
сохраняются под общим CLOEXEC/flock lock: запись `.new`, flush/close, `sync`, rename,
`sync`. Успех записи проверяется до внешнего вызова. Повреждённая/невалидная очередь,
policy или incident journal останавливают обработку, исходные файлы не перезаписываются.
Оставшийся `.new` не является подтверждением доставки.

Состояния:

- `PENDING`: ожидает доступной категории, окончания mute и next_attempt_at;
- `INFLIGHT`: попытка сохранена до HTTP, lease 60 секунд;
- `SENT`: Telegram подтвердил `ok=true` и целочисленный `message_id`;
- `FAILED`: постоянная ошибка Telegram (400/401/403/404), требуется разбор владельца;
- `COALESCED`: переход включён в recovery summary.

После crash/reboot истёкший INFLIGHT повторяется. SENT не отправляется повторно.
**Это at-least-once, а не exactly-once:** Telegram sendMessage не предоставляет ключ
идемпотентности. Если сервер принял запрос, а процесс умер до сохранения SENT либо
ответ потерялся, повторная попытка может создать дубликат. ID события в тексте позволяет
его распознать. Crash после записи RATE_LIMIT receipt до записи policy также сохраняет
общую паузу: receipt проверяется при следующем запуске.

## Транспорт и retry

MAIN SOCKS `127.0.0.1:1082`; fallback Torrent SOCKS `127.0.0.1:1081` только когда
HTTP-код 0, curl завершился с ошибкой и сообщает нулевой размер отправленного тела.
Проверяется только последний transport suffix; разделитель внутри повреждённого HTTP body
не может разрешить fallback. Malformed metadata откладывает доставку без fallback. При неоднозначной ошибке
после передачи тела fallback не выполняется; событие остаётся для позднего retry.
Прямой WAN не используется, ambient NO_PROXY отключён. MAIN не переключается.

Connect timeout 5 с, общий timeout 10 с на маршрут. До четырёх событий за итерацию.
Backoff: 15, 30, 60… до 3600 с. Retry-after Telegram учитывается до 86400 с и блокирует
всю очередь, включая другие события. HTTP-ответы обрабатываются и при curl exit 22.
HTTP 5xx и невалидные ответы повторяются; постоянные ошибки не создают hot loop.
Token читается из штатного secrets-файла, URL передаётся curl через stdin config.
Payload — приватный RAM-файл 0600, удаляется после вызова. Curl stderr не журналируется;
из ошибок сохраняются только фиксированные коды. Raw `reason` не включается в сообщения.

## Ограничение истории и dedup

`sync`/`dispatch` автоматически запускают compaction после 512 queue/journal records.
Ручной запуск: `gateway notifications compact`. Сохраняются все PENDING/INFLIGHT,
последние 256 terminal receipts, OPEN/latest STATE_CHANGED активных инцидентов и
OPEN/latest STATE_CHANGED/RECOVERED последних 128 закрытых инцидентов. Источник любого
неотправленного события сохраняется независимо от возраста. OPEN в journal сохраняет
длительность будущего recovery даже после удаления его полной notification receipt.

`notification-dedup.json` хранит IDs подтверждённых событий, оставшихся в journal без
полной queue receipt. Удаление SENT из queue само по себе недопустимо. Compaction берёт
notification lock, затем incident lock; concurrent tick возвращает 73. Результаты
сначала сохраняются в `notification-compaction.json` (redo journal), затем публикуются
dedup, queue, incidents и `notification-compaction.snapshot.json`. Только после sync
удаляется redo journal. Incident producer не добавляет события при незавершённой
compaction. Worker сначала восстанавливает redo, затем запускает tick.

`gateway notifications recover` завершает прерванную операцию без доставки. Это также
выполняется перед обычными notification-командами. Если dedup index потерян, IDs читаются
из последнего committed snapshot. Если потеряны оба файла, marker в компактированной
queue останавливает доставку. Corrupt index/redo не сбрасываются автоматически.
Snapshot используется для восстановления dedup, **не для отката новой queue**: там могут
быть более свежие SENT. Все state файлы приватны (0600). Backup/restore должен сохранять
весь state согласованно; смешивать snapshots разных моментов нельзя.

Лимит чтения каждого файла и размера redo — 2 MiB. Успешная compaction ограничена 1024
queue records и 1024 journal records; превышение из-за неотправленной работы вызывает
backpressure, а не eviction. Ни PENDING, ни INFLIGHT не удаляются ради лимита. При
длительной недоступности/выключенной доставке оператор должен разобрать backlog до
достижения byte cap. Это не бессрочное хранение всей истории: старые завершённые
инциденты удаляются согласованно с их квитанциями.

## Recovery, mute, категории

Накопленные PENDING OPEN/STATE_CHANGED одного закрытого инцидента объединяются в одно
RECOVERED с длительностью. SENT сохраняются. Неоднозначный INFLIGHT сначала выдерживает
lease; после него coalescing предотвращает отправку устаревшего OPEN после recovery.
Mute и отключённая категория откладывают доставку, не удаляя события.

```sh
gateway notifications
gateway notifications --json
gateway notifications sync
gateway notifications dispatch
gateway notifications compact
gateway notifications recover
gateway notifications configure enable
gateway notifications configure disable
gateway notifications configure mute 3600
gateway notifications configure mute 0
gateway notifications configure category main off
gateway notifications configure category main on
```

Категории: wan, dns, main, torrent, redmi, asata, tailscale. Mute: 0–86400 секунд.
Без policy доставка выключена. Enable/disable и категории сохраняются на flash.
Policy повреждена → доставка остановлена; автоматического сброса настроек нет.
Два procd instance в существующем сервисе: poller и notifications worker. Worker при
включённой policy выполняет incident tick и dispatch, затем ждёт 30 с. Он независим от
long polling. Любая ошибка control plane не меняет конфигурацию data plane.

## Sysupgrade

После согласованной установки владелец выполняет отдельно:

```sh
gateway notifications persistence
sysupgrade -l
```

Первая команда идемпотентно дополняет `/etc/sysupgrade.conf`, сохраняя существующие строки:
`/etc/home-gateway/`, `/usr/bin/gateway`, `/usr/lib/home-gateway/`, Telegram init script
и его S95 autostart link. Она не запускает sysupgrade или reboot. Вторая команда
проверяет фактический backup inventory без перепрошивки. Секреты включаются в backup
вместе с `/etc/home-gateway/`; такой backup хранить приватно, не загружать в CI/Git.
Пакеты ucode/curl/CA certificates должны присутствовать в целевом firmware отдельно.
Данные CD receiver и внешних keeper не входят в этот новый Gateway allowlist;
проверить их сохранение по существующей процедуре CD до реального sysupgrade.

## Отказ и восстановление

1. Остановить notifications worker/сервис штатно, сохранить приватную копию state.
2. Проверить свободное место, права, синхронизацию времени и последнюю валидную копию.
3. При corrupt state восстановить проверенную копию или вручную исправить конкретную
   повреждённую запись после сопоставления с incident journal и Telegram receipts.
4. Не обнулять очередь автоматически: это может повторно отправить старые события.
5. Выполнить show/json/sync, затем однократный dispatch после разрешения владельца.

## Проверки

Production ucode revision `85922056ef7abeace3cca3ab28bc1ac2d88e31b1`, BusyBox ash/awk.
46 tests: queue/transport faults, restart/reboot simulation, SIGKILL, backoff, 429,
HTTP errors, corruption, failed write, orphan `.new`, legacy IDs, recovery, mute,
category, bounded batch, size cap, persistence, exact ASATA collector semantics, compaction bounds, every redo
publication boundary, producer lock, recovery duration, missing/corrupt dedup and backlog backpressure.
HTTP boundary в автоматизированных тестах — test curl fixture; настоящий Telegram,
SOCKS/Xray и flash power loss этим не подтверждены. Production не содержит test stub.

LIVE остаются: фактический curl/OpenWrt TLS и SOCKS, Telegram receipts/fallback,
штатный reboot и procd, sysupgrade inventory, flash-поведение, точный nft output,
внешний ASATA keeper и проверка data-plane invariants. Рискованные fault tests только
на изолированном стенде, не на production CUDY.

Независимый ASATA keeper и pending LIVE-план: [ASATA_KEEPER.md](ASATA_KEEPER.md).
