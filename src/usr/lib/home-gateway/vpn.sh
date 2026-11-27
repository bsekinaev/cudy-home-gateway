#!/bin/sh
# Read-only статус MAIN VPN CUDY Home Gateway.

hg_vpn_is_ipv4() {
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

hg_vpn_main_process_running() {
    profile="$1"
    [ -n "$profile" ] || return 1

    config_path="/tmp/etc/passwall2/${profile}.json"
    ps w 2>/dev/null | awk -v config_path="$config_path" '
        index($0, "xray") && index($0, config_path) { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

hg_vpn_collect() {
    HG_VPN_PASSWALL_ENABLED='unknown'
    HG_VPN_MAIN_STATE='UNKNOWN'
    HG_VPN_MAIN_CONFIG_STATE='UNKNOWN'
    HG_VPN_MAIN_PROFILE=''
    HG_VPN_MAIN_PROFILE_ENABLED='unknown'
    HG_VPN_MAIN_NODE=''
    HG_VPN_MAIN_NAME=''
    HG_VPN_ACTIVE_NAME=''
    HG_VPN_MAIN_SOCKS_HOST="${HG_MAIN_SOCKS_HOST:-127.0.0.1}"
    HG_VPN_MAIN_SOCKS_PORT=''
    HG_VPN_MAIN_XRAY_STATE='UNKNOWN'
    HG_VPN_AUTOSWITCH_ENABLED='unknown'
    HG_VPN_BACKUP_NODES=''
    HG_VPN_ACTIVE_NODE=''
    HG_VPN_ACTIVE_NODE_STATE='UNKNOWN'
    HG_VPN_EGRESS_STATE='UNKNOWN'
    HG_VPN_EGRESS_IPV4=''
    HG_VPN_EGRESS_SOURCE='live_probe'
    primary_provider="${HG_MAIN_EGRESS_PROVIDER:-api.ipify.org}"
    secondary_provider="${HG_MAIN_EGRESS_SECONDARY_PROVIDER:-ipv4.icanhazip.com}"
    HG_VPN_EGRESS_PROVIDER=''
    HG_VPN_EGRESS_CHECKED_AT=''
    HG_VPN_EGRESS_PROBE_ATTEMPTS='0'

    probe_timeout=6
    [ "${HG_MONITOR_ACTIVE:-0}" != 1 ] || probe_timeout=4
    egress_cache_file="${HG_MAIN_EGRESS_CACHE_FILE:-/tmp/home-gateway-main-egress.cache}"
    egress_cache_ttl="${HG_MAIN_EGRESS_CACHE_TTL:-300}"
    egress_probe_url="${HG_MAIN_EGRESS_PROBE_URL:-https://api.ipify.org}"
    secondary_probe_url="${HG_MAIN_EGRESS_SECONDARY_PROBE_URL:-https://ipv4.icanhazip.com/}"

    case "$egress_cache_ttl" in
        ''|*[!0-9]*) egress_cache_ttl=300 ;;
    esac

    if ! command -v uci >/dev/null 2>&1; then
        return 0
    fi

    passwall_enabled="$(uci -q get 'passwall2.@global[0].enabled' 2>/dev/null || true)"
    case "$passwall_enabled" in
        1) HG_VPN_PASSWALL_ENABLED='true' ;;
        0) HG_VPN_PASSWALL_ENABLED='false' ;;
    esac

    HG_VPN_MAIN_PROFILE="$(uci -q get passwall2.rulenode.default_node 2>/dev/null || true)"

    if [ -n "$HG_VPN_MAIN_PROFILE" ]; then
        profile_type="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}" 2>/dev/null || true)"
        profile_enabled="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.enabled" 2>/dev/null || true)"
        HG_VPN_MAIN_NODE="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.node" 2>/dev/null || true)"
        HG_VPN_MAIN_SOCKS_PORT="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.port" 2>/dev/null || true)"
        autoswitch_enabled="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.enable_autoswitch" 2>/dev/null || true)"
        HG_VPN_BACKUP_NODES="$(uci -q get "passwall2.${HG_VPN_MAIN_PROFILE}.autoswitch_backup_node" 2>/dev/null || true)"

        case "$profile_enabled" in
            1) HG_VPN_MAIN_PROFILE_ENABLED='true' ;;
            0) HG_VPN_MAIN_PROFILE_ENABLED='false' ;;
        esac
        case "$autoswitch_enabled" in
            1) HG_VPN_AUTOSWITCH_ENABLED='true' ;;
            0) HG_VPN_AUTOSWITCH_ENABLED='false' ;;
        esac

        if [ -n "$HG_VPN_MAIN_NODE" ]; then
            HG_VPN_MAIN_NAME="$(uci -q get "passwall2.${HG_VPN_MAIN_NODE}.remarks" 2>/dev/null || true)"
        fi

        case "$HG_VPN_MAIN_SOCKS_PORT" in
            ''|*[!0-9]*) port_valid='false' ;;
            *) port_valid='true' ;;
        esac

        if [ "$HG_VPN_PASSWALL_ENABLED" = 'false' ] || [ "$HG_VPN_MAIN_PROFILE_ENABLED" = 'false' ]; then
            HG_VPN_MAIN_CONFIG_STATE='DOWN'
        elif [ "$HG_VPN_PASSWALL_ENABLED" = 'true' ] && \
             [ "$profile_type" = 'socks' ] && \
             [ "$HG_VPN_MAIN_PROFILE_ENABLED" = 'true' ] && \
             [ -n "$HG_VPN_MAIN_NODE" ] && \
             [ "$port_valid" = 'true' ]; then
            HG_VPN_MAIN_CONFIG_STATE='OK'
        elif [ "$HG_VPN_PASSWALL_ENABLED" = 'true' ]; then
            HG_VPN_MAIN_CONFIG_STATE='DEGRADED'
        fi
    elif [ "$HG_VPN_PASSWALL_ENABLED" = 'false' ]; then
        HG_VPN_MAIN_CONFIG_STATE='DOWN'
    fi

    case "$HG_VPN_MAIN_CONFIG_STATE" in
        OK)
            if hg_vpn_main_process_running "$HG_VPN_MAIN_PROFILE"; then
                HG_VPN_MAIN_XRAY_STATE='OK'
                if [ "$HG_VPN_MAIN_PROFILE" = socks_P8ART ] && [ -r /tmp/etc/passwall2/var ]; then
                    observed="$(awk '/^socks_P8ART="[a-zA-Z0-9_]+"$/ { split($0, fields, "\""); node=fields[2] } END { print node }' /tmp/etc/passwall2/var 2>/dev/null)" || observed=''
                    if [ -n "$observed" ] && [ "${#observed}" -le 64 ] &&
                        [ "$(uci -q get "passwall2.$observed" 2>/dev/null || true)" = nodes ]; then
                        HG_VPN_ACTIVE_NODE="$observed"
                        HG_VPN_ACTIVE_NODE_STATE='OK'
                        HG_VPN_ACTIVE_NAME="$(uci -q get "passwall2.$observed.remarks" 2>/dev/null || true)"
                    fi
                fi
            else
                HG_VPN_MAIN_XRAY_STATE='DOWN'
            fi
            ;;
        DOWN)
            HG_VPN_MAIN_XRAY_STATE='DOWN'
            ;;
    esac

    now="$(date '+%s' 2>/dev/null || true)"
    case "$now" in
        ''|*[!0-9]*) now='' ;;
    esac

    # Reuse only evidence tied to this WAN and the generated SOCKS config.
    vpn_cache_context=''
    vpn_wan_context="${HG_NETWORK_PATH_CONTEXT:-}"
    case "$HG_VPN_MAIN_PROFILE" in
        ''|*[!A-Za-z0-9_-]*) ;;
        *)
            vpn_config="${HG_MONITOR_GENERATED_DIR:-/tmp/etc/passwall2}/${HG_VPN_MAIN_PROFILE}.json"
            if [ "${#vpn_wan_context}" = 64 ] && [ -f "$vpn_config" ] && [ ! -L "$vpn_config" ]; then
                vpn_config_hash="$(sha256sum "$vpn_config" 2>/dev/null | awk '{print $1}')"
                if [ "${#vpn_config_hash}" = 64 ]; then
                    vpn_cache_context="$(printf '%s\n' "$HG_NETWORK_PATH_CONTEXT" "$vpn_config_hash" "$HG_VPN_MAIN_PROFILE" "$HG_VPN_MAIN_NODE" "$HG_VPN_ACTIVE_NODE" "$HG_VPN_MAIN_SOCKS_HOST" "$HG_VPN_MAIN_SOCKS_PORT" "$egress_probe_url" "$secondary_probe_url" "$primary_provider" "$secondary_provider" | sha256sum | awk '{print $1}')"
                fi
            fi
            ;;
    esac
    cache_checked_at=''
    cache_ipv4=''
    cache_provider=''
    if [ -r "$egress_cache_file" ]; then
        set -- $(awk 'NR == 1 && NF == 4 { print $1, $2, $3, $4; exit }' "$egress_cache_file" 2>/dev/null || true)
        cache_checked_at="${1:-}"
        cache_ipv4="${2:-}"
        cache_provider="${3:-}"

        case "$cache_checked_at" in
            ''|*[!0-9]*) cache_checked_at='' ;;
        esac
        if [ -z "$vpn_cache_context" ] || [ "${4:-}" != "$vpn_cache_context" ] || ! hg_vpn_is_ipv4 "$cache_ipv4"; then
            cache_ipv4=''
            cache_provider=''
        fi
    fi

    if [ "$HG_VPN_MAIN_XRAY_STATE" != 'OK' ]; then
        if [ -n "$cache_ipv4" ]; then
            HG_VPN_EGRESS_IPV4="$cache_ipv4"
            HG_VPN_EGRESS_SOURCE='stale_cache'
            HG_VPN_EGRESS_CHECKED_AT="$cache_checked_at"
            HG_VPN_EGRESS_PROVIDER="$cache_provider"
        fi
        if [ "$HG_VPN_MAIN_XRAY_STATE" = 'DOWN' ]; then
            HG_VPN_EGRESS_STATE='DOWN'
            HG_VPN_MAIN_STATE='DOWN'
        fi
        return 0
    fi

    if [ -n "$now" ] && [ -n "$cache_checked_at" ] && [ -n "$cache_ipv4" ]; then
        cache_age=$((now - cache_checked_at))
        if [ "$cache_age" -ge 0 ] && [ "$cache_age" -lt "$egress_cache_ttl" ]; then
            HG_VPN_EGRESS_STATE='OK'
            HG_VPN_EGRESS_IPV4="$cache_ipv4"
            HG_VPN_EGRESS_SOURCE='cache'
            HG_VPN_EGRESS_CHECKED_AT="$cache_checked_at"
            HG_VPN_EGRESS_PROVIDER="$cache_provider"
            HG_VPN_MAIN_STATE='OK'
            return 0
        fi
    fi

    HG_VPN_EGRESS_CHECKED_AT="$now"

    if command -v curl >/dev/null 2>&1 && [ -n "$HG_VPN_MAIN_SOCKS_PORT" ]; then
        HG_VPN_EGRESS_PROBE_ATTEMPTS='1'
        vpn_ipv4="$(
            curl -4 -fsS \
                --socks5-hostname "${HG_VPN_MAIN_SOCKS_HOST}:${HG_VPN_MAIN_SOCKS_PORT}" \
                --connect-timeout 2 \
                --max-time "$probe_timeout" \
                "$egress_probe_url" 2>/dev/null |
                awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
        )"

        if hg_vpn_is_ipv4 "$vpn_ipv4"; then
            HG_VPN_EGRESS_IPV4="$vpn_ipv4"
            HG_VPN_EGRESS_SOURCE='live_probe'
            HG_VPN_EGRESS_PROVIDER="$primary_provider"
            HG_VPN_EGRESS_STATE='OK'
            HG_VPN_MAIN_STATE='OK'

            if [ -n "$now" ] && [ -n "$vpn_cache_context" ]; then
                printf '%s %s %s %s\n' "$now" "$vpn_ipv4" "$primary_provider" "$vpn_cache_context" >"$egress_cache_file" 2>/dev/null || true
            fi
            return 0
        fi

        if [ -n "$secondary_probe_url" ] && [ "$secondary_probe_url" != "$egress_probe_url" ]; then
            HG_VPN_EGRESS_PROBE_ATTEMPTS='2'
            vpn_ipv4="$(
                curl -4 -fsS \
                    --socks5-hostname "${HG_VPN_MAIN_SOCKS_HOST}:${HG_VPN_MAIN_SOCKS_PORT}" \
                    --connect-timeout 2 \
                    --max-time "$probe_timeout" \
                    "$secondary_probe_url" 2>/dev/null |
                    awk 'NR == 1 { gsub(/[[:space:]]/, ""); print; exit }' || true
            )"

            if hg_vpn_is_ipv4 "$vpn_ipv4"; then
                HG_VPN_EGRESS_IPV4="$vpn_ipv4"
                HG_VPN_EGRESS_SOURCE='live_probe'
                HG_VPN_EGRESS_PROVIDER="$secondary_provider"
                HG_VPN_EGRESS_STATE='OK'
                HG_VPN_MAIN_STATE='OK'

                if [ -n "$now" ] && [ -n "$vpn_cache_context" ]; then
                    printf '%s %s %s %s\n' "$now" "$vpn_ipv4" "$secondary_provider" "$vpn_cache_context" >"$egress_cache_file" 2>/dev/null || true
                fi
                return 0
            fi
        fi
    fi

    if [ -n "$cache_ipv4" ]; then
        HG_VPN_EGRESS_IPV4="$cache_ipv4"
        HG_VPN_EGRESS_SOURCE='stale_cache'
        HG_VPN_EGRESS_CHECKED_AT="$cache_checked_at"
        HG_VPN_EGRESS_PROVIDER="$cache_provider"
    fi

    # Локальный Xray работает, но внешний путь не удалось подтвердить.
    HG_VPN_EGRESS_STATE='UNKNOWN'
    HG_VPN_MAIN_STATE='DEGRADED'
}

