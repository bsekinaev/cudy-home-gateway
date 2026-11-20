"""Exercise the real publish function against an executable gateway boundary."""
import json, shutil, subprocess, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
@unittest.skipUnless(shutil.which('ucode'),'ucode required')
class MonitorPublishTests(unittest.TestCase):
 def test_gateway_publish_and_recovery_keep_executable_mode(self):
  raw=(ROOT/'scripts/owner_series/engine.uc').read_text()
  fn=raw[raw.index('function publish('):raw.index('function raw_active(')]
  for recovering in (False,True):
   code='import * as p from '+json.dumps(str(ROOT/'scripts/owner_series/protocol.uc'))+';let runtime_mode=p.runtime_mode;'+r'''
function need(ok,why){if(!ok)die(why);}
let created=false, published=false;
const m={inventories:{baseline:{'usr/bin/gateway':'old'},candidate:{'usr/bin/gateway':'new'}},changed:['usr/bin/gateway'],profile:'OWNER_MANUAL'};
const fs={lsdir:function(path){return [];}};
const kit='/kit',J='/journal',own_pid=123;
const io={hash:function(path,mode,limit){need(mode==0755,'READ_EXECUTABLE_MODE');return 'old';},
 read:function(path,mode,limit){need(mode==0755,'PACKAGE_EXECUTABLE_MODE');return 'new bytes';},
 exists:function(path){return false;},
 exclusive:function(path,bytes,mode){need(mode==0755,'WRITE_EXECUTABLE_MODE');created=true;},
 rename:function(a,b,replace){need(created && b=='/usr/bin/gateway' && replace,'PUBLICATION');published=true;}};
const protocol={runtime:function(inventory){need(published,'NOT_PUBLISHED');}};
function hook(point){}
''' + fn + ('publish("candidate",'+('true' if recovering else 'false')+');')
   r=subprocess.run(['ucode','-e',code],capture_output=True,text=True,timeout=5)
   self.assertEqual(r.returncode,0,r.stderr)
if __name__=='__main__': unittest.main()
