# Архитектура CUDY Home Gateway

## Граница ответственности

Проект разделён на два слоя:

* **Data Plane** — существующие PassWall2/Xray, nftables, DNS, Tailscale и пользовательские политики. Проект не должен становиться обязательным условием их работы.
* **Control Plane** — CLI `gateway`, health engine, Telegram UI, уведомления, журналирование и безопасные действия.

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

* `OK`
* `DEGRADED`
* `DOWN`
* `UNKNOWN`
* `MAINTENANCE`

`DEGRADED` используется, когда основной путь неисправен, но сервис продолжает работать через резервный механизм. `MAINTENANCE` подавляет ложные аварии во время подтверждённого управляющего действия.

## Инварианты

1. Configured MAIN и фактический egress — разные сущности.
2. Внешний egress определяется фактически, а активная fallback-нода указывается только при надёжном сопоставлении.
3. Никакое решение `vtest` не меняет MAIN автоматически.
4. Любое изменение MAIN проходит preflight, snapshot, apply, post-check и commit/rollback.
5. Параллельные конфликтующие операции запрещены locks-механизмом.
6. Незавершённые транзакции восстанавливаются после crash/reboot через transaction journal.
7. Telegram callbacks имеют TTL, nonce и проверку user/chat; старые updates не исполняются.

## Health Alert Pipeline

Система контроля состояния разделена на несколько уровней.

### Health Core

Отвечает за:

* сбор наблюдений;
* нормализацию состояния компонентов;
* формирование health snapshot.

### Incident Engine

Отвечает за:

* применение debounce/hysteresis;
* создание lifecycle событий;
* хранение журнала incidents;
* определение переходов OPEN, STATE_CHANGED и RECOVERED.

### Notification Projection

Отвечает за:

* преобразование incident events в уведомления;
* создание независимого слоя между состоянием системы и каналом доставки;
* подготовку событий для дальнейшей обработки.

### Notification Queue

Отвечает за:

* хранение pending notifications;
* отделение событий от механизмов доставки;
* возможность повторной обработки и подключения разных delivery adapters.

Такой подход не связывает Incident Engine напрямую с Telegram или другим транспортом уведомлений.

## Поток обработки

```text
Health Core
      |
      v
Incident Engine
      |
      v
Notification Projection
      |
      v
Notification Queue
      |
      v
Delivery adapters
```

Каждый следующий слой зависит только от предыдущего и не изменяет состояние нижнего уровня без явного управляющего действия.
