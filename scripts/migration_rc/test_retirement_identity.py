"""Run the production immutable-retirement source selector, not a copy."""
import json,subprocess,tempfile,unittest
from pathlib import Path
SOURCE=Path(__file__).with_name('rc-b.uc').read_text()
FUNCTION=SOURCE[SOURCE.index('function retirement_identity('):SOURCE.index('function retire(nonce,')]
class RetirementIdentity(unittest.TestCase):
 def gate(self,source,pin,archived=False,nonce='11111111-2222-3333-4444-555555555555'):
  with tempfile.TemporaryDirectory() as d:
   base=Path(d)/'state';where=Path(str(base)+'.retired.'+nonce) if archived else base
   where.mkdir();(where/'delivery.json').write_text(json.dumps(dict(source=source,manifest_sha256=pin)))
   program='import * as fs from "fs";function require(ok,why){if(!ok)die(why);} function read(p,mode,limit){return fs.readfile(p);} const owner=true;let base=ARGV[0];'+FUNCTION+'print(sprintf("%J",retirement_identity(ARGV[1])));'
   return subprocess.run(['ucode','-e',program,'--',str(base),nonce],capture_output=True,text=True,timeout=10)
 def test_both_accepted_immutable_packages_active_and_archived(self):
  pairs=[('908dd3222b81992d9fee056bd015a1266a0ce8d7','67b65f1ceabe1534ff74fba8f6c486e9d02bfce9a7e7999875bd11929df467a1'),('6b7d3ada6fe6b513e08db22469ccde10a6d47ee3','10a5ac968a539a9c0287d4b711f065acdc71d54382854803d1b3fc0b551b6501')]
  for source,pin in pairs:
   for archived in (False,True):
    with self.subTest(source=source,archived=archived):
     r=self.gate(source,pin,archived);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(json.loads(r.stdout),dict(source=source,pin=pin))
 def test_unknown_source_wrong_pin_and_nonce_refuse(self):
  for source,pin in [('f'*40,'a'*64),('6b7d3ada6fe6b513e08db22469ccde10a6d47ee3','f'*64),('908dd3222b81992d9fee056bd015a1266a0ce8d7','10a5ac968a539a9c0287d4b711f065acdc71d54382854803d1b3fc0b551b6501')]:
   self.assertNotEqual(self.gate(source,pin).returncode,0)
  self.assertNotEqual(self.gate('f'*40,'a'*64,nonce='bad').returncode,0)

 def test_live_gate_rechecked_before_retire_but_not_interrupted_recovery(self):
  block=SOURCE[SOURCE.index("if(op=='retire' || op=='retire-check' || op=='verify-retired') {"):SOURCE.index("if(op=='preflight' || op=='prepare') {")]
  for op in ('retire-check','retire','verify-retired'):
   for state in ('untouched','journal','journal-new','init','init-new','boot','archived'):
    with self.subTest(op=op,state=state):
     base='/etc/home-gateway-migration'
     paths=[] if state=='archived' else [base]
     extra={'journal':base+'/retirement.json','journal-new':base+'/retirement.json.new','init':'/etc/init.d/home-gateway-retirement','init-new':'/etc/init.d/home-gateway-retirement.new','boot':'/etc/rc.d/S07home-gateway-retirement'}
     if state in extra:paths.append(extra[state])
     program='let op='+json.dumps(op)+';let base='+json.dumps(base)+';let tx="fixture";let present='+json.dumps(paths)+';let fs={lstat:function(p){return index(present,p)>=0?{}:null;}};function require(ok,why){if(!ok)die(why);}function verify_asata_baseline(){print("GATE\\n");}function retire(a,b,c){return "archive";}'+block
     r=subprocess.run(['ucode','-e',program,'--','a','b','c','d'],capture_output=True,text=True,timeout=10)
     self.assertEqual(r.returncode,0,r.stderr)
     self.assertEqual('GATE' in r.stdout,op in ('retire-check','retire') and state=='untouched')
