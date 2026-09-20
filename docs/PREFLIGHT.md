# Результаты preflight целевого CUDY

Дата: 20.09.2026 MSK.

## Целевая платформа

- OpenWrt 25.12.5, kernel 6.12.94;
- архитектура `aarch64_cortex-a53`;
- board string: `Cudy TR3000 256MB v1`;
- ОС сообщает 496724 KiB RAM — это расходится с названием board string, поэтому код не должен выводить объём памяти из имени модели;
- overlay: 190.4 MiB, свободно около 146.3 MiB;
- `/tmp`: свободно около 235.1 MiB.

## Доступный runtime

На целевом роутере уже присутствуют:

- `ash`;
- `curl`;
- `jsonfilter`;
- `uci`;
- `ubus`;
- `nft`;
- `flock`;
- `ucode`.

Для Foundation и Gateway CLI установка дополнительных тяжёлых runtime не требуется.

## Текущая нагрузка

Во время замера:

- load average был низким;
- CPU практически простаивал;
- доступно около 269 MiB RAM;
- уже работают четыре процесса Xray и `tailscaled`.

Большие значения VSZ у Xray и Tailscale не следует трактовать как фактическое потребление RAM. Перед добавлением отдельного Management Xray нужно измерить `VmRSS` процессов через `/proc/<pid>/status`.

## Вывод по Telegram runtime

`ucode` уже установлен штатно, поэтому он выбран основным runtime для Telegram orchestration и state machine.

Shell остаётся системным слоем для небольших OpenWrt adapters и аварийным fallback, но Telegram API, callbacks, JSON и состояние не планируется реализовывать одним большим shell-скриптом.

## Management VPN

Требование остаётся прежним: Telegram-трафик не должен выходить DIRECT.

Отдельный постоянный Management Xray пока не создаётся. Перед этим нужно получить реальный RSS существующих Xray/Tailscale и оценить дополнительную стоимость отдельного процесса.

## Передача файлов на OpenWrt

На целевом образе отсутствует `/usr/libexec/sftp-server`, поэтому современный `scp` из Windows по умолчанию завершает передачу ошибкой.

Для deployment используется legacy SCP mode:

```powershell
scp -O <local-file> root@192.168.1.1:<remote-path>
```

Установка SFTP-сервера только ради deployment проекта не требуется.

## IP stack

На устройстве существуют IPv6 listener'ы и служебные IPv6-адреса, даже если публичный IPv6-доступ в текущей сетевой политике не используется.

Следствие: код не должен считать отсутствие публичного IPv6 равным полному отсутствию IPv6 в системе.

## Проверенная стабильная база

На момент preflight подтверждены:

- MAIN Xray — OK;
- Torrent — OK;
- Tailscale — OK;
- ASATA UDP DIRECT rule — присутствует и имеет ненулевые counters;
- `vtest` — IDLE и доступен.

Foundation не вносил изменений в data plane.
