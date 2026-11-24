import json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
COLLECTOR=ROOT/'scripts/observability/router-call-probe.uc'
SOURCE='d'*40
@unittest.skipUnless(os.name!='nt' and shutil.which('ucode'),'POSIX ucode required')
class CallProbeTests(unittest.TestCase):
 def collect(self,uci=None,config=None,nft=None,raw=None,unsafe=None,nested=False):
  with tempfile.TemporaryDirectory() as tmp:
   b=Path(tmp);cfg=b/'configs';cfg.mkdir()
   values={'passwall2.@global[0].client_proxy':'1','passwall2.@global_forwarding[0].udp_no_redir_ports':'','passwall2.@global_forwarding[0].udp_redir_ports':'1:65535','passwall2.rulenode.default_node':'main_test','passwall2.acl_A2dNs.enabled':'1'}
   values.update(uci or {})
   (b/'values').write_text(json.dumps(values))
   if config is None:config={'inbounds':[{'protocol':'dokodemo-door','settings':{'network':'tcp,udp'},'streamSettings':{'sockopt':{'tproxy':'tproxy'}}}],'outbounds':[{'tag':'proxy','protocol':'vless','settings':{'vnext':[{'address':'203.0.113.5','users':[{'id':'PRIVATE_UUID'}]}]},'streamSettings':{'network':'grpc','realitySettings':{'publicKey':'SECRET_KEY','serverName':'SECRET_HOST'}}}],'routing':{'rules':[]}}
   (cfg/'main_test.json').write_text(raw if raw is not None else json.dumps(config))
   if nested:
    (cfg/'acl').mkdir()
    modern={'inbounds':[{'protocol':'tunnel','settings':{'allowedNetwork':'udp','followRedirect':True},'streamSettings':{'sockopt':{'tproxy':'tproxy'}}}], 'outbounds':[{'protocol':'vless','streamSettings':{'method':'grpc'}}]}
    for name in ('default.json','acl_A2dNs.json'):
     (cfg/'acl'/name).write_text(json.dumps(modern))
   if unsafe=='writable':(cfg/'main_test.json').chmod(0o666)
   if unsafe=='symlink':
    target=b/'private.json';target.write_text(json.dumps(config));(cfg/'main_test.json').unlink();(cfg/'main_test.json').symlink_to(target)
   if nft is None:nft={'nftables':[{'rule':{'comment':'ASATA-UDP-DIRECT','expr':[{'match':{'op':'==','left':{'meta':{'key':'l4proto'}},'right':'udp'}},{'return':None}]}},{'rule':{'expr':[{'tproxy':{'port':1234}}]}}]}
   (b/'nft_data').write_text(json.dumps(nft))
   (b/'calls').write_text('')
   for tool in ('uci','nft','ip'):
    p=b/tool;p.write_text('#!/usr/bin/env python3\nimport sys,os,json\nfrom pathlib import Path\nb=Path(os.environ["HG_CALL_TEST"])\nwith (b/"calls").open("a") as f:f.write(" ".join(sys.argv)+"\\n")\nif Path(sys.argv[0]).name=="uci":\n data=json.loads((b/"values").read_text());key=sys.argv[-1]\n if key not in data:sys.exit(1)\n print(data[key])\nelif Path(sys.argv[0]).name=="nft":print((b/"nft_data").read_text())\nelse:print("")\n');p.chmod(0o755)
   env=dict(os.environ,PATH=tmp+os.pathsep+os.environ['PATH'],HG_CALL_TEST=tmp,HG_CALL_CONFIG_DIR=str(cfg))
   r=subprocess.run(['ucode',str(COLLECTOR),SOURCE],env=env,text=True,capture_output=True,timeout=20)
   self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stderr,'')
   lines=r.stdout.splitlines();self.assertEqual(len(lines),2);self.assertEqual(lines[0],'HG_CALL_READINESS_V1')
   data=json.loads(lines[1]);self.assertEqual(data['source_commit'],SOURCE)
   for secret in ('203.0.113.5','PRIVATE_UUID','SECRET_KEY','SECRET_HOST','main_test'):self.assertNotIn(secret,r.stdout)
   self.assertNotRegex((b/'calls').read_text(),r'uci .* (set|commit)|nft .* (add|delete|flush)|restart|curl|ping|ifdown|ifup')
   return data
 def test_safe_projection_and_udp_listener_config(self):
  r=self.collect();self.assertEqual(r['client_proxy_state'],'ENABLED');self.assertEqual(r['udp_redirect_mode'],'ALL');self.assertEqual(r['udp_exclusion_mode'],'EMPTY')
  self.assertEqual(r['call_connectivity'],'UNVERIFIED');c=r['configs'][0]
  self.assertEqual(c['role'],'MAIN_SOCKS');self.assertEqual(c['udp_transparent_inbounds'],1);self.assertEqual(c['proxy_protocols'],['vless']);self.assertEqual(c['proxy_transports'],['grpc'])
 def test_all_udp_excluded_is_reported_without_changing_settings(self):
  r=self.collect(uci={'passwall2.@global_forwarding[0].udp_no_redir_ports':'1:65535'})
  self.assertEqual(r['udp_exclusion_mode'],'ALL');self.assertEqual(r['asata_udp_direct_rule'],'PRESENT')
 def test_nested_acl_and_modern_xray_fields(self):
  r=self.collect(nested=True)
  by_role={c['role']:c for c in r['configs']}
  for role in ('GLOBAL','REDMI'):
   self.assertIn(role,by_role)
   self.assertEqual(by_role[role]['udp_transparent_inbounds'],1)
   self.assertEqual(by_role[role]['proxy_transports'],['grpc'])
 def test_socks_listener_not_confused_with_transparent_udp(self):
  r=self.collect(config={'inbounds':[{'protocol':'socks','settings':{'udp':True}}]})
  self.assertEqual(r['configs'][0]['udp_transparent_inbounds'],0)
 def test_broad_udp_direct_rule_is_exposed(self):
  r=self.collect(config={'outbounds':[{'tag':'direct','protocol':'freedom'}],'routing':{'rules':[{'type':'field','network':'udp','outboundTag':'direct'}]}})
  self.assertEqual(r['configs'][0]['broad_udp_direct_rule'],'PRESENT')
 def test_tcp_udp_broad_direct_rule_is_exposed(self):
  r=self.collect(config={'outbounds':[{'tag':'direct','protocol':'freedom'}],'routing':{'rules':[{'type':'field','network':'tcp,udp','outboundTag':'direct'}]}})
  self.assertEqual(r['configs'][0]['broad_udp_direct_rule'],'PRESENT')
 def test_negated_udp_rule_is_not_udp_bypass(self):
  r=self.collect(nft={'nftables':[{'rule':{'comment':'ASATA-UDP-DIRECT','expr':[{'match':{'op':'!=','left':{'meta':{'key':'l4proto'}},'right':'udp'}},{'return':None}]}}]})
  self.assertEqual(r['udp_match_rules'],0);self.assertEqual(r['asata_udp_direct_rule'],'ABSENT')
 def test_destination_limited_udp_rule_not_called_broad(self):
  r=self.collect(config={'outbounds':[{'tag':'direct','protocol':'freedom'}],'routing':{'rules':[{'type':'field','network':'udp','ip':['geoip:private'],'outboundTag':'direct'}]}})
  self.assertEqual(r['configs'][0]['broad_udp_direct_rule'],'ABSENT')
 def test_missing_settings_and_malformed_configs_are_unknown(self):
  for raw in ('{bad','[]',' '*262145):
   with self.subTest(raw=raw[:8]):
    r=self.collect(raw=raw);self.assertEqual(r['configs'][0]['config_state'],'UNREADABLE')
 def test_untrusted_port_strings_not_echoed_or_accepted(self):
  for value in ('SECRET_KEY','0','70000','99:1'):
   r=self.collect(uci={'passwall2.@global_forwarding[0].udp_redir_ports':value});self.assertEqual(r['udp_redirect_mode'],'UNKNOWN')
 def test_unsafe_config_files_not_read(self):
  for kind in ('writable','symlink'):
   r=self.collect(unsafe=kind);self.assertEqual(r['configs'][0]['config_state'],'UNSAFE');self.assertIsNone(r['configs'][0]['udp_transparent_inbounds'])
 def test_failed_or_missing_uci_read_not_assumed_inherited(self):
  r=self.collect();self.assertEqual(r['redmi_udp_exclusion_mode'],'UNKNOWN');self.assertEqual(r['redmi_udp_redirect_mode'],'UNKNOWN')
 def test_missing_firewall_not_zero_rules(self):
  r=self.collect(nft={});self.assertEqual(r['firewall_state'],'UNKNOWN');self.assertIsNone(r['tproxy_rules'])
if __name__=='__main__':unittest.main()
