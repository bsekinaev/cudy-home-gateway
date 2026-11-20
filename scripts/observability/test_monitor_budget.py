"""Actual adapters under a non-networked command boundary."""
import os, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class MonitorBudgetTests(unittest.TestCase):
 def run_adapter(self,module,active=True):
  with tempfile.TemporaryDirectory() as d:
   env=dict(os.environ, HG_LIBDIR=str(ROOT/'src/usr/lib/home-gateway'), HG_TEST_LOG=d+'/log',HG_MONITOR_ACTIVE='1' if active else '0', HG_EGRESS_CACHE_FILE=d+'/wan',HG_MAIN_EGRESS_CACHE_FILE=d+'/main',HG_TORRENT_EGRESS_CACHE_FILE=d+'/torrent')
   script=r''' . "$HG_LIBDIR/''' +module+r'''.sh"
uci() {
 case "$*" in
 *rulenode.default_node) echo socks_P8ART;;
 *enable_autoswitch) echo 0;;
 *.enabled) echo 1;;
 *.node) echo node1;;
 *.port) echo 1082;;
 *.remarks) echo fixture;;
 *network.*.device) echo eth1;;
 *network.*.proto) echo dhcp;;
 *) echo socks;; esac
}
ps() { echo 'xray /tmp/etc/passwall2/socks_P8ART.json /tmp/etc/passwall2/socks_hLPwH.json'; }
ubus() { echo '{}'; }
jsonfilter() { cat >/dev/null; case "$*" in *@.up*) echo true;; *@.l3_device*) echo eth1;; *@.proto*) echo dhcp;; esac; }
ip() { case "$*" in *addr*) echo 'inet 192.0.2.2/24';; *route*) echo 'default via 192.0.2.1 dev eth1';; esac; }
curl() { echo "$*" >> "$HG_TEST_LOG"; echo 203.0.113.1; }
hg_''' +module+r'''_collect
'''
   p=subprocess.run(['sh','-c',script],env=env,text=True,capture_output=True,timeout=5)
   self.assertEqual(p.returncode,0,p.stderr)
   log=Path(d+'/log'); return log.read_text() if log.exists() else ''
 def test_monitor_wan_budget_is_three_seconds(self):
  self.assertIn('--max-time 3',self.run_adapter('network'))
 def test_monitor_main_budget_is_four_seconds(self):
  self.assertIn('--max-time 4',self.run_adapter('vpn'))
 def test_torrent_background_does_not_start_external_probe(self):
  self.assertEqual(self.run_adapter('torrent'),'')
 def test_interactive_torrent_keeps_external_probe(self):
  self.assertIn('--max-time 6',self.run_adapter('torrent',False))
if __name__=='__main__': unittest.main()
