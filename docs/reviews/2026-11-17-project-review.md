# Сверка плана CUDY Home Gateway — 17 ноября 2026

## Основания и границы проверки

Локально получен репозиторий bsekinaev/cudy-home-gateway. Проверены main
`b093075`, ROADMAP, ACCEPTANCE, README, исходники redmi.sh/health.sh и сведения GitHub
о PR #31. Изучены чаты «CUDY HOME GATEWAY», «Статус и тестирование проекта»,
«Реализация диспетчера уведомлений» и «Диагностика VPN Redmi».
К роутеру в рамках проверки подключений не было; текущий LIVE runtime не измерялся.

## Исходная дорожная карта

| Этап | Задача | Подтверждённый статус |
|---|---|---|
| 0.1 | Foundation, окружение и ограничения | Завершён по ROADMAP |
| 0.2 | Gateway CLI, JSON, doctor/selftest | Завершён по ROADMAP |
| 0.3 | Статус сети и устройств | Завершён по ROADMAP; требуется усилить достоверность REDMI |
| 0.4 | Telegram read-only | Завершён по ROADMAP |
| 0.5 | Health, incidents, уведомления | Текущий этап; LIVE acceptance остаётся открытым |
| 0.6 | vtest runner, progress, alerts | Read-only часть есть; безопасный runner не принят |
| 0.7 | Safe Actions | Код есть, disabled by default; LIVE не принят |
| 0.8 | MAIN Transactions | Только read-only planner |
| 0.9 | Backup, rotation, restore | Частичная реализация; restore не доказан |
| 1.0 | Stable, soak, документация | Не выпущен |

## Что изменилось относительно плана

1. Установка HGDEPLOY2 уже состоялась. Последний подтверждённый владельцем baseline:
   RC-B 20261020.2, source `62592457237e7f026786c086d1ca6fdd4b6c095d`,
   transaction `786dbec9-f1b6-4732-9ea4-23df99d372ed`, COMMITTED,
   отдельный Verify PASS, selftest 62/0, doctor 11/0/0. Это историческое evidence,
   а не измерение состояния 17 ноября. ACCEPTANCE содержит этот результат,
   но README и старые части ROADMAP всё ещё акцентируют предыдущую неудачную установку.
2. Telegram navigation PR #30 объединён. Установка его кода на CUDY не подтверждена.
3. PR #31 открыт: head `0d772f57b8d7bd92923144d3dc9609918a1f90f2`.
   CI run 39756315596 завершён SUCCESS именно для этого SHA.
   Текущая mergeability DIRTY; локальная немутирующая проверка merge-tree
   подтвердила конфликт README.md. Новое разрешение конфликта потребует нового CI.
   Успех CI не доказывает выпуск owner kit или LIVE update.
4. В сегодняшнем чате диагностики MAIN DNS :2002 отвечает, REDMI :2004 и :2007
   дают timeout. Причина не установлена: DNS/upstream/Reality требуют различения.
   Не считать сервер неисправным только по DNS timeout.
5. redmi.sh оставляет EGRESS=UNKNOWN, но общий REDMI_STATE становится OK,
   если процесс, policy и Kill Switch присутствуют. health.sh публикует redmi_ready.
   Значение подтверждает структуру policy, но не доступность сайтов.

## Предлагаемая корректировка очередности

Владелец подтвердил устранение проблемы REDMI и поручил продолжать разработку.
Активная ближайшая задача — завершение существующего updater; усиление health
остаётся отдельным последующим изменением.

1. P0 эксплуатация: получить актуальное read-only наблюдение REDMI и результат
   последней проверки endpoint из чата диагностики. Сохранить Kill Switch;
   исправление выбирать после установления причины, отдельно от updater.
2. P0 диагностика: согласовать контракт REDMI health — отдельно показывать policy,
   DNS и неподтверждённый egress. Ограниченная DNS-проверка должна использовать
   фактический профиль и runtime, а не безусловно зашитый порт 2004.
   DNS success сам по себе не доказывает клиентский VPN egress.
   Регрессии: процесс и правила живы/DNS timeout; DNS success/egress unknown;
   отсутствующий или изменившийся runtime; ограниченное время выполнения.
3. P0 обновление: довести существующий PR #31, разрешить README conflict,
   проверить review и exact-head CI/VM recovery, выпустить immutable owner kit.
   Не расширять Telegram-only inventory delta новыми health-файлами:
   health-изменения требуют отдельного проверенного пакета/поддерживаемого пути.
4. Owner update: свежий preflight, резервный доступ, проверенный rollback,
   поэтапные Apply/Verify и Telegram acceptance при участии владельца.
   Не повторять миграцию и не подменять runtime-файлы вручную.
5. Закрыть 0.5: реальная доставка/recovery уведомлений и наблюдение 24–72 часа
   с начальными/конечными метриками. Reboot и sysupgrade отдельно согласуются.
6. Далее последовательно 0.6 → 0.7 → 0.8 → 0.9 → 1.0; не закрывать этапы
   по одному лишь наличию кода или старому selftest.

Это предложение для согласования ближайшего объёма разработки, не GO для установки.

## Ссылки

- https://github.com/bsekinaev/cudy-home-gateway/pull/30
- https://github.com/bsekinaev/cudy-home-gateway/pull/31
- https://github.com/bsekinaev/cudy-home-gateway/actions/runs/39756315596
