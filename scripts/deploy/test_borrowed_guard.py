"""Real inherited OFD lock and CLOEXEC, prerequisite for procd handoff."""
import json,os,shlex,shutil,subprocess,tempfile,unittest
from pathlib import Path
MOD=Path(__file__).with_name('migration-state.uc').resolve()
class BorrowedGuard(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  (self.root/'etc').mkdir();(self.root/'tmp').mkdir();(self.root/'.hg-deploy-test-root').write_text('DISPOSABLE\n')
  self.bb=shutil.which(os.environ.get('HG_TEST_BUSYBOX','busybox'));self.assertTrue(self.bb)
  self.lock=self.root/'etc/home-gateway-migration.lock';self.lock.touch(mode=0o600)
 def command(self,borrow=True):
  source='import * as fs from "fs"; import {open_state} from '+json.dumps(str(MOD))+'; let s=open_state(ARGV[0],true,ARGV[1],null,null,'+('true' if borrow else 'null')+'); s.fence(); '
  if borrow:source+='let p=fs.popen("test ! -e /proc/self/fd/8","r"); if(p.close()!=0)die("FD_LEAK"); s.close();'
  return shlex.join(['ucode','-e',source,str(self.root),self.bb])
 def test_same_ofd_parent_lease_survives_child_close_without_exec_leak(self):
  source='exec 8< '+shlex.quote(str(self.lock))+'\n'+shlex.join([self.bb,'flock','-n','8'])+'\n'+self.command()+'\nif '+self.command(False)+' >/dev/null 2>&1; then exit 91; fi\nexec 8<&-\n'+self.command(False)
  p=subprocess.run(['sh','-ec',source],capture_output=True,text=True,timeout=20);self.assertEqual(p.returncode,0,p.stderr)
 def test_foreign_fd_is_refused_before_state_creation(self):
  foreign=self.root/'foreign';foreign.touch(mode=0o600)
  p=subprocess.run(['sh','-c','exec 8< '+shlex.quote(str(foreign))+'; '+self.command()],capture_output=True,text=True,timeout=15)
  self.assertNotEqual(p.returncode,0);self.assertFalse((self.root/'etc/home-gateway-migration').exists())
 def test_absent_fd_is_refused(self):
  p=subprocess.run(['sh','-c','exec 8<&-; '+self.command()],capture_output=True,text=True,timeout=15)
  self.assertNotEqual(p.returncode,0);self.assertFalse((self.root/'etc/home-gateway-migration').exists())
if __name__=='__main__':unittest.main()
