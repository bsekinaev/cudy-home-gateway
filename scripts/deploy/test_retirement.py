"""Native explicit retirement preserves snapshots and the original guard."""
import json,os,shlex,subprocess,unittest,signal,time
from pathlib import Path
import test_private_handoff
MOD=Path(__file__).with_name('migration-retirement.uc').resolve()
class Retirement(unittest.TestCase):
 def setUp(self):
  self.f=test_private_handoff.PrivateHandoff();self.f.setUp();self.addCleanup(self.f.doCleanups)
  self.f.apply();self.f.ok('rollback_service_coordinator(ARGV[0],s,ARGV[1]);complete_service_rollback(ARGV[0],s,ARGV[1])')
  self.root,self.base,self.bb=self.f.root,self.f.base,self.f.bb
  self.nonce=(self.base/'marker').read_text().split()[1]
  self.pin='a'*64;self.source='c'*40
  self.lock=self.root/'etc/home-gateway-migration.lock';self.inode=self.lock.stat().st_ino
  self.archive=self.base.with_name(self.base.name+'.retired.'+self.nonce)
  self.put('delivery.json',json.dumps(dict(format='HG_DELIVERY_B_RECORD_V1',source=self.source,manifest_sha256=self.pin,marker=(self.base/'marker').read_text(),guard_inode=self.inode,profile='B_VM_ACCEPTANCE',boot_id='11111111-2222-3333-4444-555555555555')))
 def put(self,name,raw):
  p=self.base/name;p.write_text(raw);p.chmod(0o600)
 def runret(self,mutate=True,nonce=None,bb=None,background=False):
  code='import {retire_rolled_back} from '+json.dumps(str(MOD))+';print(retire_rolled_back(ARGV[0],ARGV[1],ARGV[2],ARGV[3],ARGV[4],'+str(mutate).lower()+'));'
  args=['ucode','-e',code,'--',str(self.root),bb or self.bb,nonce or self.nonce,self.source,self.pin]
  body='exec 8< '+shlex.quote(str(self.lock))+'; '+shlex.join([self.bb,'flock','-n','8'])+' && exec '+shlex.join(args)
  cmd=[self.bb,'ash','-c',body]
  if background:return subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  return subprocess.run(cmd,capture_output=True,text=True,timeout=120)
 def ok(self,mutate=True):
  p=self.runret(mutate);self.assertEqual(p.returncode,0,p.stderr);return p
 def test_retire_repeat_verification_and_new_preparation_preserve_old_evidence(self):
  marker=(self.base/'marker').read_bytes();old=(self.base/'snapshot.json').read_bytes()
  self.assertNotEqual(self.runret(False).returncode,0)
  self.ok();self.assertFalse(self.base.exists());self.assertEqual(self.lock.stat().st_ino,self.inode)
  self.assertEqual((self.archive/'snapshot.json').read_bytes(),old);self.assertEqual((self.archive/'marker').read_bytes(),marker)
  self.assertFalse((self.root/'tmp/home-gateway-deploy.lock').is_symlink())
  for rel in ['etc/rc.d/S08home-gateway-migration','etc/init.d/home-gateway-migration','usr/libexec/home-gateway-deploy/migration-state.uc']:self.assertFalse((self.root/rel).exists(),rel)
  self.ok(False);self.ok();self.ok(False)
  p=self.f.runuc('s.close()') # old fixture opens existing state; must refuse.
  self.assertNotEqual(p.returncode,0)
  state=MOD.with_name('migration-state.uc')
  p=subprocess.run(['ucode','-e','import {open_state} from '+json.dumps(str(state))+';let s=open_state(ARGV[0],true,ARGV[1]);print(s.phase());s.close();','--',str(self.root),self.bb],capture_output=True,text=True,timeout=10)
  self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout,'PREPARING')
  self.assertNotEqual((self.base/'marker').read_bytes(),marker);self.assertEqual(self.lock.stat().st_ino,self.inode)
  self.assertNotEqual(self.runret().returncode,0);self.assertEqual((self.archive/'snapshot.json').read_bytes(),old)
 def test_drift_nonce_phase_and_foreign_fence_refuse_before_archive(self):
  p=self.root/'usr/bin/gateway';raw=p.read_bytes();p.write_bytes(raw+b'# drift\n');self.assertNotEqual(self.runret().returncode,0);p.write_bytes(raw)
  self.assertNotEqual(self.runret(nonce='11111111-2222-3333-4444-555555555555').returncode,0)
  self.put('phase','COMMITTED\n');self.assertNotEqual(self.runret().returncode,0);self.put('phase','ROLLED_BACK\n')
  ram=self.root/'tmp/home-gateway-deploy.lock';ram.mkdir(mode=0o700);self.assertNotEqual(self.runret().returncode,0);self.assertTrue(ram.is_dir());ram.rmdir()
  self.assertFalse(self.archive.exists());self.assertTrue(self.base.exists());self.ok()
 def test_corrupt_archived_snapshot_and_newer_deployment_refuse(self):
  self.ok();p=self.archive/'old/runtime/usr/bin/gateway';raw=p.read_bytes();p.write_bytes(b'corrupt');self.assertNotEqual(self.runret(False).returncode,0);p.write_bytes(raw)
  latest=self.root/'etc/home-gateway-deploy/latest';raw=latest.read_bytes();latest.write_bytes(b'tx.newer\n');self.assertNotEqual(self.runret().returncode,0);latest.write_bytes(raw);self.ok(False)

 def interrupt(self,phase):
  ready=self.root/'retirement-fault-ready';shim=self.root/'retirement-fault-busybox'
  condition={
   'before_archive':'case " $* " in *"'+str(self.base)+'/retirement.json.new"*) hit=1;; esac',
   'after_archive':'[ ! -d '+shlex.quote(str(self.archive))+' ] || hit=1',
   'after_control':'if [ -d '+shlex.quote(str(self.archive))+' ] && [ ! -L '+shlex.quote(str(self.root/'etc/rc.d/S08home-gateway-migration'))+' ];then hit=1;fi',
  }[phase]
  shim.write_text('#!/bin/sh\nhit=0\nif [ "$1" = fsync ];then '+condition+';fi\nif [ "$hit" = 1 ];then printf READY > '+shlex.quote(str(ready))+';exec /bin/sleep 30;fi\nexec '+shlex.quote(self.bb)+' "$@"\n');shim.chmod(0o700)
  proc=self.runret(bb=str(shim),background=True)
  try:
   deadline=time.monotonic()+90
   while not ready.exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.02)
   self.assertTrue(ready.exists(),'Retirement did not reach injected checkpoint')
   os.killpg(proc.pid,signal.SIGKILL);proc.communicate(timeout=10)
   self.assertEqual(self.lock.stat().st_ino,self.inode)
   self.ok();self.ok(False);self.assertFalse(self.base.exists())
  finally:
   if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.communicate()
 def test_sigkill_during_retirement_record_is_resumable(self):self.interrupt('before_archive')
 def test_sigkill_after_archive_publication_is_resumable(self):self.interrupt('after_archive')
 def test_sigkill_after_control_removal_is_resumable(self):self.interrupt('after_control')
