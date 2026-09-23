# CUDY CI/CD: установка и восстановление

## Границы готовности

Реализованы сборка и проверка релиза, dry-run, ограниченный SSH-протокол,
контролируемая установка, backup, post-check, автоматическое восстановление
при ошибке, повторяемый recover после обрыва/перезагрузки и ручной rollback.
Shell-интеграционные тесты используют отдельный корень файловой системы и
имитируют procd/ucode/gateway. Они проверяют настоящий engine.sh, но не
заменяют тест на CUDY, реальную Tailscale-сеть и отключение питания устройства.
Первое включение требует LAN-доступа владельца, нового SSH-ключа и настройки
Tailscale OIDC. Пока этот шаг не выполнен, CD не активирован.

## Архитектура и доверие

- CI собирает код из Git commit, запускает проверки и публикует архив.
- Deploy CUDY запускается только вручную, с environment `production` и
  общей concurrency group. `plan` выбран по умолчанию.
- Запуск CI должен быть успешным, из этого репозитория, из разрешённой ветки,
  от push/workflow_dispatch, точно для указанного полного SHA. PR-артефакты не принимаются.
- Инструменты deployment берутся из SHA самого workflow, не из архива релиза.
- После проверки архива клиент передаёт bounded-протокол: фиксированный
  список из 18 путей, размеры, права, SHA256 и base64 содержимого. На CUDY
  нет распаковки входящего tar, интерпретации JSON как shell или произвольных путей.
- Ограничения: архив до 8 MiB, запрос до 1 MiB, файл до 256 KiB;
  изменение списка runtime требует явного обновления доверенного receiver.
- Новый ключ CD допускает только plan/apply/status/rollback/recover; он хранится
  в GitHub Environment, отдельно от smoke-ключа. Порт 2223, tag:cd.
- Важно: право устанавливать root-код эквивалентно доверию этому коду.
  Forced command ограничивает интерфейс, но не делает вредоносный релиз безопасным.
  Защищайте ветку, workflow, environment и ключ; smoke-ключ не получает write-доступ.
- На 2223 используется обычная база authorized_keys Dropbear: существующие
  административные ключи сохраняют свои права. Ключ CD добавляется только с
  command= и запретом PTY/forwarding. На этом instance НЕ устанавливается
  общий ForceCommand: он перекрыл бы command= smoke-ключа.

## Однократная активация

1. Применить патч, запустить тесты, commit/push и дождаться зелёного CI.
   Workflow с workflow_dispatch должен присутствовать в default branch,
   чтобы GitHub позволил запускать его вручную. Сделайте обычный PR/merge
   в default branch; не меняйте default branch только ради кнопки запуска.
2. В PowerShell из корня проекта:

   ```powershell
   python scripts/deploy/bootstrap.py
   ```

   Используется существующий доверенный SSH root@192.168.1.1; проверка host key
   обязательна. Скрипт создаёт `local/cudy-cd` через ssh-keygen без проблемы
   пустого аргумента PowerShell, отправляет только public key и receiver.
   Конфигурации сохраняются в `/root/home-gateway-cd-bootstrap.*`.
   LAN SSH и smoke 2222 не изменяются. Добавляются Dropbear 2223, firewall rule,
   recovery service и записи sysupgrade. При отсутствии обязательного инструмента
   bootstrap останавливается до изменения конфигурации.
3. В Tailscale добавьте `tag:cd` с владельцем `autogroup:admin` и grant:

   ```json
   {"src": ["tag:cd"], "dst": ["100.84.35.92"], "ip": ["tcp:2223"]}
   ```

   Существующие правила сохраните. Тест policy для tag:cd: accept 2223,
   deny 22/80/443/2222 и LAN 192.168.1.1:22. Для tag:ci дополните deny портом 2223.
   Не добавляйте allow-all для tagged nodes.
4. Создайте ОТДЕЛЬНЫЙ Tailscale trust credential GitHub OIDC, с правом
   создания auth keys и tag:cd. Issuer: `https://token.actions.githubusercontent.com`.
   Subject для observed immutable GitHub subject format этого репозитория:

   ```text
   repo:bsekinaev@208483034/cudy-home-gateway@1378260931:environment:production
   ```

   Если фактически полученный `sub` отличается, скопируйте точное значение
   из Tailscale credential diagnostics. Не используйте wildcard репозитория.
   Environment-claim заменяет branch-сегмент; branch ограничивается в GitHub.
   Сохраните Client ID и Audience; приватный SSH-ключ в чат не присылайте.
5. С установленным GitHub CLI (`gh auth login`) выполните:

   ```powershell
   python scripts/deploy/configure_github.py --branch feature/health-alerts
   ```

   После перехода на main используйте `--branch main` и предварительно удалите
   старое разрешение ветки в environment. Скрипт создаёт environment production
   с вами как reviewer (self-review разрешён для единственного владельца),
   ограничением ветки и переменной CD_ALLOWED_REF. Он спросит Client ID/Audience
   без отображения и установит четыре environment secrets:
   TS_CD_CLIENT_ID, TS_CD_AUDIENCE, CUDY_CD_SSH_KEY, CUDY_CD_KNOWN_HOSTS.
   Если тариф/видимость репозитория не поддерживают required reviewers,
   настройка завершится ошибкой; не заменяйте автоматически защищённое окружение
   незащищённым. Проверьте доступные настройки GitHub.

