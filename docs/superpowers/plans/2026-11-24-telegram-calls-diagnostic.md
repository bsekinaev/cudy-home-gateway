# Диагностика звонков Telegram через CUDY

**Goal:** Выяснить, почему звонки зависают на подключении через шлюз, но работают с VPN на устройстве из той же подписки.

**Architecture:** Отдельный owner-run probe, без установки runtime и без сетевых изменений. Читает только выбранные UCI-параметры UDP, безопасную проекцию generated Xray JSON, количество правил перехвата/маркировки и наличие ASATA bypass. Пароли, адреса, MAC, UUID, ключи, имена узлов и полные конфигурации не экспортируются. Проверка actual call остаётся UNVERIFIED до отдельного теста владельца.

**Context:** Владелец 24.11 подтвердил: затронуты ASATA, REDMI и другие устройства; вызов зависает на соединении; VPN на устройстве из той же подписки помогает. Прямое правило ASATA не объясняет проблему всех устройств. /status и web/Telegram messages не доказывают media path.

**Sources:** [Telegram calls](https://core.telegram.org/api/calls), [PassWall2 UDP redirection](https://github.com/Openwrt-Passwall/openwrt-passwall2/blob/main/luci-app-passwall2/root/usr/share/passwall2/nftables.sh). Проверяем установленную конфигурацию, не переносим автоматически defaults из latest.

## Plan

- [x] RED/GREEN collector tests: глобальные ограничения UDP, конфиги SOCKS/transparent, broad UDP direct rules, unknown/malformed/oversize, privacy и отсутствие writes.
- [x] Source-bound package с проверкой SHA/source/schema, Windows stdin framing и явным exit после heredoc.
- [ ] Offline Linux, native Windows fake-SSH, независимый review, проверка состава ZIP.
- [ ] Владелец запускает пакет и присылает безопасный отчёт. Агент к CUDY не подключается.
- [ ] По фактам выбрать конкретную правку; не отключать Kill Switch REDMI и не заменять правила ASATA без доказательств и согласования эффекта.

WAN route formatter fix 1472f35 сохранён отдельно. На CUDY остаётся runtime 1fc822c; ни диагностика, ни изменения этого плана его не обновляют.

## Проверки перед передачей

Независимый review выявил неверный учёт nft match.op!='==' и пропуск network
"tcp,udp" у broad direct. Оба случая воспроизведены RED и исправлены GREEN;
повторный review подтвердил исправления. Отсутствие UCI-ключа не отличимо от
ошибки чтения в этом минимальном probe и потому даёт UNKNOWN, не INHERIT.
Конфиги проверяются на принадлежность текущему UID (на CUDY root), отсутствие
symlink и group/other-write. Отдельный запуск tests под UID 1000 проверил этот
контракт без фиктивного разрешения небезопасных файлов.
