# Аудит предоставленных исходников — 10.10.2026

WORK_HANDOFF.md изучен. Оригиналы приватные: в Git/CI/PR не добавляются,
на рабочем хосте не исполняются. Подтверждены размер и SHA256:

| Файл | Bytes | SHA256 |
|---|---:|---|
| vless-auto.sh | 49251 | cab3ffda3cdbdff192c3a91729b806c3998f2340418306ce5c4af67573fb6279 |
| asata-udp-direct | 1261 | 6d0411a56ad43afd78b47589ff8ad793e77b9f3d56fc722066ee6d5bef605de7 |
| asata_udp_direct | 260 | 7f2d8aea08d73e3aa0030606799515a57aa060092bf52e564acbac245f2d8b37 |

vtest имеет реальные offline TSV formats: по ним написан самостоятельный bounded
adapter. Provider status не используется: он выполняет сетевые probes.
Runner пока blocked: PassWall helper dependencies отсутствуют, cleanup ownership
и PID lock недостаточно безопасны для production. Подробности: [VTEST.md](VTEST.md).

ASATA keeper считает достаточным наличие comment. Это не доказывает source IP,
UDP, return, отсутствие дополнительных условий или правильное положение правила.
Mkdir lock не гарантирует recovery после аварии. Init запускает повторяющийся
keeper под procd. Требуется самостоятельная реализация точной проверки с порядком
правил, атомарной nft batch и lock, который освобождается после смерти процесса.
Новый keeper нельзя устанавливать одновременно с оригинальным worker.

Предоставленный архив не содержит байтов failed CD staging `redmi.sh`. Причина
target syntax error по-прежнему не доказана. Нужны exact artifact и staging bytes;
старый installed script не является заменой этого сравнения.

Принятие 0.5/0.6 и последующих этапов не заявляется. CUDY не изменён, LIVE,
reboot/sysupgrade и soak ожидают отдельного разрешения владельца.
