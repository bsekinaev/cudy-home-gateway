# CUDY Home Gateway — контрольная точка 10.10.2026

## Версия

Завершённой новой версии нет. Сохраняется `0.5.0-dev`; этап 0.5 открыт.
Ветка: `feature/0.5-notification-dispatcher`, основана на main
`5c3a7dbeb0d647e3391dee0b6316987754f0ad3f`.
Тег v0.5.0-dev уже существовал; новый тег не создан. Роутер не обновлялся.

## Восстановление GitHub доступа

10.10.2026 доступ на запись восстановлен: рабочая ветка создана через GitHub.
Код опубликован коммитами `1906d46f2c45edebc3db25c5cdec60700544a591` и
`a1a91c5894f5003366b0404fb25733fb3fdd136a`; документация публикуется следующим commit.
Предыдущие 403 и отсутствие credentials ниже относятся к первой попытке.
Новый PR и GitHub CI нужно проверить перед merge. Роутер не обновлялся.

## Аудит

- История main прочитана; feature/gateway-cli и feature/health-alerts не имеют новых
  коммитов относительно main. Открытых PR на момент проверки нет.
- Существующий main CI: SUCCESS,
  https://github.com/bsekinaev/cudy-home-gateway/actions/runs/35936004895
- Последний read-only CD plan: FAILURE,
  https://github.com/bsekinaev/cudy-home-gateway/actions/runs/35936087985
  По журналу: target shell syntax error в redmi.sh line 15. В локальном BusyBox
  1.36.1 файл разбирается. Причина не доказана; нужен target-only read-only разбор.
- GitHub connector create_branch: 403 `Resource not accessible by integration`.
  Git push: нет локальных credentials. PR и CI нового кода не запущены.

## Изменения и коммиты

Исходные локальные коммиты (их код теперь опубликован с новыми GitHub SHA):

- `9685afb2e51c1b775055d1f5ac044a98f10a5dfe` — dispatcher, production Telegram adapter,
  MAIN/Torrent fallback, persistent attempts/receipts, backoff/retry-after,
  coalescing/recovery summary, mute/categories, opt-in procd worker, sysupgrade
  persistence command, ASATA collector semantics, selftest/CI и 31 tests.
- `3726ac5` — дополнительный test отказа записи receipt после успешной отправки.
- Следующий commit документирует этот checkpoint, README/ROADMAP/NOTIFICATIONS.

GitHub-коммиты реализации:
https://github.com/bsekinaev/cudy-home-gateway/commit/1906d46f2c45edebc3db25c5cdec60700544a591
https://github.com/bsekinaev/cudy-home-gateway/commit/a1a91c5894f5003366b0404fb25733fb3fdd136a
Локальные SHA выше сохранены для сопоставления с исходным пакетом продолжения.

## Проверки

- Notification/ASATA tests: 32 PASS.
- Release builder/verifier tests: 13 PASS.
- Deployment/protocol/crash recovery tests под BusyBox ash: 29 PASS.
- Всего: 74 автоматизированных test PASS.
- Репозиторный CI script: PASS; BusyBox ash syntax и target-revision ucode compile.
- Release bundle, SHA256/manifest verification и encode CD protocol: PASS.
  Inventory остаётся 19 файлов, trusted receiver менять для этой итерации не нужно.
- Git diff whitespace и tracked-secret scan: PASS.

HTTP boundary — тестовый curl, crash/reboot проверены в изолированной файловой
системе. Настоящий Telegram, Xray/SOCKS, CUDY flash/reboot/sysupgrade и procd этим
не подтверждены. Старые doctor 11 OK / selftest 58 PASS не считаются проверкой
нового runtime. Production не содержит тестовых заглушек.

## Незавершённое

1. Создать PR опубликованной ветки и дождаться успешного GitHub CI.
2. Разобрать target-only redmi.sh CD plan failure без изменения data plane.
3. После отдельного разрешения владельца — controlled install и безопасная LIVE
   приёмка Telegram/procd/reboot/sysupgrade inventory; destructive tests на стенде.
4. Получить исходник внешнего ASATA keeper; сейчас hardened только read-only collector.
5. Решить долгосрочную ротацию state с сохранением dedup (сейчас лимит 2 MiB и
   остановка обработки). Автоматически удалять SENT/обнулять очередь нельзя.
6. Этапы 0.6–1.0 ещё не реализованы. Нужен soak и реальные критерии stable.

Exactly-once Telegram sendMessage недостижима без серверного idempotency key.
При потере ответа или crash между отправкой и receipt возможен дубликат; это
зафиксированное ограничение at-least-once, не скрытая гарантия.

## Следующее действие

Создать PR `feature/0.5-notification-dispatcher` в main; проверить GitHub CI
нового HEAD. Только после успешного CI решать merge. LIVE приёмка остаётся отдельным
шагом с разрешением владельца; роутер автоматически не обновлять.

Если текущая рабочая копия потеряна, применить патч из пакета в чистом clone:

```sh
git fetch origin
git switch -c feature/0.5-notification-dispatcher origin/main
git am --3way /absolute/path/cudy-notifications-0.5.patch
git push -u origin feature/0.5-notification-dispatcher
```

Перед применением убедиться, что `git status --porcelain` пуст. Не reset/stash чужие
изменения автоматически. Если upstream изменился, проверить diff и повторить CI.
