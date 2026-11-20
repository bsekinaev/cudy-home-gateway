"""Monitoring activation verifies the package and refuses unsafe remote state."""
import hashlib,json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
TEMPLATE=Path(__file__).with_name('start-monitor.ps1.in')
PS=shutil.which('powershell.exe')
@unittest.skipUnless(PS,'Windows PowerShell required')
class LauncherTests(unittest.TestCase):
 def invoke(self,fail_verify=False,tampered=False):
  with tempfile.TemporaryDirectory() as d:
   b=Path(d); marker=b/'verify'; calls=b/'ssh.json'
   def q(s):return "'"+str(s).replace("'","''")+"'"
   owner=b/'owner.ps1'; owner.write_text('param($Stage,$Bundle,$BundleSha256,$Target,$Port,$SessionFile)\n'+
    '[IO.File]::WriteAllText('+q(marker)+',$Stage)\n'+('throw "Verify failed"\n' if fail_verify else ''),encoding='utf-8-sig')
   sha=hashlib.sha256(owner.read_bytes()).hexdigest()
   if tampered:owner.write_bytes(owner.read_bytes()+b'# changed\n')
   script=TEMPLATE.read_text(encoding='utf-8-sig').replace('@@RUNNERSHA@@',sha).replace('@@ARCHIVE@@','fixture.tar.gz').replace('@@SHA256@@','a'*64).replace('@@SOURCE@@','b'*40)
   launcher=b/'start.ps1'; launcher.write_text(script,encoding='utf-8-sig')
   harness=b/'harness.ps1'; harness.write_text('function global:ssh { [IO.File]::WriteAllText('+q(calls)+',($args|ConvertTo-Json -Compress)); $global:LASTEXITCODE=0 }\n& '+q(launcher)+' -Stage Notifications\nexit $LASTEXITCODE\n',encoding='utf-8-sig')
   r=subprocess.run([PS,'-NoProfile','-ExecutionPolicy','Bypass','-File',str(harness)],input='\n',text=True,encoding='utf-8',errors='replace',capture_output=True,timeout=10)
   return r,marker.read_text() if marker.exists() else None,json.loads(calls.read_text(encoding='utf-8-sig')) if calls.exists() else None
 def test_enabling_reverifies_before_fixed_ssh(self):
  r,stage,calls=self.invoke(); self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(stage,'Verify')
  self.assertIn('root@192.168.1.1',calls); self.assertIn('StrictHostKeyChecking=yes',calls)
  self.assertIn('configure monitoring',calls[-1]); self.assertIn('b'*40,calls[-1]); self.assertIn('home-gateway-deploy.lock',calls[-1])
 def test_failed_verify_never_enables_delivery(self):
  r,stage,calls=self.invoke(fail_verify=True); self.assertNotEqual(r.returncode,0); self.assertEqual(stage,'Verify'); self.assertIsNone(calls)
 def test_modified_owner_script_refused_before_verify(self):
  r,stage,calls=self.invoke(tampered=True); self.assertNotEqual(r.returncode,0); self.assertIsNone(stage); self.assertIsNone(calls)
@unittest.skipUnless(shutil.which('sh'),'POSIX shell required')
class RemoteGuardTests(unittest.TestCase):
 def test_wrong_source_pending_operation_and_path_escape_cannot_enable(self):
  template=TEMPLATE.read_text(encoding='utf-8-sig'); code=template.split("$remote=@'\n",1)[1].split("\n'@",1)[0].replace('@@SOURCE@@','b'*40)
  for case in ('valid','wrong_source','pending','dangling','escape'):
   with self.subTest(case=case), tempfile.TemporaryDirectory() as d:
    b=Path(d); deploy=b/'deploy'; deploy.mkdir(); (deploy/'tx.123').mkdir(); (deploy/'latest').write_text('tx.123' if case!='escape' else 'tx...escape')
    (deploy/'tx.123/commit').write_text('c'*40 if case=='wrong_source' else 'b'*40)
    if case=='pending':(b/'lock').touch()
    if case=='dangling':(b/'lock').symlink_to(b/'absent')
    gateway=b/'gateway'; marker=b/'enabled'; gateway.write_text('#!/bin/sh\ntouch '+str(marker)+'\n'); gateway.chmod(0o755)
    script=code.replace('/etc/home-gateway-deploy',str(deploy)).replace('/tmp/home-gateway-deploy.lock',str(b/'lock')).replace('/usr/bin/gateway',str(gateway))
    r=subprocess.run(['sh','-c',script],capture_output=True,text=True,timeout=3)
    self.assertEqual(marker.exists(),case=='valid'); self.assertEqual(r.returncode==0,case=='valid')
if __name__=='__main__':unittest.main()
