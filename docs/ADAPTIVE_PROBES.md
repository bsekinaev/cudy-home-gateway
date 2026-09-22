# Adaptive External Probes

Этап `0.5.3` делает внешнее подтверждение egress адаптивным.

## Алгоритм

Для Direct, MAIN и Torrent действует одинаковая схема:

1. если cache свежее TTL — внешний запрос не выполняется;
2. если cache отсутствует или истёк — выполняется primary probe;
3. только если primary probe не подтвердил валидный IPv4 — выполняется secondary probe;
4. только после провала обоих providers внешний egress становится `UNKNOWN`;
5. локальный отказ (например, MAIN Xray `DOWN`) не вызывает лишние внешние probes.

По умолчанию:

```text
primary   = https://api.ipify.org
secondary = https://ipv4.icanhazip.com/
TTL       = 300s
```

Secondary provider используется как confirmation path, а не как дополнительный постоянный polling.

## Cache provenance

Формат cache расширен обратно совместимо:

```text
<checked_at> <ipv4> [provider]
```

Старые cache-файлы с двумя полями продолжают читаться.

## Observability

Status/Health JSON выводит `probe_attempts`.

Health дополнительно выводит успешный/cached `provider` и `secondary_attempted`.

`secondary_attempted=true` означает, что primary не подтвердил egress и был вызван secondary provider. Это не означает, что secondary обязательно завершился успешно.

Семантика:

- `0` — использован cache или probe не запускался;
- `1` — выполнен primary probe;
- `2` — primary не подтвердил egress, выполнен secondary confirmation.

## Диагностические overrides

Direct:

- `HG_EGRESS_PROBE_URL`
- `HG_EGRESS_PROVIDER`
- `HG_EGRESS_SECONDARY_PROBE_URL`
- `HG_EGRESS_SECONDARY_PROVIDER`

MAIN:

- `HG_MAIN_EGRESS_PROBE_URL`
- `HG_MAIN_EGRESS_PROVIDER`
- `HG_MAIN_EGRESS_SECONDARY_PROBE_URL`
- `HG_MAIN_EGRESS_SECONDARY_PROVIDER`

Torrent:

- `HG_TORRENT_EGRESS_PROBE_URL`
- `HG_TORRENT_EGRESS_PROVIDER`
- `HG_TORRENT_EGRESS_SECONDARY_PROBE_URL`
- `HG_TORRENT_EGRESS_SECONDARY_PROVIDER`

Overrides не изменяют data plane.