# Stage 0.8 read-only planning boundary. This is not a candidate network preflight.
# The private PassWall helper contract and writer coordination must be audited
# before any MAIN mutation can be implemented. No UCI set/commit or restart here.
hg_main_transaction_plan() (
    candidate="$1"
    case "$candidate" in ''|*[!a-zA-Z0-9_]* )
        printf '{"schema_version":1,"status":"INVALID_CANDIDATE","apply_supported":false}\n'
        exit 2 ;;
    esac
    [ "${#candidate}" -le 64 ] || {
        printf '{"schema_version":1,"status":"INVALID_CANDIDATE","apply_supported":false}\n'
        exit 2
    }
    set -o pipefail
    hg_main_plan_blocked() {
        printf '{"schema_version":1,"status":"%s","apply_supported":false,"preflight_passed":false,"snapshot_ready":false}\n' "$1"
        exit 70
    }
    # Each observation is bounded and private; neither config nor node IDs are
    # returned. Independent reads are explicitly not a transaction snapshot.
    hg_main_plan_get() {
        # Sentinel preserves LF bytes across command substitution so truncation
        # cannot turn an oversized multiline value into a valid short scalar.
        value="$(timeout -k 1 5 uci -q get "$1" 2>/dev/null | head -c 66
            read_rc="$?"
            [ "$read_rc" -eq 0 ] || exit 1
            printf '.')" || return 1
        value="${value%?}"
        [ "${#value}" -le 65 ] || return 1
        newline="$(printf '\n.')"; newline="${newline%.}"
        case "$value" in *"$newline") value="${value%"$newline"}" ;; *) return 1 ;; esac
        case "$value" in *"$newline"*) return 1 ;; esac
        printf '%s' "$value"
    }
    command -v uci >/dev/null 2>&1 || hg_main_plan_blocked UCI_UNAVAILABLE
    pending="$(timeout -k 1 5 uci -q changes passwall2 2>/dev/null | head -c 65)" || hg_main_plan_blocked UCI_READ_FAILED
    [ -z "$pending" ] || hg_main_plan_blocked UNCOMMITTED_CONFIG
    enabled="$(hg_main_plan_get 'passwall2.@global[0].enabled')" || hg_main_plan_blocked UCI_READ_FAILED
    profile="$(hg_main_plan_get passwall2.rulenode.default_node)" || hg_main_plan_blocked UCI_READ_FAILED
    [ "$enabled" = 1 ] && [ "$profile" = socks_P8ART ] || hg_main_plan_blocked UNSUPPORTED_MAIN_PROFILE
    profile_type="$(hg_main_plan_get passwall2.socks_P8ART)" || hg_main_plan_blocked UCI_READ_FAILED
    active="$(hg_main_plan_get passwall2.socks_P8ART.enabled)" || hg_main_plan_blocked UCI_READ_FAILED
    port="$(hg_main_plan_get passwall2.socks_P8ART.port)" || hg_main_plan_blocked UCI_READ_FAILED
    [ "$profile_type" = socks ] && [ "$active" = 1 ] && [ "$port" = 1082 ] || hg_main_plan_blocked UNSUPPORTED_MAIN_PROFILE
    autoswitch="$(hg_main_plan_get passwall2.socks_P8ART.enable_autoswitch)" || hg_main_plan_blocked UCI_READ_FAILED
    [ "$autoswitch" = 0 ] || hg_main_plan_blocked AUTOSWITCH_REQUIRES_OWNER
    current="$(hg_main_plan_get passwall2.socks_P8ART.node)" || hg_main_plan_blocked UCI_READ_FAILED
    case "$current" in ''|*[!a-zA-Z0-9_]* ) hg_main_plan_blocked INVALID_CURRENT_NODE ;; esac
    candidate_type="$(hg_main_plan_get "passwall2.$candidate")" || hg_main_plan_blocked CANDIDATE_UNAVAILABLE
    [ "$candidate_type" = nodes ] || hg_main_plan_blocked INVALID_CANDIDATE_TYPE
    # Re-observe pending edits; still no claim of generation-consistent reads.
    pending="$(timeout -k 1 5 uci -q changes passwall2 2>/dev/null | head -c 65)" || hg_main_plan_blocked UCI_READ_FAILED
    [ -z "$pending" ] || hg_main_plan_blocked UNCOMMITTED_CONFIG
    same=false
    [ "$candidate" != "$current" ] || same=true
    printf '{"schema_version":1,"status":"PREFLIGHT_ADAPTER_REQUIRED","candidate_exists":true,"same_as_configured_main":%s,"observation_only":true,"apply_supported":false,"preflight_passed":false,"snapshot_ready":false,"blockers":["AUDITED_PASSWALL_HELPERS","WRITER_COORDINATION","LAN_TAILSCALE_RECOVERY","TRANSACTION_SNAPSHOT_JOURNAL"]}\n' "$same"
    exit 70
)

