# CI/CD

## Текущий checkpoint

CI включается до продолжения `0.5 Health & Alerts`.

На каждый push в `main` и `feature/**`, а также на pull request в `main`, GitHub Actions выполняет:

- whitespace check изменённых файлов;
- policy-check, что secrets/runtime state не отслеживаются Git;
- базовый secret scan;
- LF-check для runtime и CI-файлов;
- проверку executable mode;
- `sh -n` для BusyBox/POSIX shell;
- сборку ucode той же revision, которая была проверена на целевом CUDY;
- `ucode -c` для `.uc`;
- детерминированный selftest Incident Engine;
- safety-check против универсального remote shell.

CI не подключается к домашней сети и не имеет production secrets.

## Почему CD пока не включён

Прямой deployment на CUDY пока намеренно запрещён.

Перед write-deploy должны быть реализованы:

1. versioned release bundle;
2. SHA256 verification;
3. staging в `/tmp`;
4. backup текущего control plane;
5. atomic/controlled install;
6. post-deploy `selftest`, `doctor`, `health`;
7. automatic rollback;
8. sysupgrade persistence для Home Gateway.

До этого GitHub Actions не должен копировать файлы поверх живого `/usr/bin` и `/usr/lib`.

## Read-only router smoke

Второй checkpoint — ручной workflow `Router Smoke`.

```text
GitHub-hosted runner
        ↓
Tailscale ephemeral tag:ci
        ↓
CUDY Tailscale address
        ↓
Dropbear key with forced command
        ↓
home-gateway-ci-smoke
        ↓
gateway version / selftest / doctor / health
```

Workflow не получает универсальный SSH shell. Выделенный public key на CUDY привязан через Dropbear `command=` к `/usr/bin/home-gateway-ci-smoke`, а также запрещает PTY и port forwarding.

Даже при компрометации этого deployment credential ключ не предназначен для произвольного изменения CUDY.

Workflow запускается только вручную через `workflow_dispatch`.

Для production deployment позже будет использоваться отдельный GitHub Environment `production` с ручным запуском/защитой окружения и единственным deployment concurrency group.

## Tailscale

Для GitHub-hosted runner используется ephemeral tagged node `tag:ci` через Tailscale Workload Identity Federation. Production SSH не публикуется в WAN.

GitHub secrets:

- `TS_OAUTH_CLIENT_ID`;
- `TS_AUDIENCE`;
- `CUDY_CI_SSH_KEY`;
- `CUDY_SSH_KNOWN_HOSTS`.

`TS_OAUTH_CLIENT_ID` + `TS_AUDIENCE` относятся только к federated identity с writable `auth_keys` scope и `tag:ci`.

Доступ `tag:ci` должен быть минимальным: в идеале только TCP/22 к Tailscale IPv4 CUDY. Если в tailnet всё ещё действует permissive allow-all policy, её hardening выполняется отдельно после проверки текущего policy, чтобы не потерять административный доступ.
