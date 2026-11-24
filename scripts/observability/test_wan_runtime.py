"""WAN adapter tests with synthetic, offline command responses."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipIf(os.name == 'nt', 'POSIX shell required')
class WanRuntimeTests(unittest.TestCase):
    def run_case(self, actions):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HG_LIBDIR=str(ROOT / 'src/usr/lib/home-gateway'),
                       HG_EGRESS_CACHE_FILE=tmp + '/cache')
            script = r'''
. "$HG_LIBDIR/network.sh"
proto=dhcp; address=192.0.2.2; route='default via 192.0.2.1 dev eth1'; answer=203.0.113.4
ubus() { echo '{}'; }
jsonfilter() { cat >/dev/null; case "$*" in *@.up*) echo true;; *@.l3_device*) echo eth1;; *@.proto*) echo "$proto";; esac; }
ip() { case "$*" in *addr*) echo "inet $address/24";; *route*) printf '%s\n' "$route";; esac; }
curl() { printf '%s\n' "$answer"; }
sample() { hg_network_collect; printf '%s|%s|%s|%s\n' "$HG_NETWORK_WAN_STATE" "$HG_NETWORK_DIRECT_STATE" "$HG_NETWORK_DIRECT_SOURCE" "$HG_NETWORK_DIRECT_IPV4"; }
''' + actions
            result = subprocess.run(['sh', '-c', script], env=env, text=True,
                                    capture_output=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.splitlines()

    def test_pppoe_device_route(self):
        self.assertEqual(self.run_case("proto=pppoe; route='default dev eth1 scope link'; sample"),
                         ['OK|OK|live_probe|203.0.113.4'])

    def test_route_of_other_device_not_accepted(self):
        self.assertEqual(self.run_case("route='default via 192.0.2.1 dev eth2'; sample"),
                         ['DEGRADED|UNKNOWN|live_probe|'])

    def test_unknown_protocol_not_ready(self):
        self.assertEqual(self.run_case('proto=unknown; sample'),
                         ['DEGRADED|UNKNOWN|live_probe|'])

    def test_network_change_invalidates_cache(self):
        self.assertEqual(self.run_case('sample; sample; address=192.0.2.3; answer=203.0.113.9; sample'),
                         ['OK|OK|live_probe|203.0.113.4', 'OK|OK|cache|203.0.113.4',
                          'OK|OK|live_probe|203.0.113.9'])

    def test_old_cache_cannot_be_used_after_route_change(self):
        self.assertEqual(self.run_case("sample; route='default via 192.0.2.254 dev eth1'; answer=''; sample"),
                         ['OK|OK|live_probe|203.0.113.4', 'OK|UNKNOWN|live_probe|'])

    def test_multiple_defaults_do_not_certify_route(self):
        self.assertEqual(self.run_case("route='default via 192.0.2.1 dev eth1\ndefault via 192.0.2.254 dev eth1'; sample"),
                         ['DEGRADED|UNKNOWN|live_probe|'])

    def test_linkdown_route_does_not_certify_path(self):
        self.assertEqual(self.run_case("route='default via 192.0.2.1 dev eth1 linkdown'; sample"),
                         ['DEGRADED|UNKNOWN|live_probe|'])

    def test_legacy_cache_is_not_reused(self):
        self.assertEqual(self.run_case('printf "%s 203.0.113.99 previous\\n" "$(date +%s)" > "$HG_EGRESS_CACHE_FILE"; sample'),
                         ['OK|OK|live_probe|203.0.113.4'])
