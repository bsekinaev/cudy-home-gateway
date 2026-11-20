#!/bin/sh
# Read-only ╤Б╤В╨░╤В╤Г╤Б Redmi VPN-only policy CUDY Home Gateway.

hg_redmi_is_ipv4() {
    value="$1"

    printf '%s\n' "$value" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
                    exit 1
            }
        }
    '
}

hg_redmi_is_mac() {
    value="$1"

    case "$value" in
        ??\:??\:??\:??\:??\:??)
            oldifs="$IFS"
            IFS=:
            set -- $value
            IFS="$oldifs"

            for octet do
                case "$octet" in
                    [0-9a-fA-F][0-9a-fA-F]) ;;
                    *) return 1 ;;
                esac
            done

            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

hg_redmi_process_running() {
    profile="$1"
    [ -n "$profile" ] || return 1

    config_path="${HG_REDMI_RUNTIME_CONFIG:-/tmp/etc/passwall2/acl/${profile}.json}"
    ps w 2>/dev/null | awk -v config_path="$config_path" '
        ($5 == "xray" || $5 ~ /\/xray$/) && index($0, config_path) { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

hg_redmi_dns_snapshot() {
    # One bounded local task. No raw configuration leaves the parser.
    timeout -k 1 3 sh -s -- \
        "${HG_REDMI_RUNTIME_CONFIG:-/tmp/etc/passwall2/acl/${HG_REDMI_ACL_PROFILE}.json}" \
        "${HG_REDMI_PROC_ROOT:-/proc}" "$HG_REDMI_ACL_PROFILE" <<'HG_REDMI_SNAPSHOT'
config="$1"; proc="$2"; profile="$3"
case "$profile" in ''|*[!a-zA-Z0-9_]*) exit 1 ;; esac
[ -f "$config" ] || exit 1
[ "$(uci -q get "passwall2.$profile.enabled" 2>/dev/null)" = 1 ] || exit 1
node="$(uci -q get "passwall2.$profile.node" 2>/dev/null)" || exit 1
case "$node" in ''|*[!a-zA-Z0-9_]*) exit 1 ;; esac
[ "${#node}" -le 128 ] || exit 1
before="$(sha256sum "$config" 2>/dev/null)" || exit 1
identity="$(ucode -e '
    import * as fs from "fs";
    function read(path, limit) {
        let st = fs.stat(path);
        if (!st || st.type != "file" || st.size > limit) return null;
        let f = fs.open(path, "r");
        if (!f) return null;
        let raw = f.read(limit + 1); f.close();
        return type(raw) == "string" && length(raw) <= limit ? raw : null;
    }
    let raw = read(ARGV[0], 262144), c;
    if (raw == null) exit(1);
    try { c = json(raw); } catch (e) { exit(1); }
    if (type(c) != "object" || type(c.inbounds) != "array") exit(1);
    let endpoints = filter(c.inbounds, i => type(i) == "object" && i.tag == "dns-in");
    if (length(endpoints) != 1) exit(1);
    let endpoint = endpoints[0], port = endpoint.port;
    if (endpoint.listen != "127.0.0.1" || type(port) != "int" || port < 1 || port > 65535) exit(1);
    let networks;
    if (endpoint.protocol == "tunnel") networks = endpoint.settings?.allowedNetwork;
    else if (endpoint.protocol == "dokodemo-door") networks = endpoint.settings?.network;
    else exit(1);
    if (type(networks) != "string" || index(split(networks, ","), "udp") < 0) exit(1);
    let proc = ARGV[1], sockets = [], udp = read(proc + "/net/udp", 262144);
    if (udp == null) exit(1);
    for (let line in split(udp, "\n")) {
        let columns = split(trim(line), /[ \t]+/);
        if (length(columns) > 9 && uc(columns[1]) == sprintf("0100007F:%04X", port)
            && columns[3] == "07") push(sockets, columns[9]);
    }
    if (length(sockets) != 1 || !match(sockets[0], /^[0-9]+$/)) exit(1);
    let commands = fs.glob(proc + "/[0-9]*/cmdline");
    if (type(commands) != "array" || length(commands) > 1024) exit(1);
    let candidates = [];
    for (let path in commands) {
        let cmd = read(path, 8192);
        if (cmd == null) continue;
        let args = split(cmd, "\x00"), config_matches = 0;
        for (let n = 1; n < length(args); n++)
            if (index([ "-c", "-config", "--config" ], args[n-1]) >= 0 && args[n] == ARGV[0]) config_matches++;
        if (config_matches != 1) continue;
        let pid = match(path, /\/([0-9]+)\/cmdline$/)?.[1];
        if (!pid) continue;
        let directory = proc + "/" + pid, exe = fs.readlink(directory + "/exe");
        if (type(exe) != "string" || !match(exe, /\/xray$/)) continue;
        push(candidates, pid);
    }
    if (length(candidates) != 1) exit(1);
    let pid = candidates[0], directory = proc + "/" + pid;
    let fds = fs.glob(directory + "/fd/*"), owned = false;
    if (type(fds) != "array" || length(fds) > 1024) exit(1);
    for (let fd in fds)
        if (fs.readlink(fd) == "socket:[" + sockets[0] + "]") owned = true;
    if (!owned) exit(1);
    let stat = read(directory + "/stat", 4096);
    if (stat == null) exit(1);
    let fields = split(replace(trim(stat), /^.*\) /, ""), /[ \t]+/);
    if (length(fields) <= 19 || !match(fields[19], /^[0-9]+$/)) exit(1);
    print(port, "|", pid, "|", fields[19], "|", sockets[0]);
