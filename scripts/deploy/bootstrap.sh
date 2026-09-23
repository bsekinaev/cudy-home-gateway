#!/bin/sh
# One-time LAN/admin installation, never invoked by the deployment key.
set -eu
umask 077
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || exit 1
for tool in uci fw4 ucode sha256sum base64 stat timeout head mktemp cmp sync; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
[ ! -e /etc/home-gateway-deploy/BOOTSTRAPPED ] || { echo 'Already bootstrapped; use documented maintenance procedure'; exit 1; }
[ -z "$(uci changes firewall)" ] && [ -z "$(uci changes dropbear)" ] || { echo 'Uncommitted UCI changes'; exit 1; }
! uci -q get dropbear.cd_deploy >/dev/null || { echo 'cd_deploy section already exists'; exit 1; }
! uci -q get firewall.cd_deploy >/dev/null || { echo 'cd_deploy firewall rule already exists'; exit 1; }
[ "$(uci get network.tailscale_ci.device)" = tailscale0 ]
[ "$(uci get firewall.tailscale.name)" = tailscale ]
grep -q 'procd_set_param netdev' /etc/init.d/dropbear || { echo 'Install documented Dropbear netdev fix first'; exit 1; }
ip -4 addr show dev tailscale0 | grep -q '100.84.35.92/32'
netstat -lnt | grep -q ':2223 ' && { echo 'Port 2223 already in use'; exit 1; }
[ -f /etc/dropbear/authorized_keys ] && [ ! -L /etc/dropbear/authorized_keys ]
read -r type key comment < deploy.pub
[ "$type" = ssh-ed25519 ] && [ "${#key}" -eq 68 ]
case "$key" in *[!A-Za-z0-9+/=]*) exit 1;; esac
if grep -Fq "$key" /etc/dropbear/authorized_keys; then echo 'Key already registered; use a separate CD key'; exit 1; fi
for script in engine.sh wrapper.sh recovery.init; do sh -n "$script"; done
backup=$(mktemp -d /root/home-gateway-cd-bootstrap.XXXXXX)
cp -p /etc/config/dropbear /etc/config/firewall /etc/dropbear/authorized_keys "$backup/"
[ ! -f /etc/sysupgrade.conf ] || cp -p /etc/sysupgrade.conf "$backup/"
echo "BOOTSTRAP_BACKUP=$backup"
mkdir -p /usr/libexec/home-gateway-deploy /etc/home-gateway-deploy
chmod 700 /etc/home-gateway-deploy /usr/libexec/home-gateway-deploy
cp engine.sh wrapper.sh /usr/libexec/home-gateway-deploy/
chmod 700 /usr/libexec/home-gateway-deploy/*.sh
cp recovery.init /etc/init.d/home-gateway-deploy-recover
chmod 755 /etc/init.d/home-gateway-deploy-recover
# Key-specific command is essential. Server-wide -c would override the smoke key restrictions.
cp -p /etc/dropbear/authorized_keys "$backup/authorized_keys.new"
printf '\ncommand="/usr/libexec/home-gateway-deploy/wrapper.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty %s %s cudy-cd\n' "$type" "$key" >> "$backup/authorized_keys.new"
cp "$backup/authorized_keys.new" /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
uci set dropbear.cd_deploy=dropbear
uci set dropbear.cd_deploy.enable=1
uci set dropbear.cd_deploy.DirectInterface=tailscale_ci
uci set dropbear.cd_deploy.Port=2223
uci set dropbear.cd_deploy.PasswordAuth=0
uci set dropbear.cd_deploy.RootPasswordAuth=0
uci set dropbear.cd_deploy.RootLogin=1
uci set dropbear.cd_deploy.LocalPortForward=0
uci set dropbear.cd_deploy.RemotePortForward=0
uci set dropbear.cd_deploy.mdns=0
uci set firewall.cd_deploy=rule
uci set firewall.cd_deploy.name=Allow-CUDY-CD
uci set firewall.cd_deploy.src=tailscale
uci set firewall.cd_deploy.dest_ip=100.84.35.92
uci set firewall.cd_deploy.proto=tcp
uci set firewall.cd_deploy.dest_port=2223
uci set firewall.cd_deploy.family=ipv4
uci set firewall.cd_deploy.target=ACCEPT
if ! fw4 check; then
    uci revert firewall; uci revert dropbear
    cp -p "$backup/authorized_keys" /etc/dropbear/authorized_keys
    echo 'Firewall validation failed; configuration reverted' >&2
    exit 1
fi
uci commit firewall
uci commit dropbear
/etc/init.d/firewall reload
/etc/init.d/dropbear reload
/etc/init.d/home-gateway-deploy-recover enable
# Preserve application code, receiver and local Tailscale/Dropbear fixes during sysupgrade.
touch /etc/sysupgrade.conf
for item in /etc/home-gateway-deploy/ /usr/libexec/home-gateway-deploy/ \
    /etc/init.d/home-gateway-deploy-recover /etc/init.d/home-gateway-telegram \
    /usr/bin/gateway /usr/bin/home-gateway-ci-smoke /usr/lib/home-gateway/ \
    /etc/init.d/dropbear /etc/init.d/tailscale \
    /etc/rc.d/S94home-gateway-deploy-recover /etc/rc.d/K09home-gateway-deploy-recover \
    /etc/rc.d/S95home-gateway-telegram /etc/rc.d/K10home-gateway-telegram; do
    grep -Fxq "$item" /etc/sysupgrade.conf || printf '%s\n' "$item" >> /etc/sysupgrade.conf
done
/bin/sh /usr/libexec/home-gateway-deploy/engine.sh status
printf '%s\n' "$backup" > /etc/home-gateway-deploy/BOOTSTRAPPED
echo BOOTSTRAP_OK
