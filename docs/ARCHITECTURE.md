# Архитектура CUDY Home Gateway

## Граница ответственности

Проект разделён на два слоя:

- **Data Plane** — существующие PassWall2/Xray, nftables, DNS, Tailscale и пользовательские политики. Проект не должен становиться обязательным условием их работы.
- **Control Plane** — CLI `gateway`, health engine, Telegram UI, уведомления, журналирование и безопасные действия.

Сбой Control Plane должен приводить максимум к потере наблюдаемости и удалённого управления через Telegram, но не к потере сетевой связности.

## Целевая схема

```text
Telegram
   |
   v
Telegram UI / polling
   |
   v
Gateway API / CLI
   +-- Status Engine
   +-- Health Engine
   +-- Action Manager
   +-- Transaction Journal
   +-- Notification Engine
   |
   v
OpenWrt adapters
   +-- PassWall2 / Xray
   +-- nftables
   +-- dnsmasq / AdBlock
   +-- Tailscale
   +-- vtest
   +-- backup
```

## Состояния компонентов

Каждый наблюдаемый компонент возвращает одно из состояний:

- `OK`
- `DEGRADED`
- `DOWN`
- `UNKNOWN`
- `MAINTENANCE`

`DEGRADED` используется, когда основной путь неисправен, но сервис продолжает работать через резервный механизм. `MAINTENANCE` подавляет ложные аварии во время подтверждённого управляющего действия.

## Инварианты

1. Configured MAIN и фактический egress — разные сущности.
2. Внешний egress определяется фактически, а активная fallback-нода указывается только при надёжном сопоставлении.
3. Никакое решение `vtest` не меняет MAIN автоматически.
4. Любое изменение MAIN проходит preflight, snapshot, apply, post-check и commit/rollback.
5. Параллельные конфликтующие операции запрещены locks-механизмом.
6. Незавершённые транзакции восстанавливаются после crash/reboot через transaction journal.
7. Telegram callbacks имеют TTL, nonce и проверку user/chat; старые updates не исполняются.
