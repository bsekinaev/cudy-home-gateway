"""Native control publication on real filesystems/processes; production blocked."""
import hashlib,json,os
from pathlib import Path
import subprocess,unittest
import test_native_runtime

MODULE=Path(__file__).with_name('migration-controls.uc').resolve()
FILES={**{'usr/libexec/home-gateway-deploy/'+p:0o600 for p in ('migration-state.uc','migration-snapshot.uc','migration-candidate.uc','migration-runtime.uc','migration-handoff.uc','migration-coordinator.uc','migration-controls.uc')},'usr/libexec/home-gateway-deploy/migration-admission.sh':0o700,'etc/init.d/home-gateway-migration':0o755}
BOOT='etc/rc.d/S08home-gateway-migration'
class Controls(unittest.TestCase):
 def setUp(self):
  self.fixture=test_native_runtime.NativeRuntimeTests('test_actual_18_to_20_to_18_preserves_legacy_journal_and_latest');self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
  self.root,self.base,self.bb=self.fixture.root,self.fixture.base,self.fixture.bb
  (self.root/'etc/rc.d').mkdir(mode=0o755)
  self.source=self.root/'control-input';self.source.mkdir(mode=0o700)
  for rel,mode in FILES.items():
   p=self.source/rel;p.parent.mkdir(parents=True,exist_ok=True)
   p.write_bytes(MODULE.with_name('migration-boot.init' if rel.endswith('/home-gateway-migration') else Path(rel).name).read_bytes());p.chmod(mode)
  for p in self.source.rglob('*'):
   if p.is_dir():p.chmod(0o700)
  raw=''.join(hashlib.sha256((self.source/p).read_bytes()).hexdigest()+'  '+p+'\n' for p in FILES).encode()
  (self.source/'controls.sha256').write_bytes(raw);(self.source/'controls.sha256').chmod(0o600);self.pin=hashlib.sha256(raw).hexdigest()
 def runuc(self,body):
  script='import { open_state } from '+json.dumps(str(MODULE.with_name('migration-state.uc')))+'; import { prepare_runtime,apply_runtime,restore_runtime } from '+json.dumps(str(MODULE.with_name('migration-runtime.uc')))+'; import { prepare_controls,apply_controls,restore_controls,verify_controls } from '+json.dumps(str(MODULE))+'; let s=open_state(ARGV[0],false,ARGV[1]); '+body+';'
  return subprocess.run(['ucode','-e',script,'--',str(self.root),self.bb,str(self.source),self.pin],capture_output=True,text=True,timeout=30)
 def ok(self,body):
  r=self.runuc(body);self.assertEqual(r.returncode,0,r.stderr)
 def prepare(self):self.ok('prepare_controls(ARGV[0],s,ARGV[1],ARGV[2],ARGV[3]);prepare_runtime(ARGV[0],s,ARGV[1])')
 def test_real_control_apply_verify_restore_repeat(self):
  self.prepare();self.ok('apply_controls(ARGV[0],s,ARGV[1]);verify_controls(ARGV[0],s,ARGV[1])')
  self.assertTrue((self.root/BOOT).is_symlink())
  self.ok('apply_runtime(ARGV[0],s,ARGV[1]);restore_runtime(ARGV[0],s,ARGV[1]);restore_controls(ARGV[0],s,ARGV[1]);restore_controls(ARGV[0],s,ARGV[1])')
  for rel in FILES:self.assertFalse((self.root/rel).exists())
  self.assertFalse((self.root/BOOT).is_symlink());self.fixture.fixture.lab.assert_previous()
 def test_unknown_existing_control_refuses_before_snapshot(self):
  p=self.root/next(iter(FILES));p.write_bytes(b'foreign');p.chmod(0o600)
  self.assertNotEqual(self.runuc('prepare_controls(ARGV[0],s,ARGV[1],ARGV[2],ARGV[3])').returncode,0)
  self.assertFalse((self.base/'controls.json').exists());self.assertEqual(p.read_bytes(),b'foreign')
 def test_live_drift_refuses_restore_before_boot_removal(self):
  self.prepare();self.ok('apply_controls(ARGV[0],s,ARGV[1])')
  p=self.root/next(iter(FILES));p.write_bytes(b'foreign')
  self.assertNotEqual(self.runuc('restore_controls(ARGV[0],s,ARGV[1])').returncode,0);self.assertTrue((self.root/BOOT).is_symlink())
 def test_partial_owned_pending_is_recovered_and_foreign_pending_refused(self):
  self.prepare();rel=next(iter(FILES));p=self.base/'control-pending'/rel.replace('/','_');p.write_bytes((self.source/rel).read_bytes()[:20]);p.chmod(FILES[rel])
  self.ok('apply_controls(ARGV[0],s,ARGV[1])')
  p.write_bytes(b'foreign');p.chmod(FILES[rel]);self.assertNotEqual(self.runuc('restore_controls(ARGV[0],s,ARGV[1])').returncode,0);self.assertTrue((self.root/BOOT).is_symlink())
 def test_corrupt_saved_control_cannot_publish(self):
  self.prepare();p=self.base/'controls'/next(iter(FILES));p.write_bytes(b'foreign')
  self.assertNotEqual(self.runuc('apply_controls(ARGV[0],s,ARGV[1])').returncode,0)
  self.assertFalse((self.root/BOOT).is_symlink())
 def test_control_source_extra_and_hardlink_refused(self):
  p=self.source/'extra';p.write_bytes(b'foreign');self.assertNotEqual(self.runuc('prepare_controls(ARGV[0],s,ARGV[1],ARGV[2],ARGV[3])').returncode,0);p.unlink()
  q=self.source/next(iter(FILES));os.link(q,self.root/'external-link');self.assertNotEqual(self.runuc('prepare_controls(ARGV[0],s,ARGV[1],ARGV[2],ARGV[3])').returncode,0)

if __name__=='__main__':unittest.main()
