# Health Core

Этап `0.5.1` вводит read-only Health Core поверх существующего Status API.

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

Дальше:

1. adaptive confirmation probes;
2. persistent notification queue;
3. Telegram delivery через MAIN SOCKS с fallback на Torrent SOCKS;
4. mute/categories и recovery summary.

До релиза `0.5.0` также должны быть закрыты подтверждённые hardening-задачи:

- persistence Home Gateway через sysupgrade;
- ASATA keeper должен проверять полную семантику nft rule, а не только comment;
- Tailscale/ISP CGNAT overlap остаётся наблюдаемым routing-risk, но текущие table 52 host-routes имеют приоритет перед main.
