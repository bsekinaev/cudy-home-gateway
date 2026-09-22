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

## Следующий CD checkpoint

Следующим инфраструктурным шагом будет read-only `router-smoke` workflow:

```text
GitHub-hosted runner
        ↓
Tailscale ephemeral node
        ↓
CUDY Tailscale address
        ↓
gateway version
gateway selftest
gateway doctor
gateway health
```

Он докажет безопасный GitHub → Tailnet → CUDY канал, но ничего на роутере не изменит.

Для production deployment будет использоваться отдельный GitHub Environment `production` с ручным запуском/защитой окружения и единственным deployment concurrency group.

## Tailscale

Для GitHub-hosted runner предпочтителен ephemeral tagged node. Production SSH не публикуется в WAN.

Доступ `tag:ci` должен быть минимальным: только к SSH CUDY, без широкого доступа ко всему tailnet.
