#!/bin/sh
# Read-only статус ASATA UDP-direct policy CUDY Home Gateway.

hg_asata_collect() {
    HG_ASATA_STATE='UNKNOWN'
    HG_ASATA_CLIENT_IPV4="${HG_ASATA_CLIENT_IPV4:-192.168.1.140}"
    HG_ASATA_EXPECTED_MAC="${HG_ASATA_EXPECTED_MAC:-58:04:4f:81:09:6b}"
    HG_ASATA_OBSERVED_MAC=''
    HG_ASATA_CLIENT_NAME=''
    HG_ASATA_IDENTITY_STATE='UNKNOWN'
    HG_ASATA_REACHABILITY_STATE='UNKNOWN'
    HG_ASATA_RULE_STATE='UNKNOWN'
    HG_ASATA_RULE_COMMENT="${HG_ASATA_RULE_COMMENT:-ASATA-UDP-DIRECT}"
    HG_ASATA_RULES=''
    HG_ASATA_VALID_RULES=''
    HG_ASATA_RULE_PACKETS=''
    HG_ASATA_RULE_BYTES=''
    HG_ASATA_KEEPER_STATE='UNKNOWN'
    HG_ASATA_KEEPER_AUTOSTART='unknown'
    HG_ASATA_KEEPER_INTERVAL_SECONDS=''

    lease_file="${HG_ASATA_LEASE_FILE:-/tmp/dhcp.leases}"
    init_script="${HG_ASATA_INIT_SCRIPT:-/etc/init.d/asata_udp_direct}"
    keeper_path="${HG_ASATA_KEEPER_PATH:-/usr/bin/asata-udp-direct}"

    lease_mac=''
    neighbor_mac=''

    if [ -r "$lease_file" ]; then
        lease_mac="$(
            awk -v ip="$HG_ASATA_CLIENT_IPV4" '
                $3 == ip { print tolower($2); exit }
            ' "$lease_file" 2>/dev/null || true
        )"
        HG_ASATA_CLIENT_NAME="$(
            awk -v ip="$HG_ASATA_CLIENT_IPV4" '
                $3 == ip { print $4; exit }
            ' "$lease_file" 2>/dev/null || true
        )"
    fi

    if command -v ip >/dev/null 2>&1; then
        neighbor_mac="$(
            ip neigh show "$HG_ASATA_CLIENT_IPV4" 2>/dev/null |
                awk '
                    NR == 1 {
                        for (i = 1; i <= NF; i++) {
                            if ($i == "lladdr" && (i + 1) <= NF) {
                                print tolower($(i + 1))
                                exit
                            }
                        }
                    }
                ' || true
        )"
    fi

    if [ -n "$neighbor_mac" ]; then
        HG_ASATA_OBSERVED_MAC="$neighbor_mac"
    elif [ -n "$lease_mac" ]; then
        HG_ASATA_OBSERVED_MAC="$lease_mac"
    fi

    expected_mac="$(printf '%s' "$HG_ASATA_EXPECTED_MAC" | awk '{ print tolower($0) }')"

    if [ -n "$lease_mac" ] && [ -n "$neighbor_mac" ] && [ "$lease_mac" != "$neighbor_mac" ]; then
        HG_ASATA_IDENTITY_STATE='DOWN'
    elif [ -n "$HG_ASATA_OBSERVED_MAC" ] && [ "$HG_ASATA_OBSERVED_MAC" = "$expected_mac" ]; then
        HG_ASATA_IDENTITY_STATE='OK'
    elif [ -n "$HG_ASATA_OBSERVED_MAC" ]; then
        HG_ASATA_IDENTITY_STATE='DOWN'
    fi

    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 1 "$HG_ASATA_CLIENT_IPV4" >/dev/null 2>&1; then
            HG_ASATA_REACHABILITY_STATE='OK'
        else
            HG_ASATA_REACHABILITY_STATE='DOWN'
        fi
    fi

    if command -v nft >/dev/null 2>&1; then
        set -- $(
            nft -a list chain inet passwall2 PSW2_MANGLE 2>/dev/null |
                awk -v ip="$HG_ASATA_CLIENT_IPV4" -v comment="$HG_ASATA_RULE_COMMENT" '
                    /# handle [0-9]+[ \t]*$/ && $1 != "chain" && $1 != "table" { rule_position++ }
                    index($0, "comment \"" comment "\"") {
                        comment_rules++
                        # Exact canonical nft expression, not substring matches.
                        # Reject broader IPs, extra predicates, assignments and verdicts.
                        line = $0
                        sub(/^[ \t]+/, "", line)
                        sub(/[ \t]+# handle [0-9]+[ \t]*$/, "", line)
                        n = split(line, fields, /[ \t]+/)
                        if (n == 14 && fields[1] == "ip" && fields[2] == "saddr" &&
                            fields[3] == ip && fields[4] == "meta" &&
                            fields[5] == "l4proto" && fields[6] == "udp" &&
                            fields[7] == "counter" && fields[8] == "packets" &&
                            fields[9] ~ /^[0-9]+$/ && fields[10] == "bytes" &&
                            fields[11] ~ /^[0-9]+$/ && fields[12] == "return" &&
                            fields[13] == "comment" && fields[14] == "\"" comment "\"") {
                            valid_rules++
                            if (rule_position == 1) valid_first=1
                            packets += fields[9]
                            bytes += fields[11]
                        }
                    }
                    END {
                        print comment_rules + 0, valid_rules + 0, packets + 0, bytes + 0, valid_first + 0
                    }
                '
        )

        HG_ASATA_RULES="${1:-}"
        HG_ASATA_VALID_RULES="${2:-}"
        HG_ASATA_RULE_PACKETS="${3:-}"
        HG_ASATA_RULE_BYTES="${4:-}"

        if [ "$HG_ASATA_RULES" = '1' ] && [ "$HG_ASATA_VALID_RULES" = '1' ] && [ "${5:-0}" = 1 ]; then
            HG_ASATA_RULE_STATE='OK'
        elif [ "$HG_ASATA_VALID_RULES" = '0' ]; then
            HG_ASATA_RULE_STATE='DOWN'
        else
            HG_ASATA_RULE_STATE='DEGRADED'
        fi
    fi

    if [ -x "$init_script" ]; then
        if "$init_script" running >/dev/null 2>&1 && [ -x "$keeper_path" ]; then
            HG_ASATA_KEEPER_STATE='OK'
        else
            HG_ASATA_KEEPER_STATE='DOWN'
        fi

        if "$init_script" enabled >/dev/null 2>&1; then
            HG_ASATA_KEEPER_AUTOSTART='true'
        else
            HG_ASATA_KEEPER_AUTOSTART='false'
        fi

        HG_ASATA_KEEPER_INTERVAL_SECONDS="$(
            sed -n 's/.*sleep \([0-9][0-9]*\).*/\1/p' "$init_script" 2>/dev/null |
                head -n 1
        )"
    else
        HG_ASATA_KEEPER_STATE='DOWN'
    fi

    # Выключенный ASATA не ломает саму policy: reachability показываем отдельно.
    # Но неверная идентичность IP/MAC опасна: UDP-direct может примениться не к тому клиенту.
    if [ "$HG_ASATA_RULE_STATE" = 'DOWN' ] || [ "$HG_ASATA_IDENTITY_STATE" = 'DOWN' ]; then
        HG_ASATA_STATE='DOWN'
    elif [ "$HG_ASATA_RULE_STATE" = 'DEGRADED' ] || \
         [ "$HG_ASATA_KEEPER_STATE" != 'OK' ] || \
         [ "$HG_ASATA_KEEPER_AUTOSTART" != 'true' ]; then
        HG_ASATA_STATE='DEGRADED'
    elif [ "$HG_ASATA_RULE_STATE" = 'OK' ]; then
        HG_ASATA_STATE='OK'
    fi
}

