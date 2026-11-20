# Appended after common/dns/redmi definitions, then streamed through SSH stdin.
HG_REDMI_ACL_PROFILE="${1:-acl_A2dNs}"
case "$HG_REDMI_ACL_PROFILE" in ''|*[!a-zA-Z0-9_]*) exit 1 ;; esac
printf 'HG_REDMI_DNS_TEST_V1\n'
hg_dns_collect
hg_redmi_collect
printf '{"profile":%s,"router_dns_state":%s,"redmi_config_state":%s,"redmi_xray_state":%s,"redmi_policy_state":%s,"redmi_killswitch_state":%s,"redmi_dns_state":%s,"redmi_dns_reason":%s,"redmi_dns_port":%s,"redmi_dns_source":%s,"client_internet":"unverified"}\n' \
    "$(hg_json_string "$HG_REDMI_ACL_PROFILE")" \
    "$(hg_json_string "$HG_DNS_STATE")" \
    "$(hg_json_string "$HG_REDMI_CONFIG_STATE")" \
    "$(hg_json_string "$HG_REDMI_XRAY_STATE")" \
    "$(hg_json_string "$HG_REDMI_POLICY_STATE")" \
    "$(hg_json_string "$HG_REDMI_KILLSWITCH_STATE")" \
    "$(hg_json_string "$HG_REDMI_DNS_STATE")" \
    "$(hg_json_string "$HG_REDMI_DNS_REASON")" \
    "$(hg_json_number_or_null "$HG_REDMI_DNS_PORT")" \
    "$(hg_json_string "$HG_REDMI_DNS_SOURCE")"
exit 0