' "$config" "$proc" 2>/dev/null)" || exit 1
after="$(sha256sum "$config" 2>/dev/null)" || exit 1
[ "$before" = "$after" ] || exit 1
hash="${before%% *}"
case "$hash" in ''|*[!0-9a-f]*) exit 1 ;; esac
[ "${#hash}" = 64 ] || exit 1
printf '%s|%s|%s\n' "$identity" "$hash" "$node"
HG_REDMI_SNAPSHOT
}

hg_redmi_dns_collect() {
    local before after tool
    HG_REDMI_DNS_STATE='UNKNOWN'
    HG_REDMI_DNS_REASON='profile_unavailable'
    HG_REDMI_DNS_PORT=''
    HG_REDMI_DNS_CHECKED_AT=''
    HG_REDMI_DNS_SOURCE='unverified'
    [ "${HG_REDMI_CONFIG_STATE:-UNKNOWN}" = OK ] &&
        [ "${HG_REDMI_XRAY_STATE:-UNKNOWN}" = OK ] || return 0
    HG_REDMI_DNS_REASON='tool_unavailable'
    for tool in timeout ucode uci sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || return 0
    done
    timeout --help 2>&1 | grep -q -- '-k' || return 0
    HG_REDMI_DNS_REASON='runtime_unverified'
    before="$(hg_redmi_dns_snapshot 2>/dev/null)" || return 0
    HG_REDMI_DNS_REASON='runtime_changed'
    [ "${before##*|}" = "${HG_REDMI_NODE:-}" ] || return 0
    HG_REDMI_DNS_PORT="${before%%|*}"
    if ! command -v hg_dns_probe >/dev/null 2>&1; then
        HG_REDMI_DNS_REASON='tool_unavailable'
        return 0
    fi
    hg_dns_probe "${HG_DNS_PROBE_DOMAIN:-openwrt.org}" "$HG_REDMI_DNS_PORT"
    after="$(hg_redmi_dns_snapshot 2>/dev/null)" || return 0
    [ "$before" = "$after" ] || return 0
    HG_REDMI_DNS_STATE="$HG_DNS_PROBE_STATE"
    HG_REDMI_DNS_REASON="$HG_DNS_PROBE_REASON"
    case "$HG_REDMI_DNS_STATE" in
        OK|DOWN)
            HG_REDMI_DNS_CHECKED_AT="$(date +%s 2>/dev/null)"
            HG_REDMI_DNS_SOURCE='live_probe'
            ;;
    esac
}

