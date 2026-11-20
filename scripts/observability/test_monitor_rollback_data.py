"""The exact installed baseline must consume new events/queue after rollback."""
import hashlib,json,os,subprocess,unittest
from pathlib import Path
import test_monitor_history as fixtures
ROOT=Path(__file__).resolve().parents[2]
PINS={'incidents.uc':'0296c322bcd3d079554cc2e78f4b90cba78a8a30c364eb5498d2062db9b30195',
      'notifications.uc':'d9f985b15ebd44ce1f4e9e82c7792adf49436cfdc8639c64019cb21fdfbaf5df'}
class RollbackDataTests(unittest.TestCase):
 def setUp(self):
  self.f=fixtures.MonitorHistoryTests('test_three_unique_failures_two_unique_successes_and_unknown'); self.f.setUp(); self.addCleanup(self.f.doCleanups)
 def legacy(self,name):
  seam=os.environ.get('HG_MONITOR_LEGACY_DIR')
  raw=(Path(seam)/name).read_bytes() if seam else subprocess.check_output(['git','-C',str(ROOT),'show','62b5c4a9f25bc657fa1456eeacdfdc9039648cae:src/usr/lib/home-gateway/'+name])
  self.assertEqual(hashlib.sha256(raw).hexdigest(),PINS[name])
  p=self.f.base/('legacy-'+name); p.write_bytes(raw); return p
 def module(self,path,mode):
  r=subprocess.run(['ucode',str(path),str(self.f.gateway),mode],env=self.f.env,capture_output=True,text=True,timeout=10)
  self.assertEqual(r.returncode,0,r.stderr); return r
 def test_baseline_replays_and_recovers_new_incident_without_rewinding_state(self):
  for t in (10,20,30): self.f.tick(t)
  self.module(ROOT/'src/usr/lib/home-gateway/notifications.uc','sync')
  incident=self.f.status()['active']['main']['incident_id']
  oldnotify=self.legacy('notifications.uc'); oldinc=self.legacy('incidents.uc')
  before=(self.f.base/'state/incidents.jsonl').read_bytes()
  self.module(oldnotify,'json'); self.module(oldnotify,'sync'); self.module(oldnotify,'compact')
  self.assertEqual((self.f.base/'state/incidents.jsonl').read_bytes(),before)
  self.assertEqual(json.loads(self.module(oldinc,'json').stdout)['active_count'],1)
  for t in (40,50):
   p=self.f.base/'health.json'; health=json.loads(p.read_text()); health['generated_at']['epoch']=1800000000+t
   health['components']['main']['state']='OK'; p.write_text(json.dumps(health)); self.module(oldinc,'tick')
  self.assertEqual(json.loads(self.module(oldinc,'json').stdout)['active_count'],0)
  self.module(oldnotify,'sync'); q=json.loads(self.module(oldnotify,'json').stdout)['notifications']
  self.assertEqual([x['status'] for x in q],['COALESCED','PENDING'])
  self.assertTrue(all(x['incident_id']==incident for x in q))
  self.module(ROOT/'src/usr/lib/home-gateway/notifications.uc','json')
if __name__=='__main__':unittest.main()
