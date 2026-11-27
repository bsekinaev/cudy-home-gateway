# MAIN Transactions — 0.8 work in progress

`gateway main-transaction plan NODE` — read-only observation of the existing UCI
configuration. It accepts a named section of up to 64 alphanumeric/underscore
characters, requires the audited profile mapping `socks_P8ART`, socks/enable=1,
port 1082, global enabled=1, autoswitch explicitly disabled, a candidate section
of type `nodes`, and no pending PassWall2 UCI edits. Read commands use bounded
output and `timeout -k 1 5`; raw errors, config, node IDs and credentials are not
returned. No external vtest command, node process, traffic probe or restart runs.

Even a valid observation returns **70 / PREFLIGHT_ADAPTER_REQUIRED** with
`apply_supported=false`, `preflight_passed=false`, `snapshot_ready=false`.
`same_as_configured_main` compares only configured IDs; it does not prove actual
active egress. Independent UCI reads are not an atomic or generation-consistent
snapshot, and no authorization token/certificate is created. `apply`, `rollback`
and `recover` fail closed without invoking UCI. Telegram has no access to this
command. Runtime inventory remains unchanged (implementation in `vpn.sh`).

## Remaining implementation and acceptance

1. Audit the actual PassWall2 `utils.sh` and `app.sh run_socks` dependencies and
   target version. The supplied vtest calls these privileged helpers but does not
   include their implementation. Never execute an unaudited provider or broad
   `pgrep` cleanup on production.
2. Establish process-owned temporary SOCKS, unique port and hard timeout; actual
   TLS-verified candidate network preflight and owned cleanup, no MAIN changes.
3. Coordinate every UCI/nft/service writer. A private copy and repeated reads
   alone cannot make a snapshot/apply safe against concurrent writers.
4. Snapshot relevant config privately with hashes, durable transaction journal,
   apply intent persisted before change, staged apply, independent post-check,
   commit/rollback and crash/reboot recovery. This is distinct from existing
   control-plane transactional deployment.
5. Verify LAN recovery and Tailscale independently; owner-approved isolated
   tests before any live MAIN apply. Record target rollback and backup evidence.

These capabilities are **not implemented or accepted** yet. Real CUDY remains
unchanged and no v1.0.0 tag may be created from this planner.

## Решение в режиме наблюдения

`gateway recovery-review` оценивает один снимок health. Результат содержит
decision и changes_applied=false. KEEP_MAIN означает, что основной выход
подтверждён. WAIT_FOR_WAN означает, что WAN ещё не подтверждён.
REVIEW_CANDIDATES появляется при свежем успешном WAN и свежей неудачной
проверке MAIN с попыткой через второй проверочный адрес. В остальных
случаях выводится INSUFFICIENT_EVIDENCE.

Команда доступна по SSH. Она не подбирает и не применяет узел. Для
автоматического режима ещё нужны серия независимых наблюдений, журнал
решений, ограничение попыток, подтверждение LAN и испытания отката.

Журнал режима наблюдения доступен через gateway recovery-history. Цикл
Incident Engine сохраняет последние 16 решений в RAM в incidents.runtime.json.
Решение берётся из того же снимка, который уже собрал мониторинг. Для новой
записи нужны валидные наблюдения WAN и MAIN, оба новее предыдущей записи
того же контекста. Журнал сбрасывается при перезагрузке.

## Выбор узла по результатам vtest и управление из Telegram

Плановый vtest обновляет рейтинг кандидатов. Запись рейтинга сама по себе
не запускает переключение. Gateway принимает только полностью завершённый
отчёт известного поставщика, со временем, идентификатором запуска и
контекстом конфигурации. Отчёт обязан относиться к текущему набору узлов.
Текст отчёта не исполняется. Узлы вне списка владельца отклоняются.

При подтверждённом отказе MAIN свежий рейтинг определяет порядок проверки.
Кандидат допускается только после новой проверки через временный SOCKS.
При здоровом MAIN плановая оптимизация выключена по умолчанию. Для её
включения нужны отдельное согласие владельца, повторно подтверждённый
выигрыш по нескольким замерам, пауза между сменами и та же транзакция с
проверкой LAN и откатом. Скорость определяет порядок только среди узлов,
которые прошли доступность, TLS и проверку стабильности.

Telegram сначала показывает последнее решение наблюдения и сохранённый
результат vtest. Следующий этап добавляет действия проверки разрешённого
резерва, паузы автоматики с истечением срока и подготовки смены MAIN.
Смена выполняется только по короткоживущему одноразовому подтверждению,
привязанному к владельцу, чату, сообщению и неизменному плану операции.
Бот передаёт идентификатор плана. Все проверки кандидата, конфликта
записей, LAN и отката остаются в общем механизме Gateway.

Внутренний режим recovery-order принимает нормализованные данные, а не
файлы стороннего vtest. На первом этапе окно актуальности равно шести
часам. Неполный, устаревший или несовместимый отчёт оставляет порядок
резервов из настроек. Допустимые узлы из свежего отчёта проверяются
первыми. Остальные разрешённые узлы остаются в очереди на случай отказа
всех кандидатов из рейтинга. Валидация происхождения отчёта и получение
доверенного контекста остаются задачей источника данных для этого режима.

