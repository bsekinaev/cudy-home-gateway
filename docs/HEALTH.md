# Health Core

Этап `0.5.1` вводит read-only Health Core поверх существующего Status API.

## Уточнение текущего состояния и следующего выпуска — 20.11.2026

Health установлен в source fb8d9e3; [LIVE-приёмка](reports/HGDEPLOY2_OWNER_SERIES_20261120_LIVE.md).
`components.redmi` описывает policy/process/защиту, а не сквозную доступность
телефона. DNS роутера и будущая DNS-проба REDMI — разные scopes.

[Переработанный проект](superpowers/specs/2026-11-20-internet-observability-revised-design.md)
вводит общий ID/свежесть измерения и явные пропуски. Это будущая работа, не
изменение текущего JSON contract. Повтор кэша не должен стать несколькими
независимыми подтверждениями для incident engine.

## Граница ответственности

Health Core:

- не изменяет routing, PassWall2, nftables, DNS или другие части data plane;
- использует уже существующие adapters и `hg_status_collect`;
- нормализует состояния компонентов;
- отделяет component health от внешних egress observations;
- сохраняет `source`, `checked_at`, `age_seconds` и `freshness` внешних проверок.

Команды:

```sh
gateway health
gateway health --json
```

## Overall state

Core-компоненты: WAN, DNS, MAIN.

`DOWN` любого core-компонента делает overall `DOWN`.
`DEGRADED` core-компонента делает overall `DEGRADED`.
`UNKNOWN` core-компонента делает overall `UNKNOWN`, если нет более тяжёлого состояния.

Service/policy-компоненты: Torrent, Redmi, ASATA, Tailscale.

Их `DOWN` или `DEGRADED` понижает здоровый overall до `DEGRADED`, но не объявляет весь интернет-шлюз `DOWN`.

## External evidence

Direct, MAIN и Torrent egress выводятся отдельно как evidence.

Freshness:

- `live` — результат live probe;
- `cached` — валидный результат существующего cache;
- `stale` — старое значение сохранено только для диагностики;
- `unknown` — свежесть определить нельзя.

Health Core не превращает `stale_cache` в `OK`.

## Следующие итерации

`0.5.1` не отправляет alerts.

Incident state реализуется отдельной state machine и не смешивается с adapters/Health Core. См. [Incident State](INCIDENTS.md).

Adaptive confirmation probes описаны в [Adaptive External Probes](ADAPTIVE_PROBES.md).

Дальше:

1. persistent notification queue;
2. Telegram delivery через MAIN SOCKS с fallback на Torrent SOCKS;
3. mute/categories и recovery summary.

До релиза `0.5.0` также должны быть закрыты подтверждённые hardening-задачи:

- persistence Home Gateway через sysupgrade;
- ASATA keeper должен проверять полную семантику nft rule, а не только comment;
- Tailscale/ISP CGNAT overlap остаётся наблюдаемым routing-risk, но текущие table 52 host-routes имеют приоритет перед main.
