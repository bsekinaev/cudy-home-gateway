#!/bin/sh
# Read-only статус Redmi VPN-only policy CUDY Home Gateway.

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

    printf '%s\n' "$value" | awk '
        /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$/ {
            exit 0
        }
        {
            exit 1
        }
    '
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

    # У ACL нет отдельного SOCKS endpoint, поэтому egress с роутера
    # безопасно не подменяем egress'ом MAIN и оставляем UNKNOWN.
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
}