# Candidate probes share the VPN module tracked by the deployment inventory.
hg_candidate_renderer() {
    cat <<'HG_CANDIDATE_UCODE'
'use strict';

import { stdin } from 'fs';

function reject() {
    warn('vpn-candidate: unsupported or invalid candidate configuration\n');
    exit(2);
}

function matches(value, pattern) {
    return type(value) == 'string' && match(value, pattern) != null;
}

function valid_host(value) {
    return matches(value, /^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$/);
}

function valid_path(value) {
    return matches(value, /^\/[[:graph:]]*$/) && length(value) <= 1024;
}

function render(node, listen_port) {
    if (type(node) != 'object' || node.type != 'Xray' || node.protocol != 'vless' ||
        node.tls != '1' || (node.tls_allowInsecure ?? '0') != '0' ||
        !valid_host(node.address) || !valid_host(node.tls_serverName) ||
        !matches(node.port, /^[1-9][0-9]{0,4}$/) || int(node.port) > 65535 ||
        !matches(node.uuid, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) ||
        (node.encryption ?? 'none') != 'none')
        reject();

    let supported = [
        'type', 'protocol', 'transport', 'address', 'port', 'uuid', 'tls',
        'tls_allowInsecure', 'tls_serverName', 'encryption', 'alpn', 'utls',
        'fingerprint', 'reality', 'reality_publicKey', 'reality_shortId',
        'reality_spiderX', 'flow', 'xhttp_path', 'xhttp_host', 'xhttp_mode',
        'grpc_serviceName', 'grpc_mode', 'tcp_guise', 'remarks', 'group', 'add_mode', 'timeout'
    ];
    for (let key in keys(node))
        if (index(supported, key) < 0 || type(node[key]) != 'string')
            reject();

    let network = node.transport;
    let stream = { network };
    switch (network) {
    case 'raw':
        if ((node.tcp_guise ?? 'none') != 'none')
            reject();
        break;
    case 'xhttp':
        let mode = node.xhttp_mode ?? 'auto';
        let path = node.xhttp_path ?? '/';
        if (index([ 'auto', 'packet-up', 'stream-up', 'stream-one' ], mode) < 0 ||
            !valid_path(path) ||
            (length(node.xhttp_host ?? '') && !valid_host(node.xhttp_host)))
            reject();
        stream.xhttpSettings = { mode, path, host: node.xhttp_host ?? '' };
        break;
    case 'grpc':
        if (!matches(node.grpc_serviceName, /^[-a-zA-Z0-9_.\/]{1,255}$/) ||
            index([ 'gun', 'multi' ], node.grpc_mode ?? 'gun') < 0)
            reject();
        stream.grpcSettings = {
            serviceName: node.grpc_serviceName,
            multiMode: node.grpc_mode == 'multi'
        };
        break;
    default:
        reject();
    }

    let fingerprint = node.fingerprint;
    if (fingerprint && index([ 'chrome', 'firefox', 'safari', 'ios', 'android', 'edge' ], fingerprint) < 0)
        reject();
    if (node.reality == '1') {
        if (!fingerprint || !matches(node.reality_publicKey, /^[A-Za-z0-9_-]{43}$/) ||
            !matches(node.reality_shortId ?? '', /^([a-fA-F0-9]{2}){0,8}$/) ||
            !valid_path(node.reality_spiderX ?? '/'))
            reject();
        stream.security = 'reality';
        stream.realitySettings = {
            serverName: node.tls_serverName,
            fingerprint,
            password: node.reality_publicKey,
            shortId: node.reality_shortId ?? '',
            spiderX: node.reality_spiderX ?? '/'
        };
    }
    else {
        if ((node.reality ?? '0') != '0' || node.reality_publicKey || node.reality_shortId || node.reality_spiderX)
            reject();
        stream.security = 'tls';
        stream.tlsSettings = { serverName: node.tls_serverName, allowInsecure: false };
        if (node.utls == '1' && fingerprint)
            stream.tlsSettings.fingerprint = fingerprint;
        if (node.alpn) {
            let alpn = split(node.alpn, ',');
            for (let name in alpn)
                if (index([ 'h2', 'http/1.1' ], name) < 0)
                    reject();
            stream.tlsSettings.alpn = alpn;
        }
    }

    let user = { id: node.uuid, encryption: 'none' };
    if (node.flow) {
        if (node.flow != 'xtls-rprx-vision' || network != 'raw')
            reject();
        user.flow = node.flow;
    }
    return {
        log: { loglevel: 'none' },
        inbounds: [{
            listen: '127.0.0.1', port: listen_port, protocol: 'socks',
            settings: { auth: 'noauth', udp: false }
        }],
        outbounds: [{
            protocol: 'vless',
            settings: { vnext: [{ address: node.address, port: int(node.port), users: [ user ] }] },
            streamSettings: stream
        }]
    };
}

// The caller must own the temporary port and keep stdin/stdout private.
if (length(ARGV) != 1 || !matches(ARGV[0], /^[0-9]{5}$/) ||
    int(ARGV[0]) < 49152 || int(ARGV[0]) > 65535)
    reject();
let input = stdin.read(16385);
if (!input || length(input) > 16384)
    reject();
let node;
try { node = json(input); }
catch (e) { reject(); }
printf('%J\n', render(node, int(ARGV[0])));
HG_CANDIDATE_UCODE
}