# Independent keeper implementation. Repair is local opt-in, never exposed by Telegram.
# Replaces the old worker only after owner approval; running both is unsupported.
hg_asata_keeper() (
    mode="$1"
    case "$mode" in check|repair) ;; *) exit 2 ;; esac
    if [ "$mode" = repair ] && [ "${HG_ASATA_KEEPER_AUTHORIZED:-0}" != 1 ]; then
        printf 'ASATA_KEEPER=DISABLED\n'
        exit 70
    fi
    umask 077
    runtime="${HG_ASATA_KEEPER_RUNTIME_DIR:-/tmp/home-gateway}"
    hg_asata_runtime_prepare "$runtime" || exit 70
    # Kernel lock has no PID file to become stale. Child nft is bounded to 5 seconds.
    [ ! -L "$runtime/asata-keeper.lock" ] || exit 70
    [ ! -e "$runtime/asata-keeper.lock" ] || [ "$(stat -c %u "$runtime/asata-keeper.lock")" = 0 ] || exit 70
    exec 9>"$runtime/asata-keeper.lock" || exit 70
    chmod 600 "$runtime/asata-keeper.lock" || exit 70
    flock -n 9 || exit 73
    work="$(mktemp -d "$runtime/asata-keeper.XXXXXX")" || exit 70
    trap 'rm -rf "$work"' EXIT
    trap 'exit 70' INT TERM
    set -o pipefail
    hg_asata_keeper_capture "$work/chain" || exit 70
    # Inspect exact semantics; malformed handles or missing chain abort.
    hg_asata_keeper_plan "$work/chain" > "$work/batch" || exit 70
    if [ "$(head -n 1 "$work/batch")" = OK ]; then
        printf 'ASATA_KEEPER=OK\n'
        exit 0
    fi
    if [ "$mode" = check ]; then
        printf 'ASATA_KEEPER=NEEDS_REPAIR\n'
        exit 1
    fi
    # No mutation without coordination with every external chain writer.
    # Even a missing-rule insert can race another writer and leave duplicates.
    printf 'ASATA_KEEPER=OWNER_COORDINATION_REQUIRED\n'
    exit 70
)

