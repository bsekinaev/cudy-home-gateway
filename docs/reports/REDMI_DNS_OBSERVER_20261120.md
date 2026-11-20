# DNS профиля REDMI: разработка после owner discovery

## Полученные факты

Отчёт владельца `CUDY-DNS-Discovery-20261120-131817.txt`: acl_A2dNs,
dns-in tunnel, 127.0.0.1:2004, DNS роутера 53. BusyBox nslookup A поддержан,
BusyBox timeout-k и awk не поддержаны; версия BusyBox не определилась.
Это описание generated config, а не успешный DNS-запрос и не доказательство
отсутствия отдельных системных timeout/awk. Сам отчёт остаётся у владельца.

## Реализация кандидата

DNS-адаптер использует отдельные timeout/awk, как другие модули проекта;
BusyBox нужен для проверенного nslookup с нестандартным портом. Недоступный
инструмент даёт UNKNOWN до запроса. Никакие пакеты на CUDY не устанавливаются.

REDMI discovery не фиксирует 2004 константой. Оно проверяет один dns-in,
loopback/UDP, точный аргумент config единственного Xray, PID/starttime и
принадлежность socket inode дескриптору этого процесса. Config SHA, node и
socket identity сверяются до/после запроса. Изменение контекста аннулирует
результат. Каждое discovery ограничено timeout 3 с + kill 1 с, DNS 3 с + kill 1 с;
это до 12 с номинального бюджета новой работы, не замер всего status на CUDY.

В status добавлено `redmi.dns`, health различает неуспех DNS/непроверенный DNS,
Telegram показывает отдельный ответ и его возраст. Свежесть UI ограничена
120 секундами; источник live_probe и scope profile_resolver обязательны.
Успех DNS не превращает egress или интернет телефона в проверенные.
Стабильный config/process/listener не доказывает историю загрузки конфигурации
в Xray; локация остаётся «настроенной», а не подтверждённым выходом клиента.

Только пять разрешённых runtime leaves; новая служба/модуль/команда gateway
не добавлены. Фоновое наблюдение независимо от notification OFF, история,
изменение WAN и переключение локаций в этот инкремент не входят.

## Проверки

Реальный UDP resolver, synthetic procfs, а также настоящие procfs/PID/socket
локального исполняемого fixture: ответ и silence, другой владелец/путь,
дублирование, не-loopback, missing files, замена config/node/PID starttime/socket,
отсутствие инструментов и зависший UCI. Kill Switch остаётся приоритетной причиной.
Независимый review runtime: блокирующих замечаний нет; предложенные негативные
проверки добавлены. UI regression сохраняет отсутствие клиентского proof.

Полный repository CI и окончательные результаты записываются после завершения.
Ни unit tests, ни этот отчёт не означают выпуск установленного обновления.

## Следующий owner-тест без установки

[Сборщик проверки](../../scripts/observability/build_probe.py) объединяет только
определения common/dns/redmi и фиксированный безопасный вывод. Пакет запускается
в отдельном shell через stdin и не заменяет установленный runtime. В отличие
от discovery он выполняет ограниченные DNS-запросы и читает process/socket binding.
JSON не содержит generated configs, узлов, ключей, клиентских адресов или сайтов.

Windows PowerShell 5.1 runner и настоящая цепочка Windows OpenSSH → одноразовый
Dropbear на loopback проверены с полным payload кандидата. Перед owner installer
нужен этот bounded test на фактической системе, затем exact-source release gates.
Владелец выполняет соединение; агент production CUDY не трогает.
