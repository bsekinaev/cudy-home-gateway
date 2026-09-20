# Результаты preflight целевого CUDY

Дата: 20–21.09.2026 MSK.

## Целевая платформа

- OpenWrt 25.12.5, kernel 6.12.94;
- архитектура `aarch64_cortex-a53`;
- board string: `Cudy TR3000 256MB v1`;
- ОС сообщает 496724 KiB RAM — это расходится с названием board string, поэтому код не должен выводить объём памяти из имени модели;
- overlay: 190.4 MiB, свободно около 146.3 MiB;
- `/tmp`: свободно около 234.7 MiB.

## Доступный runtime

На целевом роутере уже присутствуют:

- `ash`;
- `curl`;
- `jsonfilter`;
- `uci`;
- `ubus`;
- `nft`;
- `flock`;
- `ucode`;
- `ip`;
- `awk`;
- `sed`;
- `grep`.

Для Foundation и Gateway CLI установка дополнительных тяжёлых runtime не требуется.

## Текущая нагрузка

Контрольный замер:

- load average: `0.01 / 0.08 / 0.12`;
- CPU практически простаивал;
- `MemAvailable`: 268716 KiB (~262.4 MiB);
- swap отсутствует;
- уже работают четыре процесса Xray и `tailscaled`.

### Реальный RSS процессов

| Компонент | RSS |
| --- | ---: |
| Tailscale | 32680 KiB |
| Torrent Xray | 33068 KiB |
| Default Xray | 42424 KiB |
| Redmi ACL Xray | 36284 KiB |
| MAIN SOCKS Xray | 54112 KiB |

Сумма RSS составляет около 193.9 MiB, но это **не** означает 193.9 MiB уникально занятой памяти: процессы могут разделять страницы. Для оценки давления на память главным системным показателем остаётся `MemAvailable`.

Наблюдаемый отдельный Xray использует примерно 33–54 MiB RSS. Поэтому отдельный Management Xray технически выглядит допустимым, но будет вводиться только на этапе Telegram и после повторного замера под нагрузкой. В Foundation дополнительный Xray не запускается.

## Вывод по Telegram runtime

`ucode` уже установлен штатно, поэтому он выбран основным runtime для Telegram orchestration и state machine.

Shell остаётся системным слоем для небольших OpenWrt adapters и аварийным fallback, но Telegram API, callbacks, JSON и состояние не планируется реализовывать одним большим shell-скриптом.

## Management VPN

Требование остаётся прежним: Telegram-трафик не должен выходить DIRECT.

Resource audit показал достаточный запас памяти для дальнейшего эксперимента с отдельным Management Xray. Постоянный процесс пока не создаётся: решение будет проверено canary-запуском на этапе `0.4 Telegram read-only`, после чего повторно сравниваются `MemAvailable`, load и стабильность data plane.

## Передача файлов на OpenWrt

На целевом образе отсутствует `/usr/libexec/sftp-server`, поэтому современный `scp` из Windows по умолчанию завершает передачу ошибкой.

Для deployment используется legacy SCP mode:

```powershell
scp -O <local-file> root@192.168.1.1:<remote-path>
```

Установка SFTP-сервера только ради deployment проекта не требуется.

## IP stack

IPv4 default route использует CGNAT-адрес интерфейса `100.114.142.52`, тогда как фактический публичный direct egress на момент проверки был `95.25.95.131`.

Следствие: Gateway должен различать:

- WAN interface address;
- public direct egress address.

IPv6 default route отсутствует, но присутствует служебный ULA Tailscale `fd7a:115c:a1e0::d39:2360/128`. Поэтому control plane не должен считать отсутствие публичного IPv6 равным полному отсутствию IPv6 в системе.

## Время и расписание

- `ntpd` работает;
- системное время соответствует MSK;
- weekly `vtest` подтверждён cron-записью `0 4 * * 0 /usr/bin/vtest`.

## Проверенная стабильная база

На момент preflight подтверждены:

- MAIN Xray — OK;
- Torrent — OK;
- Tailscale — OK;
- ASATA UDP DIRECT rule — присутствует и имеет ненулевые counters;
- `vtest` — IDLE и доступен;
- SFTP server отсутствует, `scp -O` работает.

Foundation не вносил изменений в data plane.
