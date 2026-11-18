# HGDEPLOY2 owner update — LIVE 18 ноября 2026

## Подтверждённые результаты владельца

Владелец самостоятельно выполнил Preflight, Apply и отдельный Verify из
PowerShell через основной LAN-доступ. Кабельный резерв доступен по требованию;
его подключение для этого обновления не запрашивалось. Агент к CUDY не подключался.

- Source: `d2039b6c62da3aa458f720af1c46fb619aee48dd`.
- Профиль: `OWNER_MANUAL`.
- SHA256 tar.gz: `a39fb710909661d6c03c4f2f73f3b7645017b14a07999c80666de6735b926eed`.
- Preflight: PASS; baseline runtime verified; workers PASS.
- Apply: `OWNER_UPDATE_STAGE=Apply RESULT=PASS`.
- Отдельный Verify: `OWNER_UPDATE_STAGE=Verify RESULT=PASS`.
- Журнал обновления: VERIFIED, `PHASE=COMMITTED`.
- Runtime: VERIFIED, `IDENTITY=candidate`.
- Migration admission: ADMITTED.
- Оба Telegram workers: PASS.
- Selftest: 62 PASS / 0 FAIL.
- Doctor: 11 OK / 0 WARN / 0 FAIL; overlay 143 MiB.

Предыдущий подтверждённый HGDEPLOY2 baseline:
`62592457237e7f026786c086d1ca6fdd4b6c095d`, RC-B 20261020.2.
Этот результат подтверждает incremental owner update, без повторной миграции.
Runtime version остаётся `0.5.0-dev`.

## Область и ограничения доказательств

Основание — предоставленные владельцем консольные результаты трёх stages.
Private Windows sessions, transport evidence и исходный owner kit сохраняются
локально у владельца; полные приватные логи в репозиторий не включаются.

До LIVE выполнены exact-source CI 13/13 и OpenWrt VM 81/81:
https://github.com/bsekinaev/cudy-home-gateway/actions/runs/44168048251

Пользовательская проверка Telegram navigation, реальные ответы бота,
клиентский интернет после обновления и наблюдение 24–72 часа ещё ожидаются.
LIVE rollback этого обновления, reboot persistence и sysupgrade restore не
выполнялись и не считаются принятыми. Результат не закрывает v1.0 acceptance.

Следующие шаги: read-only Telegram acceptance и клиентская проверка,
затем эксплуатационное наблюдение и завершение приёмки уведомлений 0.5.

## Наблюдения для следующей разработки

Русский текст в PowerShell transport выводится с неверной кодировкой;
ASCII markers и Verify читаются корректно. Это отдельный дефект отображения.
Внутренняя строка Apply `OWNER_UPDATE_RESULT` печатает путь poller в поле SOURCE;
runner и Verify правильно сообщают immutable source SHA. Не исправлять уже
принятый immutable kit или установленный runtime вручную; разобрать отдельным патчем.
