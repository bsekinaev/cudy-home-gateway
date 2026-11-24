"""Actual adapters under a non-networked command boundary."""
import os, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class MonitorBudgetTests(unittest.TestCase):
 def run_adapter(self,module,active=True,actions=None):
  with tempfile.TemporaryDirectory() as d:
   env=dict(os.environ, HG_LIBDIR=str(ROOT/'src/usr/lib/home-gateway'), HG_TEST_LOG=d+'/log',HG_MONITOR_ACTIVE='1' if active else '0', HG_EGRESS_CACHE_FILE=d+'/wan',HG_MAIN_EGRESS_CACHE_FILE=d+'/main',HG_TORRENT_EGRESS_CACHE_FILE=d+'/torrent')
   env['HG_MONITOR_GENERATED_DIR']=d
   for name in ('socks_P8ART','socks_hLPwH'):
    Path(d+'/'+name+'.json').write_text('{}')
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
   if actions is not None:
    script=script.rsplit('hg_'+module+'_collect',1)[0]+actions
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
 def test_vpn_and_torrent_cache_invalidated_by_wan_context(self):
  for module in ('vpn','torrent'):
   with self.subTest(module=module):
    collect='hg_'+module+'_collect'
    actions='HG_NETWORK_PATH_CONTEXT=$(printf a | sha256sum | cut -d " " -f1); '+collect+'; '+collect+'; HG_NETWORK_PATH_CONTEXT=$(printf b | sha256sum | cut -d " " -f1); '+collect
    self.assertEqual(len(self.run_adapter(module,False,actions).splitlines()),2)
 def test_vpn_and_torrent_cache_invalidated_by_generated_config(self):
  for module,profile in [('vpn','socks_P8ART'),('torrent','socks_hLPwH')]:
   with self.subTest(module=module):
    collect='hg_'+module+'_collect'
    actions='HG_NETWORK_PATH_CONTEXT=$(printf a | sha256sum | cut -d " " -f1); '+collect+'; '+collect+'; printf "changed\\n" > "$HG_MONITOR_GENERATED_DIR/'+profile+'.json"; '+collect
    self.assertEqual(len(self.run_adapter(module,False,actions).splitlines()),2)
 def test_missing_wan_context_never_reuses_cache(self):
  for module in ('vpn','torrent'):
   with self.subTest(module=module):
    collect='hg_'+module+'_collect'
    self.assertEqual(len(self.run_adapter(module,False,'HG_NETWORK_PATH_CONTEXT=; '+collect+'; '+collect).splitlines()),2)
if __name__=='__main__': unittest.main()
