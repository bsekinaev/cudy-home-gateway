"""Certify real worker PIDs/cmdlines, with a local procd-JSON transport double."""
import json,os,signal,subprocess,sys,tempfile,time,unittest
from pathlib import Path
MOD=Path(__file__).with_name('migration-service.uc').resolve()
class Service(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  for d in ('etc','tmp','usr/bin','usr/lib/home-gateway'):(self.root/d).mkdir(parents=True,exist_ok=True)
  (self.root/'.hg-deploy-test-root').write_text('DISPOSABLE\n')
  self.bb=subprocess.check_output(['sh','-c','command -v busybox'],text=True).strip()
  state='import {open_state} from '+json.dumps(str(MOD.with_name('migration-state.uc')))+';let s=open_state(ARGV[0],true,ARGV[1]);s.fence();'
  subprocess.run(['ucode','-e',state,'--',str(self.root),self.bb],check=True,capture_output=True,timeout=10)
  self.data=self.root/'ubus.json';self.data.write_text('{}')
  p=self.root/'usr/bin/ubus';p.write_text('#!/bin/sh\ncat '+str(self.data)+'\n');p.chmod(0o700)
  self.exe=subprocess.check_output(['ucode','-e','import * as fs from "fs";print(fs.readlink("/proc/self/exe"));'],text=True)
  self.env=dict(os.environ,LD_LIBRARY_PATH=subprocess.check_output(['ucode','-e','print(getenv("LD_LIBRARY_PATH")??"");'],text=True))
 def worker(self,name):
  script=self.root/'usr/lib/home-gateway'/name;script.write_text('system("/bin/sleep 60");\n')
  args=[str(self.root/'usr/bin/ucode'),str(script),str(self.root/'usr/bin/gateway'),'loop']
  pidfile=self.root/('kernel-pid-'+name)
  launcher='import os,json,sys,pathlib;pathlib.Path(sys.argv[3]).write_text(open("/proc/self/stat").read().split(" ",1)[0]);os.execve(sys.argv[1],json.loads(sys.argv[2]),os.environ)'
  child=subprocess.Popen([sys.executable,'-c',launcher,self.exe,json.dumps(args),str(pidfile)],env=self.env,start_new_session=True)
  # Work's host PID namespace may differ from the mounted procfs namespace.
  # This local transport double reports the worker's own procfs-visible ID;
  # no process scan or relaxed cmdline/UID/starttime assertion is used.
  def cleanup():
   if child.poll() is None:os.killpg(child.pid,signal.SIGKILL)
   child.wait(timeout=3)
  self.addCleanup(cleanup)
  end=time.monotonic()+3
  kernel_pid=None
  while time.monotonic()<end:
   try:
    kernel_pid=int(pidfile.read_text())
    if Path(f'/proc/{kernel_pid}/cmdline').read_bytes()==b'\0'.join(a.encode() for a in args)+b'\0':break
   except FileNotFoundError:pass
   time.sleep(.01)
  self.assertIsNotNone(kernel_pid)
  return dict(running=True,pid=kernel_pid,command=args)
 def inspect(self,expected):
  src='import {open_state} from '+json.dumps(str(MOD.with_name('migration-state.uc')))+';import {inspect_telegram} from '+json.dumps(str(MOD))+';let s=open_state(ARGV[0],false,ARGV[1]);print(sprintf("%J",inspect_telegram(ARGV[0],s,ARGV[2])));'
  return subprocess.run(['ucode','-e',src,'--',str(self.root),self.bb,expected],capture_output=True,text=True,timeout=15)
 def publish(self,instances):self.data.write_text(json.dumps({'home-gateway-telegram':{'instances':instances}}))
 def test_stopped_means_no_configured_instances(self):
  self.assertEqual(self.inspect('stopped').returncode,0)
  self.publish({'instance1':{'running':False}});self.assertNotEqual(self.inspect('stopped').returncode,0)
 def test_actual_legacy_worker_certification(self):
  self.publish({'instance1':self.worker('telegram-poller.uc')});r=self.inspect('legacy');self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(len(json.loads(r.stdout)['instances']),1)
 def test_actual_candidate_two_workers(self):
  self.publish({'poller':self.worker('telegram-poller.uc'),'notifications':self.worker('notifications.uc')});r=self.inspect('candidate');self.assertEqual(r.returncode,0,r.stderr)
 def test_spoofed_ubus_pid_is_refused(self):
  r=self.worker('telegram-poller.uc');r['pid']=int(Path('/proc/self/stat').read_text().split(' ',1)[0]);self.publish({'instance1':r});self.assertNotEqual(self.inspect('legacy').returncode,0)
if __name__=='__main__':unittest.main()
