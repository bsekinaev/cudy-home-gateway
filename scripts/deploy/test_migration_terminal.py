"""Terminal receipts require exact file/journal/control and stopped-service proof."""
import json,os,subprocess,unittest
from pathlib import Path
import test_native_controls
MOD=Path(__file__).with_name('migration-terminal.uc').resolve()
class Terminal(unittest.TestCase):
 def setUp(self):
  self.fixture=test_native_controls.Controls();self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
  self.root,self.base,self.bb=self.fixture.root,self.fixture.base,self.fixture.bb
  p=self.root/'usr/bin/ubus';p.write_text('#!/bin/sh\nprintf \'{}\\n\'\n');p.chmod(0o700)
  self.ok('prepare_controls(ARGV[0],s,ARGV[1],ARGV[2],ARGV[3]);prepare_coordinator(ARGV[0],s,ARGV[1],"'+'c'*40+'",0);apply_controls(ARGV[0],s,ARGV[1]);apply_coordinator(ARGV[0],s,ARGV[1])')
 def runuc(self,body):
  imports={'migration-state.uc':'open_state','migration-controls.uc':'prepare_controls,apply_controls,restore_controls','migration-coordinator.uc':'prepare_coordinator,apply_coordinator,rollback_coordinator','migration-terminal.uc':'commit_migration,complete_rollback'}
  script=''.join('import { '+names+' } from '+json.dumps(str(MOD.with_name(file)))+'; ' for file,names in imports.items())+'let s=open_state(ARGV[0],false,ARGV[1]);'+body+';'
  return subprocess.run(['ucode','-e',script,'--',str(self.root),self.bb,str(self.fixture.source),self.fixture.pin],capture_output=True,text=True,timeout=45)
 def ok(self,body):
  p=self.runuc(body);self.assertEqual(p.returncode,0,p.stderr);return p
 def test_commit_and_rollback_admit_only_verified_terminal_trees(self):
  self.ok('commit_migration(ARGV[0],s,ARGV[1])');self.assertEqual((self.base/'phase').read_text(),'COMMITTED\n');self.assertFalse((self.root/'tmp/home-gateway-deploy.lock').is_symlink())
  self.ok('commit_migration(ARGV[0],s,ARGV[1])')
  self.ok('rollback_coordinator(ARGV[0],s,ARGV[1]);restore_controls(ARGV[0],s,ARGV[1],true);complete_rollback(ARGV[0],s,ARGV[1],true)')
  self.assertEqual((self.base/'phase').read_text(),'ROLLED_BACK\n');self.assertFalse((self.root/'tmp/home-gateway-deploy.lock').is_symlink())
  self.ok('complete_rollback(ARGV[0],s,ARGV[1],true)');self.fixture.fixture.fixture.lab.assert_previous()
 def test_completion_modules_retained_until_terminal_rollback_admission(self):
  self.ok('commit_migration(ARGV[0],s,ARGV[1]);rollback_coordinator(ARGV[0],s,ARGV[1]);restore_controls(ARGV[0],s,ARGV[1],true)')
  base=self.root/'usr/libexec/home-gateway-deploy'
  for name in ['migration-terminal.uc','migration-service.uc','migration-controls.uc','migration-snapshot.uc']:
   self.assertTrue((base/name).exists(),name)
  self.ok('complete_rollback(ARGV[0],s,ARGV[1],true)')
  self.assertFalse((base/'migration-terminal.uc').exists());self.assertTrue((base/'migration-state.uc').exists())
 def test_unknown_admission_refuses_before_terminal_transition(self):
  p=self.base/'admission.new';p.write_bytes(b'FOREIGN');p.chmod(0o600)
  self.assertNotEqual(self.runuc('commit_migration(ARGV[0],s,ARGV[1])').returncode,0)
  self.assertEqual((self.base/'phase').read_text(),'APPLYING\n');self.assertEqual(p.read_bytes(),b'FOREIGN');self.assertFalse((self.base/'admission').exists())
 def test_retained_boot_guard_releases_only_verified_rolled_back_admission(self):
  self.ok('commit_migration(ARGV[0],s,ARGV[1]);rollback_coordinator(ARGV[0],s,ARGV[1]);restore_controls(ARGV[0],s,ARGV[1],true);complete_rollback(ARGV[0],s,ARGV[1],true)')
  state=self.root/'usr/libexec/home-gateway-deploy/migration-state.uc'
  self.assertTrue(state.exists());self.assertTrue((self.root/'etc/rc.d/S08home-gateway-migration').is_symlink())
  code='import {restore_boot_fence} from '+json.dumps(str(state))+';print(restore_boot_fence(ARGV[0],ARGV[1]));'
  p=subprocess.run(['ucode','-e',code,'--',str(self.root),self.bb],capture_output=True,text=True,timeout=15)
  self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout,'ROLLED_BACK')
  self.assertFalse((self.root/'tmp/home-gateway-deploy.lock').is_symlink())
  (self.base/'admission').unlink()
  p=subprocess.run(['ucode','-e',code,'--',str(self.root),self.bb],capture_output=True,text=True,timeout=15)
  self.assertNotEqual(p.returncode,0);self.assertTrue((self.root/'tmp/home-gateway-deploy.lock').is_symlink())
 def test_new_deployment_refusal_preserves_committed_phase(self):
  self.ok('commit_migration(ARGV[0],s,ARGV[1])')
  latest=self.root/'etc/home-gateway-deploy/latest';original=latest.read_bytes();latest.write_bytes(b'tx.foreign\n')
  self.assertNotEqual(self.runuc('rollback_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
  self.assertEqual((self.base/'phase').read_bytes(),b'COMMITTED\n');self.assertEqual(latest.read_bytes(),b'tx.foreign\n')
  latest.write_bytes(original)
  rel='usr/bin/gateway';(self.root/rel).write_bytes((self.base/'old/runtime'/rel).read_bytes())
  self.assertNotEqual(self.runuc('rollback_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
  self.assertEqual((self.base/'phase').read_bytes(),b'COMMITTED\n')
 def test_known_partial_receipt_recovery_preserves_evidence(self):
  p=self.base/'admission.new';p.write_bytes(b'HG_MIGRATION_ADMITTED_V2 COM');p.chmod(0o600)
  self.ok('commit_migration(ARGV[0],s,ARGV[1])');self.assertEqual((self.base/'admission.interrupted').read_bytes(),b'HG_MIGRATION_ADMITTED_V2 COM')
  self.ok('rollback_coordinator(ARGV[0],s,ARGV[1]);restore_controls(ARGV[0],s,ARGV[1],true)')
  p.write_bytes(b'HG_MIGRATION_ADMITTED_V2 ROLL');p.chmod(0o600)
  self.ok('complete_rollback(ARGV[0],s,ARGV[1],true)');self.assertTrue((self.base/'admission.interrupted.1').exists())
if __name__=='__main__':unittest.main()
