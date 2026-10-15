"""Native guarded file/service stage and private-state non-replay contracts."""
import json,subprocess,unittest
from pathlib import Path
import test_native_controls
MOD=Path(__file__).with_name('migration-service.uc').resolve()
class PrivateHandoff(unittest.TestCase):
 def setUp(self):
  self.fixture=test_native_controls.Controls();self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
  self.root,self.base,self.bb=self.fixture.root,self.fixture.base,self.fixture.bb
  p=self.root/'usr/bin/ubus';p.write_text("#!/bin/sh\nprintf '{}\\n'\n");p.chmod(0o700)
  for d in ['etc/home-gateway','etc/home-gateway/secrets','tmp/home-gateway']:(self.root/d).mkdir(mode=0o700)
  for name in ['telegram.token','telegram.user_id','telegram.chat_id']:
   p=self.root/'etc/home-gateway/secrets'/name;p.write_text('public-fixture\n');p.chmod(0o600)
  for name in ['telegram.offset','telegram.callback']:
   p=self.root/'tmp/home-gateway'/name;p.write_text('42\n');p.chmod(0o644)
 def runuc(self,body):
  imports={'migration-state.uc':'open_state','migration-controls.uc':'prepare_controls,apply_controls','migration-coordinator.uc':'prepare_coordinator,rollback_coordinator','migration-terminal.uc':'prepare_service_coordinator,apply_service_coordinator,commit_service_coordinator,rollback_service_coordinator,complete_service_rollback','migration-service.uc':'capture_private_state,verify_private_state'}
  code=''.join('import { '+names+' } from '+json.dumps(str(MOD.with_name(file)))+';' for file,names in imports.items())+'let s=open_state(ARGV[0],false,ARGV[1]);'+body+';'
  return subprocess.run(['ucode','-e',code,'--',str(self.root),self.bb,str(self.fixture.source),self.fixture.pin],capture_output=True,text=True,timeout=45)
 def ok(self,body):
  p=self.runuc(body);self.assertEqual(p.returncode,0,p.stderr);return p
 def apply(self):
  self.ok('prepare_service_coordinator(ARGV[0],s,ARGV[1],ARGV[2],ARGV[3],"'+'c'*40+'");apply_controls(ARGV[0],s,ARGV[1]);apply_service_coordinator(ARGV[0],s,ARGV[1])')
 def test_stopped_service_apply_captures_private_bytes_without_start_ticket(self):
  self.apply();self.assertEqual((self.base/'phase').read_text(),'APPLYING\n');self.assertFalse((self.base/'service-check').exists())
  self.ok('verify_private_state(ARGV[0],s,ARGV[1],"apply",false)')
  for rel in ['etc/home-gateway/secrets/telegram.token','tmp/home-gateway/telegram.offset']:
   self.assertEqual((self.root/rel).read_bytes(),(self.base/'private-apply'/rel).read_bytes());self.assertEqual((self.base/'private-apply'/rel).stat().st_mode&0o777,0o600)
  self.ok('rollback_coordinator(ARGV[0],s,ARGV[1]);verify_private_state(ARGV[0],s,ARGV[1],"apply",false)')
  self.fixture.fixture.fixture.lab.assert_previous()
 def test_complete_stopped_service_transaction_commits_and_rolls_back(self):
  self.apply();self.ok('commit_service_coordinator(ARGV[0],s,ARGV[1])')
  self.assertEqual((self.base/'phase').read_text(),'COMMITTED\n')
  self.ok('rollback_service_coordinator(ARGV[0],s,ARGV[1]);complete_service_rollback(ARGV[0],s,ARGV[1])')
  self.assertEqual((self.base/'phase').read_text(),'ROLLED_BACK\n')
  self.fixture.fixture.fixture.lab.assert_previous()
 def test_running_worker_cursor_is_never_rewound(self):
  self.apply();p=self.root/'tmp/home-gateway/telegram.offset';p.write_text('999\n')
  self.ok('verify_private_state(ARGV[0],s,ARGV[1],"apply",true)')
  self.assertNotEqual(self.runuc('verify_private_state(ARGV[0],s,ARGV[1],"apply",false)').returncode,0)
  self.ok('capture_private_state(ARGV[0],s,ARGV[1],"rollback");rollback_coordinator(ARGV[0],s,ARGV[1]);verify_private_state(ARGV[0],s,ARGV[1],"rollback",false)')
  self.assertEqual(p.read_text(),'999\n')
 def test_interrupted_apply_private_checkpoint_does_not_prevent_rollback(self):
  self.apply();(self.base/'private-apply.json').unlink()
  self.ok('rollback_service_coordinator(ARGV[0],s,ARGV[1]);complete_service_rollback(ARGV[0],s,ARGV[1])')
  self.fixture.fixture.fixture.lab.assert_previous()
 def test_secret_drift_refuses_even_after_service_start(self):
  self.apply();p=self.root/'etc/home-gateway/secrets/telegram.token';p.write_text('changed\n')
  self.assertNotEqual(self.runuc('verify_private_state(ARGV[0],s,ARGV[1],"apply",true)').returncode,0)
  self.assertEqual(p.read_text(),'changed\n')
 def test_symlink_private_input_refused_without_touching_foreign_target(self):
  p=self.root/'etc/home-gateway/secrets/telegram.token';p.unlink();foreign=self.root/'foreign';foreign.write_text('untouched');p.symlink_to(foreign)
  self.assertNotEqual(self.runuc('capture_private_state(ARGV[0],s,ARGV[1],"apply")').returncode,0);self.assertEqual(foreign.read_text(),'untouched')
 def test_corrupt_snapshot_and_repeat_capture_fail_closed(self):
  self.ok('capture_private_state(ARGV[0],s,ARGV[1],"apply")')
  self.assertNotEqual(self.runuc('capture_private_state(ARGV[0],s,ARGV[1],"apply")').returncode,0)
  (self.base/'private-apply/etc/home-gateway/secrets/telegram.token').write_text('foreign')
  self.assertNotEqual(self.runuc('verify_private_state(ARGV[0],s,ARGV[1],"apply",true)').returncode,0)
if __name__=='__main__':unittest.main()
