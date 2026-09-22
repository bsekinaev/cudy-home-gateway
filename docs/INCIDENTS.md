# Incident State

Этап `0.5.2` добавляет state machine поверх Health Core.

## Команды

```sh
gateway incidents
gateway incidents --json
gateway incidents tick
```

`tick` выполняет одну read-only health-итерацию и обновляет только состояние control plane. Сетевую конфигурацию команда не меняет.

## Debounce и hysteresis

Incident открывается только после устойчивого состояния:

- `DEGRADED` — 3 последовательных observation;
- `DOWN` — 3 последовательных observation.

Recovery подтверждается после:

- `OK` — 2 последовательных observation.

Переход активного incident между `DEGRADED` и `DOWN` также требует 3 последовательных observation.

`UNKNOWN` и `MAINTENANCE`:

- сами не открывают incident;
- не закрывают уже открытый incident;
- сбрасывают текущий debounce candidate.

Это защищает от кратких probe failures и от ложного recovery при недостатке данных.

## Хранение состояния

Частые debounce counters находятся только в RAM:

```text
/tmp/home-gateway/incidents.runtime.json
/tmp/home-gateway/incidents.lock
```

Confirmed transitions записываются на flash только при событии:

```text
/etc/home-gateway/state/incidents.jsonl
```

Journal является persistent source of truth. Активные incidents восстанавливаются replay'ем событий:

- `OPEN`;
- `STATE_CHANGED`;
- `RECOVERED`.

После reboot transient counters начинаются заново, но уже открытый incident не теряется.

До релиза `0.5.0` каталог `/etc/home-gateway/state` должен быть добавлен в sysupgrade persistence.

## Exit semantics

`gateway incidents tick` возвращает `0`, если state machine успешно обработала observation, даже когда активны incidents.

Наличие неисправности и работоспособность самого Incident Engine — разные понятия.

## External confirmation

Начиная с `0.5.3`, egress adapters используют adaptive confirmation: secondary provider вызывается только после неуспешного primary probe. Incident State получает уже подтверждённую observation и не зависит от конкретного HTTP provider.

Следующий слой — persistent notification queue, подписанная на journal transitions.
