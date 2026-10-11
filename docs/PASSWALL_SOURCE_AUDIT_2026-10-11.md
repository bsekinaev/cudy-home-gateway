# Аудит приватных источников PassWall2 — 11 октября 2026

Копии владельца прочитаны, не выполнялись. Все 7 shell originals проходят
BusyBox 1.36.1 ash -n; 15 исходных manifest entries SHA256 проверены, отдельно
проверены 4 новых helper hashes. Public Git содержит только выводы/собственный код,
оригиналы и исторические артефакты остаются приватными.

| Источник | SHA256 копии | Target подтверждение |
|---|---|---|
| app.sh | dbccf6042e377b6bbcc9d1efe7bf2f98381ce5c5709f8c5d883d8609773faafe | ожидает владельца |
| utils.sh | 7c4bfe41b4fd9ac3c9aab6762593152a889a6aa39fb572457b36821594d71a29 | ожидает владельца |
| passwall2 init | 2f05878dde6bf5eb44b432f2c67f1a888447d6247241edef259abf8169c8a96d | ожидает владельца |
| sysupgrade | a24e6fec8f95643736e2b67844621f72e5f57339c5a3cfc07541f750f09d1c29 | ожидает владельца |

app run_socks принимает eval parameters, sourced utils переопределяет TMP_PATH
на shared PassWall runtime. NO_REC_PROCESS не создаёт isolated namespace или
ownership. ln_run возвращает после asynchronous exec, не возвращает durable
receipt. config_file substring check не является безопасной проверкой subtree.
no_run для Xray/sing-box подавляет непосредственный ln_run, но пишет JSON и вызывает
Lua generator; сами util_xray.lua/util_sing-box.lua/luci API не предоставлены.
У прочих типов возможны plugin/subprocess/direct_node_list side effects.

App startup читает UCI и выбирает binaries ещё до command dispatch. get_direct_dns
читает global DNS и использует Lua API. Нельзя считать run_socks/no_run чистыми
функциями или запускать их на workstation без target dependencies. Broad provider
cleanup по command substring/PID file не доказывает ownership и не используется.
Native primitive в VTEST.md создаёт отдельную основу, не включает provider.

PassWall init restart выполняет общий stop/start. App stop убивает процессы по
общим шаблонам, чистит runtime/locks и может затронуть DNS/netfilter. Для 0.8 нужны
coordinated writers, private snapshot/journal, isolated candidate probe и independent
postcheck/rollback; read-only planner не является successful preflight. ASATA repair
остаётся fail closed до координации всех writers, simple reread не atomic CAS.

Sysupgrade restore fallback извлекает tar в /. Ни sysupgrade -r, ни native backup
не считаются транзакционным Gateway restore. Installed hooks/owner inventory и
LAN recovery проверяются отдельно. Owner approval требуется для всех LIVE writes.

Исторические CD bundle/stderr предоставлены, но exact target staging bytes/ash
version не доказаны. Нельзя выводить root cause из копии release redmi.sh или
объявлять исправленный current tree доказательством старого failure.

Historical release redmi.sh действительно имеет 6248 bytes и SHA256
b6086de06a791e4e519e549f5a9768dd6497aadb91c9af63214d890c2ae76211.
BusyBox 1.36.1 ash -n на этом release member PASS; это не подтверждает exact
staging bytes или target ash. Ошибка CD остаётся target evidence BLOCKED.