hg_candidate_check() (
    set -eu
    set -o pipefail

    [ "$#" -eq 1 ] || exit 2
    candidate="$1"
    case "$candidate" in ''|*[!a-zA-Z0-9_]*) exit 2 ;; esac
    [ "${#candidate}" -le 64 ] || exit 2

    umask 077
    dir="$(mktemp -d /tmp/hg-candidate.XXXXXX)"
    runner=''
    cleanup() {
        if [ -n "$runner" ]; then
            kill -TERM "$runner" 2>/dev/null || :
            wait "$runner" 2>/dev/null || :
        fi
        rm -f "$dir/config.json" "$dir/render.uc"
        rmdir "$dir"
    }
    trap cleanup EXIT
    trap 'exit 70' HUP INT TERM

    port=55182
    if netstat -lnt | grep -E "[.:]$port[[:space:]]" >/dev/null; then
        printf 'CANDIDATE_PORT_BUSY\n'
        exit 70
    fi

    hg_candidate_renderer > "$dir/render.uc"

    # Credentials move between local processes on stdin, never in argv or diagnostics.
    ucode -e '
        import { cursor } from "uci";
        let c = cursor();
        let backups = c.get("passwall2", "socks_P8ART", "autoswitch_backup_node");
        if (type(backups) != "array" || index(backups, ARGV[0]) < 0 ||
            c.get("passwall2", "socks_P8ART", "node") == ARGV[0])
            exit(2);
        let node = c.get_all("passwall2", ARGV[0]);
        if (node == null || node[".type"] != "nodes")
            exit(2);
        for (let field in keys(node))
            if (substr(field, 0, 1) == ".") delete node[field];
        printf("%J", node);
    ' "$candidate" | ucode "$dir/render.uc" "$port" > "$dir/config.json"

    timeout -k 2 15 /usr/bin/xray run -c "$dir/config.json" </dev/null >/dev/null 2>&1 &
    runner=$!
    sleep 1
    pid="$(netstat -lntp 2>/dev/null | awk -v addr="127.0.0.1:$port" '
        $4 == addr && $6 == "LISTEN" && $7 ~ /\/xray$/ { split($7, fields, "/"); print fields[1] }
    ')"
    case "$pid" in ''|*[!0-9]*) printf 'CANDIDATE_LISTENER_UNAVAILABLE\n'; exit 70 ;; esac
    if ! awk -v expected="$runner" '$1 == "PPid:" && $2 == expected { found=1 } END { exit !found }' "/proc/$pid/status"; then
        printf 'CANDIDATE_LISTENER_NOT_OWNED\n'
        exit 70
    fi

    result=0
    for url in https://www.google.com/generate_204 https://cp.cloudflare.com/; do
        code="$(curl -q --noproxy '' --socks5-hostname "127.0.0.1:$port" \
            --connect-timeout 3 --max-time 4 -s -o /dev/null -w '%{http_code}' "$url")" || code=000
        printf '%s HTTP=%s\n' "$url" "$code"
        [ "$code" = 204 ] || result=70
    done
    exit "$result"
)
