"""Native guarded file/service stage and private-state non-replay contracts."""
import json,subprocess,unittest,os,signal,time,shlex
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
 def command(self,body,bb=None,recovery=False):
  imports={'migration-state.uc':'open_state,open_rollback_state','migration-controls.uc':'prepare_controls,apply_controls','migration-coordinator.uc':'prepare_coordinator,rollback_coordinator','migration-terminal.uc':'prepare_service_coordinator,apply_service_coordinator,commit_service_coordinator,rollback_service_coordinator,complete_service_rollback,abort_service_preparation,complete_preparation_abort','migration-service.uc':'capture_private_state,verify_private_state'}
  code=''.join('import { '+names+' } from '+json.dumps(str(MOD.with_name(file)))+';' for file,names in imports.items())+('let s=open_rollback_state(ARGV[0],ARGV[1]);' if recovery else 'let s=open_state(ARGV[0],false,ARGV[1]);')+body+';'
  return ['ucode','-e',code,'--',str(self.root),bb or self.bb,str(self.fixture.source),self.fixture.pin]
 def runuc(self,body,bb=None,recovery=False):
  return subprocess.run(self.command(body,bb,recovery),capture_output=True,text=True,timeout=45)
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
 def test_later_deployment_refuses_without_fencing_or_stopping_service(self):
  self.apply();self.ok('commit_service_coordinator(ARGV[0],s,ARGV[1])')
  latest=self.root/'etc/home-gateway-deploy/latest';previous=latest.read_bytes();latest.write_text('tx.newer\n')
  ram=self.root/'tmp/home-gateway-deploy.lock';self.assertFalse(ram.is_symlink())
  self.assertNotEqual(self.runuc('rollback_service_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
  self.assertFalse(ram.is_symlink());self.assertEqual(latest.read_text(),'tx.newer\n');self.assertEqual((self.base/'phase').read_text(),'COMMITTED\n')
  latest.write_bytes(previous);(self.root/'usr/bin/gateway').write_bytes((self.base/'old/runtime/usr/bin/gateway').read_bytes())
  self.assertNotEqual(self.runuc('rollback_service_coordinator(ARGV[0],s,ARGV[1])').returncode,0);self.assertFalse(ram.is_symlink());self.assertEqual((self.base/'phase').read_text(),'COMMITTED\n')
 def test_private_checkpoint_published_before_plan_can_abort_without_live_rewrites(self):
  before={p:(self.root/p).stat().st_ino for p in self.fixture.fixture.fixture.lab.previous}
  self.ok('capture_private_state(ARGV[0],s,ARGV[1],"prepare")')
  self.assertFalse((self.base/'coordinator.json').exists())
  self.ok('abort_service_preparation(ARGV[0],s,ARGV[1]);complete_preparation_abort(ARGV[0],s,ARGV[1])')
  self.assertEqual((self.base/'phase').read_text(),'ROLLED_BACK\n');self.assertFalse((self.root/'tmp/home-gateway-deploy.lock').is_symlink())
  self.assertEqual(before,{p:(self.root/p).stat().st_ino for p in before})
  self.ok('complete_preparation_abort(ARGV[0],s,ARGV[1])')
 def test_control_prepare_failure_before_plan_can_abort(self):
  self.assertNotEqual(self.runuc('prepare_service_coordinator(ARGV[0],s,ARGV[1],ARGV[2],"'+'0'*64+'","'+'c'*40+'")').returncode,0)
  self.assertTrue((self.base/'private-prepare.json').exists());self.assertFalse((self.base/'coordinator.json').exists())
  self.ok('abort_service_preparation(ARGV[0],s,ARGV[1]);complete_preparation_abort(ARGV[0],s,ARGV[1])')
  self.fixture.fixture.fixture.lab.assert_previous()
 def test_preparation_abort_rejects_live_control_publication(self):
  p=self.root/'usr/libexec/home-gateway-deploy/migration-service.uc';p.write_text('foreign');p.chmod(0o600)
  self.assertNotEqual(self.runuc('abort_service_preparation(ARGV[0],s,ARGV[1])').returncode,0)
  self.assertEqual((self.base/'phase').read_text(),'PREPARING\n');self.assertEqual(p.read_text(),'foreign')
 def test_original_telegram_boot_enablement_is_quarantined_until_terminal_admission(self):
  link=self.root/'etc/rc.d/S95home-gateway-telegram';link.symlink_to('../init.d/home-gateway-telegram')
  self.apply();self.assertFalse(link.is_symlink())
  self.ok('commit_service_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(link.readlink(),Path('../init.d/home-gateway-telegram'))
  self.ok('rollback_service_coordinator(ARGV[0],s,ARGV[1])');self.assertFalse(link.is_symlink())
  self.assertTrue((self.root/'usr/libexec/home-gateway-deploy/migration-terminal.uc').exists())
  self.ok('complete_service_rollback(ARGV[0],s,ARGV[1])');self.assertEqual(link.readlink(),Path('../init.d/home-gateway-telegram'))
  self.assertFalse((self.root/'usr/libexec/home-gateway-deploy/migration-terminal.uc').exists())
 def test_incomplete_initial_snapshot_can_abort_without_adopting_its_private_files(self):
  (self.base/'snapshot.json').unlink();(self.base/'candidate.json').unlink()
  partial=self.base/'old/runtime/usr/bin/gateway';partial.write_bytes(b'partial-preserved')
  self.ok('abort_service_preparation(ARGV[0],s,ARGV[1]);complete_preparation_abort(ARGV[0],s,ARGV[1])')
  self.assertEqual(partial.read_bytes(),b'partial-preserved');self.fixture.fixture.fixture.lab.assert_previous()
 def test_corrupt_published_snapshot_prevents_preparation_abort(self):
  (self.base/'old/runtime/usr/bin/gateway').write_bytes(b'corrupt')
  self.assertNotEqual(self.runuc('abort_service_preparation(ARGV[0],s,ARGV[1])').returncode,0)
  self.assertEqual((self.base/'phase').read_text(),'PREPARING\n')
 def test_interrupted_committed_to_restoring_requires_explicit_recovery(self):
  self.apply();self.ok('commit_service_coordinator(ARGV[0],s,ARGV[1])')
  pending=self.base/'phase.new';pending.write_bytes(b'RESTO');pending.chmod(0o600)
  self.assertNotEqual(self.runuc('rollback_service_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
  p=self.runuc('rollback_service_coordinator(ARGV[0],s,ARGV[1])',recovery=True);self.assertEqual(p.returncode,0,p.stderr)
  self.ok('complete_service_rollback(ARGV[0],s,ARGV[1])');self.assertEqual((self.base/'phase.interrupted').read_bytes(),b'RESTO')
  self.assertEqual((self.base/'phase').read_text(),'ROLLED_BACK\n');self.assertFalse((self.root/'tmp/home-gateway-deploy.lock').is_symlink())
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
 def interrupt(self,body,label):
  ready=self.root/'private-checkpoint-blocked';shim=self.root/'private-fsync-block'
  shim.write_text('#!/bin/sh\ncase "$*" in *"/private-'+label+'/etc/home-gateway/secrets/telegram.token"*) : > '+shlex.quote(str(ready))+'; sleep 30;; esac\nexec '+shlex.quote(self.bb)+' "$@"\n');shim.chmod(0o700)
  child=subprocess.Popen(self.command(body,str(shim)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
  try:
   deadline=time.monotonic()+10
   while not ready.exists() and child.poll() is None and time.monotonic()<deadline:time.sleep(.02)
   self.assertTrue(ready.exists(),label)
  finally:
   try:os.killpg(child.pid,signal.SIGKILL)
   except ProcessLookupError:pass
   child.communicate(timeout=5)
 def test_sigkill_private_apply_checkpoint_allows_only_verified_rollback(self):
  self.ok('prepare_service_coordinator(ARGV[0],s,ARGV[1],ARGV[2],ARGV[3],"'+'c'*40+'");apply_controls(ARGV[0],s,ARGV[1])')
  self.interrupt('apply_service_coordinator(ARGV[0],s,ARGV[1])','apply')
  self.assertFalse((self.base/'private-apply.json').exists());self.assertFalse((self.base/'admission').exists())
  self.assertNotEqual(self.runuc('apply_service_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
  self.ok('rollback_service_coordinator(ARGV[0],s,ARGV[1]);complete_service_rollback(ARGV[0],s,ARGV[1])')
  self.fixture.fixture.fixture.lab.assert_previous()
 def test_sigkill_private_rollback_checkpoint_can_resume_known_partial_snapshot(self):
  self.apply();self.ok('commit_service_coordinator(ARGV[0],s,ARGV[1])')
  self.interrupt('rollback_service_coordinator(ARGV[0],s,ARGV[1])','rollback')
  self.assertFalse((self.base/'private-rollback.json').exists())
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
