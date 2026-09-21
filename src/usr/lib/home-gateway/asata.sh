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
                    index($0, "comment \"" comment "\"") {
                        comment_rules++
                        if (index($0, "ip saddr " ip) && index($0, "meta l4proto udp") && index($0, " return ")) {
                            valid_rules++
                            for (i = 1; i <= NF; i++) {
                                if ($i == "packets" && (i + 1) <= NF)
                                    packets += $(i + 1)
                                else if ($i == "bytes" && (i + 1) <= NF)
                                    bytes += $(i + 1)
                            }
                        }
                    }
                    END {
                        print comment_rules + 0, valid_rules + 0, packets + 0, bytes + 0
                    }
                '
        )

        HG_ASATA_RULES="${1:-}"
        HG_ASATA_VALID_RULES="${2:-}"
        HG_ASATA_RULE_PACKETS="${3:-}"
        HG_ASATA_RULE_BYTES="${4:-}"

        if [ "$HG_ASATA_RULES" = '1' ] && [ "$HG_ASATA_VALID_RULES" = '1' ]; then
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