LAN-проверка для транзакции использует scripts/lan-check.ps1 с параметром
OperationToken. Скрипт выдаёт один JSON с двумя результатами HTTPS.
Внутренний режим lan-review проверяет фазы, токен, загрузку, дедлайн
по монотонному времени и оба ответа 204. Без параметра скрипт сохраняет
предыдущий формат вывода.

Состояние операции, boot ID и время получения должны поступать от
владельца транзакции на роутере по доверенному каналу. Этот валидатор
не выдаёт токены, не потребляет их и не подтверждает происхождение
клиента. Сохранение и одноразовое потребление состояния под блокировкой
относятся к механизму переключения.

Внутренний режим transaction-review оценивает фазу VERIFYING. По умолчанию
он ждёт подтверждения. Свежий SOCKS и валидный ответ LAN разрешают фиксацию.
Подтверждённый отказ SOCKS, истёкший срок или новая загрузка требуют отката.
Если контрольная сумма текущей конфигурации отличается от суммы применённой
кандидатом конфигурации, процесс должен остановиться без записи. Решение
режима само по себе не выполняет применение, фиксацию или откат.

Внутренние режимы transaction-intent и transaction-state сохраняют и читают
запись PREPARED в постоянном каталоге состояния Gateway. Запись содержит ID
операции, ID кандидата и исходную SHA256 конфигурации. Сохранение использует
блокировку, атомарную замену и синхронизацию файла и каталога. Повтор с теми
же параметрами возвращает исходную запись. Другая операция при существующей
записи получает код 75, повреждённая запись блокирует выполнение с кодом 70.



Перед публикацией PREPARED Gateway сохраняет приватную копию PassWall2
с правами 0600. Копия ограничена 256 КиБ, сверяется с исходной SHA256,
синхронизируется и публикуется атомарно. При повторе проверяются и
сохранённая копия, и исходная конфигурация. Повреждённая или отсутствующая
копия блокирует чтение готовой операции. Перед фактической записью
конфигурации потребуется ещё одна сверка под блокировкой и испытание
восстановления на OpenWrt.

transaction-stage создаёт кандидатную конфигурацию в приватном каталоге,
на основе проверенной копии PREPARED. UCI использует отдельные каталоги
конфигурации и правок. Кандидат сохраняется с правами 0600, команда
возвращает его SHA256. Действующий файл PassWall2 этим этапом не меняется.
OpenWrt VM проверяет смену узла в копии, совпадение переданного снимка
с исходным файлом и сохранение исходного хеша действующего файла.

SHA256 подготовленного кандидата сохраняется в журнале PREPARED. Если файл кандидата после этого изменить, чтение состояния и повторная подготовка останавливаются. Стендовый round trip восстанавливает исходный файл из копии и проверяет его байты и выбранный узел через UCI. Этот сценарий выполняется с тестовой конфигурацией, без перезапуска PassWall2.

Стендовые режимы transaction-fixture-apply и transaction-fixture-restore
доступны только для тестового файла fixture-passwall2 в приватном
каталоге /tmp/hg-main-fixture.*. Перед заменой пишутся фазы APPLYING или
RESTORING. После атомарной замены и синхронизации фиксируются APPLIED или
ROLLED_BACK. Повтор сверяет хеш результата. При посторонней правке режим
возвращает 75 и сохраняет содержимое файла.

Временный тест на CUDY подтвердил смену тестового файла, повторяемый
откат и сохранение посторонней правки. Хеш рабочей конфигурации совпал.
Сетевые службы, автоматический вызов по результату LAN и восстановление
после перезагрузки в этот сценарий не входят.

Стендовый transaction-fixture-verify использует токен и срок из журнала
применённой операции. Если SOCKS подтверждён, а LAN-ответ ещё не пришёл,
проверка ждёт до дедлайна. При вызове после дедлайна восстанавливается
исходный тестовый файл. Дедлайн для стенда составляет 30 секунд.
На CUDY сценарий проверен во временном каталоге с управляемыми отметками
времени. Рабочий PassWall2 сохранил исходный хеш.

Стенд вызывает проверку явно. Службу PassWall2, доверенный приём ответа
реального LAN-клиента и автоматический вызов проверки при истечении срока
предстоит подключить в рабочей транзакции.

Стендовый transaction-fixture-watch проверяет журнал раз в секунду.
Блокировка освобождается между проверками, чтобы параллельный процесс мог
передать подтверждение LAN. При истечении срока наблюдатель вызывает
откат тестового файла. После подтверждения с двумя HTTP 204 операция
переходит в COMMITTED, а повтор того же подтверждения получает код 75.

Оба сценария проверены на временных файлах CUDY с неизменным SHA256
рабочего PassWall2. OpenWrt VM получила отдельные проверки таймера,
фиксации и повторного подтверждения. Для рабочего сценария ещё нужны
запуск наблюдателя под управлением службы, доверенная доставка LAN-ответа
и проверка восстановления после перезагрузки.