hg_redmi_collect() {
    HG_REDMI_STATE='UNKNOWN'
    HG_REDMI_CONFIG_STATE='UNKNOWN'
    HG_REDMI_ACL_PROFILE="${HG_REDMI_ACL_PROFILE:-acl_A2dNs}"
    HG_REDMI_ACL_ENABLED='unknown'
    HG_REDMI_REMARK=''
    HG_REDMI_CLIENT_IPV4=''
    HG_REDMI_CLIENT_MAC=''
    HG_REDMI_NODE=''
    HG_REDMI_NAME=''
    HG_REDMI_XRAY_STATE='UNKNOWN'
    HG_REDMI_POLICY_STATE='UNKNOWN'
    HG_REDMI_POLICY_RULES=''
    HG_REDMI_KILLSWITCH_STATE='UNKNOWN'
    HG_REDMI_KILLSWITCH_RULES=''
    HG_REDMI_EGRESS_STATE='UNKNOWN'
    HG_REDMI_EGRESS_IPV4=''
    HG_REDMI_EGRESS_SOURCE='unverified'

    HG_REDMI_DNS_STATE='UNKNOWN'
    HG_REDMI_DNS_REASON='profile_unavailable'
    HG_REDMI_DNS_PORT=''
    HG_REDMI_DNS_CHECKED_AT=''
    HG_REDMI_DNS_SOURCE='unverified'
    if ! command -v uci >/dev/null 2>&1; then
        return 0
    fi

    acl_type="$(uci -q get "passwall2.${HG_REDMI_ACL_PROFILE}" 2>/dev/null || true)"
    acl_enabled="$(uci -q get "passwall2.${HG_REDMI_ACL_PROFILE}.enabled" 2>/dev/null || true)"
    HG_REDMI_REMARK="$(uci -q get "passwall2.${HG_REDMI_ACL_PROFILE}.remarks" 2>/dev/null || true)"
    acl_sources="$(uci -q get "passwall2.${HG_REDMI_ACL_PROFILE}.sources" 2>/dev/null || true)"
    HG_REDMI_NODE="$(uci -q get "passwall2.${HG_REDMI_ACL_PROFILE}.node" 2>/dev/null || true)"

    case "$acl_enabled" in
        1) HG_REDMI_ACL_ENABLED='true' ;;
        0) HG_REDMI_ACL_ENABLED='false' ;;
    esac

    for source in $acl_sources; do
        if [ -z "$HG_REDMI_CLIENT_IPV4" ] && hg_redmi_is_ipv4 "$source"; then
            HG_REDMI_CLIENT_IPV4="$source"
        elif [ -z "$HG_REDMI_CLIENT_MAC" ] && hg_redmi_is_mac "$source"; then
            HG_REDMI_CLIENT_MAC="$(printf '%s' "$source" | tr 'A-F' 'a-f')"
        fi
    done

    if [ -n "$HG_REDMI_NODE" ]; then
        HG_REDMI_NAME="$(uci -q get "passwall2.${HG_REDMI_NODE}.remarks" 2>/dev/null || true)"
    fi

    if [ "$HG_REDMI_ACL_ENABLED" = 'false' ]; then
        HG_REDMI_CONFIG_STATE='DOWN'
    elif [ "$acl_type" = 'acl_rule' ] && \
         [ "$HG_REDMI_ACL_ENABLED" = 'true' ] && \
         [ -n "$HG_REDMI_REMARK" ] && \
         [ -n "$HG_REDMI_NODE" ] && \
         hg_redmi_is_ipv4 "$HG_REDMI_CLIENT_IPV4" && \
         hg_redmi_is_mac "$HG_REDMI_CLIENT_MAC"; then
        HG_REDMI_CONFIG_STATE='OK'
    elif [ -n "$acl_type" ]; then
        HG_REDMI_CONFIG_STATE='DEGRADED'
    fi

    case "$HG_REDMI_CONFIG_STATE" in
        OK)
            if hg_redmi_process_running "$HG_REDMI_ACL_PROFILE"; then
                HG_REDMI_XRAY_STATE='OK'
            else
                HG_REDMI_XRAY_STATE='DOWN'
            fi
            ;;
        DOWN)
            HG_REDMI_XRAY_STATE='DOWN'
            ;;
    esac

    if command -v nft >/dev/null 2>&1 && [ -n "$HG_REDMI_REMARK" ]; then
        HG_REDMI_POLICY_RULES="$(
            nft -a list table inet passwall2 2>/dev/null |
                awk -v remark="$HG_REDMI_REMARK" -v ip="$HG_REDMI_CLIENT_IPV4" -v mac="$HG_REDMI_CLIENT_MAC" '
                    index($0, remark) && ((ip != "" && index($0, ip)) || (mac != "" && index(tolower($0), tolower(mac)))) { count++ }
                    END { print count + 0 }
                '
        )"

        case "$HG_REDMI_POLICY_RULES" in
            ''|*[!0-9]*) HG_REDMI_POLICY_RULES='' ;;
            0) HG_REDMI_POLICY_STATE='DOWN' ;;
            *) HG_REDMI_POLICY_STATE='OK' ;;
        esac
    fi

    killswitch_comment="${HG_REDMI_KILLSWITCH_COMMENT:-Redmi VPN Kill-Switch}"
    if command -v nft >/dev/null 2>&1 && [ -n "$HG_REDMI_CLIENT_IPV4" ]; then
        HG_REDMI_KILLSWITCH_RULES="$(
            nft -a list chain inet fw4 forward_lan 2>/dev/null |
                awk -v ip="$HG_REDMI_CLIENT_IPV4" -v comment="$killswitch_comment" '
                    index($0, "ip saddr " ip) && index($0, comment) && index($0, "reject_to_wan") { count++ }
                    END { print count + 0 }
                '
        )"

        case "$HG_REDMI_KILLSWITCH_RULES" in
            ''|*[!0-9]*) HG_REDMI_KILLSWITCH_RULES='' ;;
            0) HG_REDMI_KILLSWITCH_STATE='DOWN' ;;
            *) HG_REDMI_KILLSWITCH_STATE='OK' ;;
        esac
    fi

    # ╨г ACL ╨╜╨╡╤В ╨╛╤В╨┤╨╡╨╗╤М╨╜╨╛╨│╨╛ SOCKS endpoint, ╨┐╨╛╤Н╤В╨╛╨╝╤Г egress ╤Б ╤А╨╛╤Г╤В╨╡╤А╨░
    # ╨▒╨╡╨╖╨╛╨┐╨░╤Б╨╜╨╛ ╨╜╨╡ ╨┐╨╛╨┤╨╝╨╡╨╜╤П╨╡╨╝ egress'╨╛╨╝ MAIN ╨╕ ╨╛╤Б╤В╨░╨▓╨╗╤П╨╡╨╝ UNKNOWN.
    case "$HG_REDMI_CONFIG_STATE" in
        DOWN)
            HG_REDMI_STATE='DOWN'
            ;;
        DEGRADED)
            HG_REDMI_STATE='DEGRADED'
            ;;
        OK)
            if [ "$HG_REDMI_XRAY_STATE" = 'DOWN' ] || [ "$HG_REDMI_POLICY_STATE" = 'DOWN' ]; then
                HG_REDMI_STATE='DOWN'
            elif [ "$HG_REDMI_XRAY_STATE" = 'OK' ] && \
                 [ "$HG_REDMI_POLICY_STATE" = 'OK' ] && \
                 [ "$HG_REDMI_KILLSWITCH_STATE" = 'OK' ]; then
                HG_REDMI_STATE='OK'
            elif [ "$HG_REDMI_XRAY_STATE" = 'OK' ]; then
                HG_REDMI_STATE='DEGRADED'
            fi
            ;;
    esac
    hg_redmi_dns_collect
    if [ "$HG_REDMI_STATE" = OK ] && [ "$HG_REDMI_DNS_STATE" != OK ]; then
        HG_REDMI_STATE='DEGRADED'
    fi
}