Host key для 2223 читается через доверенный LAN SSH и сохраняется в
`local/cudy-cd-known-hosts`, в формате `[100.84.35.92]:2223 ssh-ed25519 ...`.

## Первый сквозной запуск

В GitHub Actions → Deploy CUDY → Run workflow выберите разрешённую ветку.
Для plan/apply укажите ID успешного CI (число в URL actions/runs/...) и полный
40-символьный SHA именно этого CI. Статус success обязателен.

1. `plan`: ожидайте список SAME/UPDATE, полный SHA и CHANGED=N. Runtime не меняется.
2. `apply`: при изменениях выполняются текущие version/selftest/doctor/health,
   проверка места, backup, остановка Telegram, установка, повторные проверки
   и восстановление исходного состояния службы. Ожидайте DEPLOY_RESULT=PASS.
3. Повторный `apply` того же релиза: DEPLOY_RESULT=NO_CHANGE, без рестартов/backup.
4. `status`: показывает последний transaction и фазу.
5. `rollback`: возвращает код предыдущего успешного deployment и прежние права.
   После него выполните Router Smoke; затем можно снова применить целевой релиз.

NO_CHANGE подтверждает совпадение файлов/прав, а не здоровье сетевых сервисов;
для актуальной проверки состояния используйте Router Smoke.

Не ломайте живой CUDY ради negative-tests. Повреждённые запросы, нехватка места,
ошибки записи/health, SIGKILL и потеря runtime-lock проверяются в CI-стенде.
После активации отдельно проверьте штатную перезагрузку роутера в удобное время:
Tailscale, оба SSH instance и Router Smoke должны восстановиться. Физическое
отключение питания на стенде не моделируется.

## Установка и crash recovery

Это контролируемая замена файлов, НЕ атомарное переключение всей системы.
Каждый файл сначала записывается во временный файл в том же каталоге и
заменяется rename. Telegram на это время остановлен; не запускайте параллельно
ручные gateway-команды. Другая административная запись в файлы во время
deployment не поддерживается.

Журнал и backup: `/etc/home-gateway-deploy/tx.*`, права 0700.
Фазы: PREPARED → APPLYING → CHECKING → COMMITTED.
При ошибке: RESTORING → RESTORED → ROLLED_BACK.
Перед первой заменой active pointer и backup синхронизируются на диск.
После SIGKILL/сбоя recover восстанавливает весь набор из backup; если COMMITTED
уже записан, завершает фиксацию. Повторный recover безопасен.

Recovery init запускается на boot с START=94, Telegram имеет START=95.
Новый Telegram init отказывается стартовать при незавершённой установке.
На первой установке старый init ещё может не иметь guard; если recovery
не завершился, используйте LAN и остановите Telegram перед ручным разбором.

При разрыве SSH во время передачи runtime остаётся прежним. После приёма
запроса engine игнорирует SIGHUP; TERM вызывает попытку отката. Если runner
потерял соединение, результат неопределён до status/recover. Не считать сетевую
ошибку доказательством отката и не перезапускать apply вслепую.

На роутере через LAN:

```sh
sh /usr/libexec/home-gateway-deploy/engine.sh status
sh /usr/libexec/home-gateway-deploy/engine.sh recover
```

Если lock указывает на живой процесс, дождитесь завершения. Если процесс умер,
recover убирает stale lock. Если PID-файл пуст или PID был переиспользован,
проверьте процессы локально перед удалением `/tmp/home-gateway-deploy.lock`.

Ручной rollback отказывается перетирать изменённое вне deployment содержимое.
Recover аварийной транзакции, напротив, восстанавливает сохранённое состояние.
Хеши backup проверяются до восстановления; при повреждении backup автоматическое
восстановление прекращается и сохраняет active marker. Используйте проверенную
копию с ПК и административный LAN-доступ. Прежняя неисправность внешней сети
не мешает байтовому восстановлению, но её health может оставаться DEGRADED.

Backup не содержит Telegram secrets или сетевую конфигурацию: они не меняются
установщиком. Backup хранятся без автоматического удаления; свободное место
проверяется перед каждым обновлением. Ротацию выполняйте после переноса копий
на ПК, не удаляя active/latest transaction.

## Обновление receiver и отключение CD

Receiver не входит в runtime payload и не может обновлять себя через CD.
Меняйте его только через административный LAN после тестов и backup.
Пакетные обновления Dropbear/Tailscale могут заменить наши локальные init-правки;
после них проверяйте netdev и proxy settings. Sysupgrade persistence не является
гарантией совместимости с другой прошивкой.

Чтобы отключить write-доступ, удалите/отзовите CD credential в Tailscale,
удалите CD key из authorized_keys и отключите dropbear.cd_deploy + firewall.cd_deploy.
Сохраните receiver, journal и recovery service до завершения active transaction.
Не восстанавливайте целиком старые UCI backup поверх более новых настроек.

## Проверки разработчика

```sh
python3 -m unittest discover -s scripts/release -p 'test_*.py' -v
python3 -m unittest discover -s scripts/deploy -p 'test_*.py' -v
HG_TEST_SHELL='busybox ash' HG_TEST_BUSYBOX=busybox python3 -m unittest discover -s scripts/deploy -p 'test_*.py' -v
```

На Windows shell-интеграционные сценарии помечаются skipped; полностью они
выполняются на Ubuntu CI. Имитация gateway/procd/ucode явно отделена от реальных
проверок CLI и ucode compilation в CI и post-deploy на роутере.

Источники: https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments
и https://tailscale.com/docs/integrations/github/github-action .
