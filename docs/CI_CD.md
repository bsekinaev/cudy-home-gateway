# CI/CD

## Статус

На 2026-09-23 проверены:

- запуск Router Smoke из GitHub Actions;
- подключение к CUDY через Tailscale и SSH на TCP/2222;
- выполнение gateway version, selftest, doctor и health;
- автоматический перезапуск CI-экземпляра Dropbear после пересоздания tailscale0;
- успешный Router Smoke после настройки локального SOCKS5-прокси для Tailscale.

Автоматическое развёртывание (write-deploy) пока не реализовано.
Длительная стабильность соединения и восстановление после полной
перезагрузки роутера требуют отдельной проверки.

## Проверки кода

На push в main и feature/**, а также на pull request в main,
основной CI выполняет:

- проверку whitespace изменённых файлов;
- проверку отсутствия secrets/runtime state в Git;
- базовый secret scan;
- проверку LF для runtime и CI-файлов;
- проверку executable mode;
- sh -n для BusyBox/POSIX shell;
- сборку ucode проверенной на CUDY ревизии;
- ucode -c для файлов .uc;
- детерминированный selftest Incident Engine;
- проверку против универсального remote shell.

Основной CI не подключается к домашней сети.
Доступ к роутеру используется отдельным workflow Router Smoke.

## Router Smoke

Файл: .github/workflows/router-smoke.yml.

Условия запуска:

- workflow_dispatch;
- push в feature/health-alerts, если изменён сам router-smoke.yml.

Триггер push добавлен для проверки workflow в рабочей ветке.
После переноса workflow в основную ветку его необходимость нужно пересмотреть.

Runner входит в tailnet с тегом tag:ci и подключается к
root@100.84.35.92 на порту 2222.

На роутере выполняется /usr/bin/home-gateway-ci-smoke.
Разрешённая исходная SSH-команда: smoke.
Признак успеха: ROUTER_SMOKE_RESULT=PASS и успешный код завершения.

Скрипт вызывает:

- gateway version;
- gateway selftest;
- gateway doctor;
- gateway health.

Это проверка установленного на роутере состояния.
Workflow не устанавливает код из проверяемого коммита на CUDY.

## Ограничения доступа

Для CI используется отдельный SSH-ключ.

В /etc/dropbear/authorized_keys его публичная часть имеет ограничения:

- command="/usr/bin/home-gateway-ci-smoke";
- no-port-forwarding;
- no-agent-forwarding;
- no-X11-forwarding;
- no-pty.

CI-экземпляр Dropbear дополнительно использует ForceCommand,
запрещает парольную аутентификацию и перенаправление портов.

Ключ даёт доступ к проверкам, выполняемым от root.
Безопасность зависит от содержимого smoke-скрипта и вызываемых команд.

Административный SSH через LAN остаётся на 192.168.1.1:22.

## GitHub secrets и OIDC

Используются:

- TS_OAUTH_CLIENT_ID;
- TS_AUDIENCE;
- CUDY_CI_SSH_KEY;
- CUDY_SSH_KNOWN_HOSTS.

Tailscale Trust Credential использует GitHub OIDC.

Issuer:
https://token.actions.githubusercontent.com

Subject, проверенный для текущей ветки:
repo:bsekinaev@208483034/cudy-home-gateway@1378260931:ref:refs/heads/feature/health-alerts

Для credential настроены auth_keys с правом Write и тег tag:ci.
При смене ветки или добавлении GitHub Environment необходимо сверить
фактический OIDC subject и обновить доверие.

Приватный SSH-ключ хранится в GitHub secret и локально вне Git.
Файлы ключей, состояние Tailscale и рабочие конфигурации с секретами
не должны попадать в репозиторий.

## Tailscale policy и SSH host key

Для tag:ci разрешён только TCP/2222 к 100.84.35.92.

Policy tests проверяют:

- разрешён 100.84.35.92:2222;
- запрещены 100.84.35.92:22, :80, :443;
- запрещён 192.168.1.1:22.

Правило autogroup:member сохраняет административный доступ пользователей.
При изменении policy нужно учитывать, что разрешения правил суммируются.

CUDY_SSH_KNOWN_HOSTS содержит закреплённый ключ роутера в формате:

[100.84.35.92]:2222 ssh-ed25519 <публичный host key роутера>

Host key получен через доверенное LAN-подключение.
Проверенный fingerprint:
SHA256:DP1+MfTRCQuax4uo+Zac/akmTugaJiQ+ehBG3M2NECg

StrictHostKeyChecking включён.

## Конфигурация OpenWrt

Логический интерфейс network.tailscale_ci:

- proto=none;
- device=tailscale0.

Адрес Tailscale назначает tailscaled.
Пустые массивы адресов в ubus для proto=none не заменяют проверку
фактического адреса командой ip -4 addr show dev tailscale0.

CI-экземпляр dropbear.ci_smoke:

- enable=1;
- DirectInterface=tailscale_ci;
- Port=2222;
- PasswordAuth=0;
- RootPasswordAuth=0;
- RootLogin=1;
- LocalPortForward=0;
- RemotePortForward=0;
- ForceCommand=/usr/bin/home-gateway-ci-smoke;
- mdns=0.

Firewall разрешает IPv4 TCP/2222 из зоны tailscale
к адресу 100.84.35.92.

## Восстановление Dropbear после пересоздания интерфейса

В установленном /etc/init.d/dropbear после строки:

procd_append_param command -l "${ndev}" -p "${Port}"

добавлена строка:

procd_set_param netdev "${ndev}"

Она передаёт сетевое устройство в procd, чтобы reload мог обнаружить
смену индекса интерфейса и перезапустить соответствующий экземпляр.

Проверено: после перезапуска Tailscale индекс tailscale0 и PID
CI-экземпляра изменились; PID LAN-экземпляра остался прежним.

Резервная копия до изменения:
/root/dropbear.init.before-netdev.Pbmoha

Это локальная правка пакетного файла. После обновления Dropbear
необходимо проверить её наличие или наличие эквивалентного исправления
в пакете.

## Tailscale через локальный SOCKS5

На прямом соединении наблюдались длительные тайм-ауты запросов
к серверу координации и TCP-повторы без видимого ответа.
Точная причина прямых обрывов не установлена.

Для сравнительного теста в start_service файла /etc/init.d/tailscale
после procd_set_param env TS_DEBUG_FIREWALL_MODE добавлены:

procd_append_param env HTTP_PROXY=socks5://127.0.0.1:1070
procd_append_param env HTTPS_PROXY=socks5://127.0.0.1:1070

Локальный SOCKS5 предоставляет Xray.
Соединения Tailscale, использующие эти настройки прокси,
зависят от его доступности.

Через прокси Router Smoke прошёл.
В журнале также наблюдались unexpected EOF и ошибки DialPlan
с последующим успешным восстановлением через DNS.
Полное отсутствие обрывов не подтверждено.

Резервная копия:
/root/tailscale.init.before-proxy-test

Откат прокси через LAN:

```sh
cp -p /root/tailscale.init.before-proxy-test /etc/init.d/tailscale
/etc/init.d/tailscale restart
```

Правка находится в пакетном init-скрипте.
После обновления Tailscale необходимо проверить её наличие.
Перенос настройки в устойчивый к обновлениям механизм остаётся задачей.

## Проверка после обслуживания

Через LAN выполнить:

```sh
tailscale status
ip -4 addr show dev tailscale0
ubus call service list '{"name":"dropbear"}'
netstat -ntp | grep tailscaled
logread -e tailscaled | tail -40
```

Проверить наличие адреса CUDY, работающего CI-экземпляра с netdev
tailscale0 и отсутствие сохраняющихся предупреждений Tailscale.

Затем запустить Router Smoke.
Для проверки автоматического восстановления не перезапускать
Dropbear вручную между перезапуском Tailscale и smoke-проверкой.

## Условия включения write-deploy

До автоматической установки на CUDY необходимы:

1. Версионированный release bundle.
2. Проверка SHA256.
3. Staging в /tmp.
4. Backup текущего control plane.
5. Контролируемая установка.
6. Проверки selftest, doctor, health после установки.
7. Автоматический rollback.
8. Сохранение Home Gateway при sysupgrade.

До реализации этих механизмов Actions не должен копировать файлы
поверх живых /usr/bin и /usr/lib.

Для write-deploy планируется отдельное GitHub Environment production
с ограничениями доступа и общей группой concurrency для развёртываний.

## Release bundle (подготовка CD)

Сборщик требует Git и Python 3.10+ на компьютере или CI runner.
Python на роутере не требуется. Установщика в этом checkpoint нет.

```sh
python -m unittest discover -s scripts/release -p 'test_*.py' -v
python scripts/release/build.py --ref HEAD --output dist
```

Сборка читает Git blobs выбранного коммита, а не рабочую директорию.
Незакоммиченные изменения не включаются. Версия берётся из HG_VERSION
в common.sh того же коммита; полная SHA коммита входит в имя архива.
Повторная сборка требует нового output-каталога, если файлы уже существуют.

Результат: tar.gz, внешний файл .sha256 и копия manifest.json.
Внутри архива находятся manifest.json и payload/ с разрешёнными файлами src/.
Manifest schema_version=1 содержит версию, коммит, время коммита,
пути относительно payload, размеры, Unix modes и SHA256 каждого файла.
Symlink, submodule, неожиданные пути и CRLF в runtime отклоняются.
Права берутся из Git, включая сборку на Windows.
Разрешённые пути заданы в scripts/release/build.py; новые категории файлов
нужно явно добавить после проверки их назначения.

Архив содержит только код Home Gateway. Рабочие secrets/state,
настройки UCI, ключи SSH и локальные правки init-скриптов Dropbear/Tailscale
в него не входят. Проверка путей не заменяет проверку содержимого на секреты.

В одинаковом окружении повторные сборки одного коммита побайтово совпадают.
Разные версии Python/zlib могут изменить сжатое представление tar.gz.
SHA256 проверяет целостность, но не является подписью или доказательством
доверенного происхождения. Будущий установщик должен проверять формат,
пути, manifest и доверие к артефакту до установки.

CI выполняет тесты сборщика, сборку и sha256sum -c после основных проверок,
затем сохраняет результат как Actions artifact на 14 дней.
Артефакты pull request являются проверочными, а не разрешёнными к deployment.
Скачивание или сборка архива ничего не устанавливает на роутер.
Не распаковывать payload поверх /: backup/install/rollback ещё не реализованы.