# Helpers used only with private generated paths from the locked keeper.
hg_asata_keeper_capture() {
    timeout -k 1 5 nft -a list chain inet passwall2 PSW2_MANGLE 2>/dev/null |
        head -c 65537 > "$1" || return 70
    captured_size="$(stat -c %s "$1")" || return 70
    [ "$captured_size" -le 65536 ]
}

hg_asata_keeper_plan() {
    awk '
        /^[ \t]*table inet passwall2[ \t]*\{/ { tables++; next }
        /^[ \t]*}[ \t]*$/ { closes++; next }
        /^[ \t]*chain PSW2_MANGLE[ \t]*\{/ { chains++; next }
        /# handle [0-9]+[ \t]*$/ {
            if ($1 == "table" || $1 == "chain") next
            position++
            if (!index($0, "comment \"ASATA-UDP-DIRECT\"")) next
            marked++
            line=$0; sub(/^[ \t]+/, "", line)
            handle=$NF
            if (handle !~ /^[0-9]+$/ || length(handle)>10 || seen[handle]++) { bad=1; next }
            sub(/[ \t]+# handle [0-9]+[ \t]*$/, "", line)
            n=split(line,f,/[ \t]+/)
            if (position == 1 && n == 14 && f[1] == "ip" && f[2] == "saddr" &&
                f[3] == "192.168.1.140" && f[4] == "meta" && f[5] == "l4proto" &&
                f[6] == "udp" && f[7] == "counter" && f[8] == "packets" &&
                f[9] ~ /^[0-9]+$/ && f[10] == "bytes" && f[11] ~ /^[0-9]+$/ &&
                f[12] == "return" && f[13] == "comment" && f[14] == "\"ASATA-UDP-DIRECT\"") valid++
            # Captured handles are validated, but never used for mutation.
        }
        index($0,"comment \"ASATA-UDP-DIRECT\"") && $0 !~ /# handle [0-9]+[ \t]*$/ { bad=1 }
        $0 !~ /# handle [0-9]+[ \t]*$/ && $0 !~ /^[ \t]*(type |policy |$)/ { bad=1 }
        END {
            if (tables != 1 || chains != 1 || closes != 2 || bad || marked > 32) exit 1
            if (marked == 1 && valid == 1) { print "OK"; exit }
            if (marked > 0) { print "BLOCKED_MARKED_RULE"; exit }
            print "MISSING_RULE"
        }
    ' "$1"

}

# Owner may use this fixed worker in a separately approved procd replacement.
hg_asata_keeper_loop() (
    [ "${HG_ASATA_KEEPER_AUTHORIZED:-0}" = 1 ] || exit 70
    umask 077
    runtime="${HG_ASATA_KEEPER_RUNTIME_DIR:-/tmp/home-gateway}"
    hg_asata_runtime_prepare "$runtime" || exit 70
    [ ! -L "$runtime/asata-keeper-loop.lock" ] || exit 70
    [ ! -e "$runtime/asata-keeper-loop.lock" ] || [ "$(stat -c %u "$runtime/asata-keeper-loop.lock")" = 0 ] || exit 70
    exec 8>"$runtime/asata-keeper-loop.lock" || exit 70
    chmod 600 "$runtime/asata-keeper-loop.lock" || exit 70
    flock -n 8 || exit 73
    trap 'exit 0' INT TERM
    while :; do
        hg_asata_keeper repair || true
        sleep 10
    done
)

# Each component is inspected in one lstat-backed stat call: type, uid, mode
# belong to the same inode. Once accepted under a trusted (possibly sticky)
# parent, an unprivileged user cannot rename this root-owned directory.
hg_asata_runtime_prepare() (
    candidate="$1"
    case "$candidate" in /*) ;; *) exit 1 ;; esac
    case "$candidate" in *[!a-zA-Z0-9_./-]*|*//*|*/) exit 1 ;; esac
    prefix=''
    remaining="$candidate"
    while :; do
        # BusyBox stat defaults to lstat (no -L); symlinks cannot pass as directory.
        set -- $(LC_ALL=C stat -c '%u %a %F' "${prefix:-/}") || exit 1
        [ "$#" -eq 3 ] && [ "$1" = 0 ] && [ "$3" = directory ] || exit 1
        permission="$2"
        case "$permission" in ''|*[!0-7]*) exit 1 ;; esac
        [ "${#permission}" -le 4 ] || exit 1
        if [ "$prefix" != "$candidate" ] && [ $((0$permission & 0022)) -ne 0 ]; then
            [ $((0$permission & 01000)) -ne 0 ] || exit 1
        fi
        [ "$prefix" != "$candidate" ] || break
        remaining="${remaining#/}"
        segment="${remaining%%/*}"
        case "$segment" in ''|.|..) exit 1 ;; esac
        prefix="$prefix/$segment"
        remaining="${remaining#"$segment"}"
        # The parent was validated before this lookup/create. A hostile existing
        # entry is inspected on the next iteration, never chmodded or descended.
        [ -e "$prefix" ] || [ -L "$prefix" ] || mkdir -m 700 "$prefix" || exit 1
    done
    [ "$prefix" != / ] && [ "$prefix" != /tmp ] && [ "$permission" = 700 ]
)
