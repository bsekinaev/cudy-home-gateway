"""Execute the actual native RC-B predicates without router I/O or overrides."""
import json,subprocess,unittest
from pathlib import Path
SOURCE=Path(__file__).with_name('rc-b.uc').read_text()
# Extract the production functions verbatim; no reimplementation of predicates.
PREDICATES=SOURCE[SOURCE.index('function verify_owner_hardware('):SOURCE.index('// End hardware predicates.')]
class TargetHardware(unittest.TestCase):
 def run_gate(self,model='Cudy TR3000 256MB v1',target='mediatek/filogic',total=496724,available=253116,raw=None):
  board={'model':model,'release':{'target':target}}
  mem=raw if raw is not None else f'MemTotal:       {total} kB\nMemFree:        207192 kB\nMemAvailable:   {available} kB\n'
  program='function require(ok,why){if(!ok)die("RC_B_REFUSED_"+why);}\n'+PREDICATES+'\nverify_owner_hardware(json(ARGV[0]),ARGV[1]);verify_available_memory(ARGV[1]);print("PASS\\n");'
  return subprocess.run(['ucode','-e',program,'--',json.dumps(board),mem],capture_output=True,text=True,timeout=10)
 def test_owner_observation_512mb_ram_passes(self):
  r=self.run_gate();self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout,'PASS\n')
 def test_supported_model_spellings_and_ram_boundaries(self):
  for model in ('Cudy TR3000 v1','Cudy TR3000 256MB v1'):
   for total in (450000,496724,524288):
    with self.subTest(model=model,total=total):self.assertEqual(self.run_gate(model=model,total=total).returncode,0)
 def test_other_models_refused_despite_sufficient_memory(self):
  for model in ('Cudy TR3000 v2','Cudy WR3000 v1','Cudy TR3000','Other TR3000 256MB v1',''):
   with self.subTest(model=model):
    r=self.run_gate(model=model);self.assertNotEqual(r.returncode,0);self.assertIn('TARGET_MODEL',r.stderr)
 def test_other_platforms_refused(self):
  for target in ('x86/64','mediatek/mt7622','mediatek/filogic-extra',''):
   with self.subTest(target=target):
    r=self.run_gate(target=target);self.assertNotEqual(r.returncode,0);self.assertIn('TARGET_PLATFORM',r.stderr)
 def test_wrong_ram_class_and_out_of_bounds_refused(self):
  for total in (0,253116,449999,524289,1048576):
   with self.subTest(total=total):
    r=self.run_gate(total=total);self.assertNotEqual(r.returncode,0);self.assertIn('TARGET_MEMORY',r.stderr)
 def test_available_memory_budget_unchanged(self):
  self.assertEqual(self.run_gate(available=32768).returncode,0)
  for available in (0,32767):
   with self.subTest(available=available):
    r=self.run_gate(available=available);self.assertNotEqual(r.returncode,0);self.assertIn('MEMORY_BUDGET',r.stderr)
 def test_missing_malformed_and_spoofed_fields_refused(self):
  for raw in ('MemAvailable: 253116 kB\n','MemTotal: 496724 MB\nMemAvailable: 253116 kB\n','FakeMemTotal: 496724 kB\nMemAvailable: 253116 kB\n','MemTotal: 496724 kB\n','MemTotal: 496724 kB\nFakeMemAvailable: 253116 kB\n'):
   with self.subTest(raw=raw):self.assertNotEqual(self.run_gate(raw=raw).returncode,0)
 def test_production_entrypoint_uses_the_tested_predicates(self):
  self.assertIn("verify_owner_hardware(b,fs.readfile('/proc/meminfo')??'');",SOURCE)
  self.assertIn("verify_available_memory(fs.readfile('/proc/meminfo')??'');",SOURCE)
  for name in ('OPENWRT_VERSION','BUSYBOX_VERSION','PROCD_PID1'):self.assertIn(name,SOURCE)
if __name__=='__main__':unittest.main()
