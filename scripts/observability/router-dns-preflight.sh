#!/bin/sh
# Read-only discovery. No probes, configuration writes or service operations.
printf 'HG_DNS_DISCOVERY_V1\n'
profile="${1:-acl_A2dNs}"
case "$profile" in ''|*[!a-zA-Z0-9_]*) printf 'profile=invalid\n'; exit 1 ;; esac
printf 'profile=%s\n' "$profile"
version="$(busybox 2>/dev/null | head -n 1)"
version="${version#BusyBox v}"
version="${version%% *}"
case "$version" in ''|*[!0-9.]*) version=unknown ;; esac
printf 'busybox_version=%s\n' "$version"
if busybox nslookup --help 2>&1 | grep -q -- '-type='; then
    printf 'nslookup_A=supported\n'
else
    printf 'nslookup_A=unsupported\n'
fi
if busybox timeout --help 2>&1 | grep -q -- '-k '; then
    printf 'timeout_kill=supported\n'
else
    printf 'timeout_kill=unsupported\n'
fi
if busybox --list 2>/dev/null | grep -qx awk; then
    printf 'busybox_awk=supported\n'
else
    printf 'busybox_awk=unsupported\n'
fi
if command -v uci >/dev/null 2>&1; then
    port="$(uci -q get 'dhcp.@dnsmasq[0].port' 2>/dev/null)"
    case "$port" in
        '') port=53 ;;
        0) port=disabled ;;
        0*|*[!0-9]*) port=invalid ;;
        *) [ "${#port}" -le 5 ] && [ "$port" -le 65535 ] || port=invalid ;;
    esac
    printf 'router_dns_port=%s\n' "$port"
else
    printf 'router_dns_port=unavailable\n'
fi
config="${HG_DNS_PREFLIGHT_CONFIG:-/tmp/etc/passwall2/acl/$profile.json}"
if ! command -v ucode >/dev/null 2>&1 || [ ! -r "$config" ]; then
    printf 'runtime=unreadable_or_unsupported\n'
    printf 'network_changes=none\n'
    exit 0
fi
# Only an allowlisted description leaves the parser. Never print raw JSON/errors.
if ! ucode -e '
    import * as fs from "fs";
    let f = fs.open(ARGV[0], "r");
    if (!f) exit(1);
    let raw = f.read(262145); f.close();
    if (type(raw) != "string" || length(raw) > 262144) exit(1);
    let c;
    try { c = json(raw); } catch (e) { exit(1); }
    if (type(c) != "object" || type(c.inbounds) != "array") exit(1);
    let endpoints = [];
    for (let item in c.inbounds) {
        if (type(item) != "object" || item.tag != "dns-in") continue;
        let port = item.port;
        push(endpoints, {
            port: type(port) == "int" && port > 0 && port <= 65535 ? port : null,
            loopback: item.listen == "127.0.0.1",
            protocol: index([ "dokodemo-door", "tunnel" ], item.protocol) >= 0 ? item.protocol : "unsupported"
        });
    }
    if (length(endpoints) > 16) exit(1);
    print("runtime_dns=", sprintf("%J", endpoints), "\n");
' "$config" 2>/dev/null; then
    printf 'runtime=unreadable_or_unsupported\n'
fi
printf 'network_changes=none\n'
exit 0
