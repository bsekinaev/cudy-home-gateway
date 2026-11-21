import base64,hashlib,json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
PS=shutil.which('powershell.exe')
TEMPLATE=Path(__file__).with_name('check-wan.ps1.in')
SOURCE='b'*40

def quote(s):return "'"+str(s).replace("'","''")+"'"

@unittest.skipUnless(PS,'Native Windows PowerShell boundary test')
class WanRunnerTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.temp=tempfile.TemporaryDirectory();cls.bin=Path(cls.temp.name)
  cs='using System;using System.IO;public class FakeSSH {public static int Main(string[] args){File.WriteAllLines(Environment.GetEnvironmentVariable("HG_ARGS"),args);File.WriteAllText(Environment.GetEnvironmentVariable("HG_STDIN"),Console.In.ReadToEnd());Console.Write(File.ReadAllText(Environment.GetEnvironmentVariable("HG_REPLY")));return int.Parse(Environment.GetEnvironmentVariable("HG_EXIT"));}}'
  code='Add-Type -TypeDefinition '+quote(cs)+' -OutputAssembly '+quote(cls.bin/'ssh.exe')+' -OutputType ConsoleApplication'
  r=subprocess.run([PS,'-NoProfile','-EncodedCommand',base64.b64encode(code.encode('utf-16le')).decode()],capture_output=True,timeout=25)
  if r.returncode:raise RuntimeError(r.stderr)
 @classmethod
 def tearDownClass(cls):cls.temp.cleanup()
 def invoke(self,case='valid'):
  with tempfile.TemporaryDirectory() as tmp:
   b=Path(tmp);payload=b'#!/bin/sh\nprintf test\nexit 0\n'
   (b/'router-wan-probe.sh').write_bytes(payload+(b'#tamper' if case=='tampered' else b''))
   (b/'SOURCE.txt').write_text(SOURCE)
   session={'format':'HG_OWNER_SERIES_SESSION_V1','target':'root@fixture.invalid','port':22}
   if case=='identity':session['target']='root@fixture;echo unsafe'
   (b/'session.json').write_text(json.dumps(session))
   runner=TEMPLATE.read_text(encoding='utf-8-sig').replace('@@SOURCE@@',SOURCE).replace('@@SCRIPT_SHA@@',hashlib.sha256(payload).hexdigest())
   (b/'check-wan.ps1').write_text(runner,encoding='utf-8-sig')
   reply={'schema_version':1,'source_commit':SOURCE,'protocol':'dhcp','interface_state':'UP','wan_device_state':'PRESENT','ipv4_address_state':'PRESENT','ipv4_address_scope':'PRIVATE','ipv6_address_state':'UNVERIFIED','ipv4_route_state':'PRESENT','gateway_state':'PRESENT','subnet_overlap':'NO','ipv4_local_path_state':'READY','physical_link_state':'UNVERIFIED','dns_state':'UNVERIFIED','internet_state':'UNVERIFIED'}
   if case=='source':reply['source_commit']='c'*40
   if case=='extra':reply['password']='SECRET_MUST_NOT_BE_SAVED'
   if case=='state':reply['internet_state']='OK'
   (b/'reply').write_text('HG_WAN_READINESS_V1\n'+json.dumps(reply)+'\n')
   env=dict(os.environ,PATH=str(self.bin)+os.pathsep+os.environ['PATH'],HG_ARGS=str(b/'args'),HG_STDIN=str(b/'stdin'),HG_REPLY=str(b/'reply'),HG_EXIT='1' if case=='ssh' else '0')
   r=subprocess.run([PS,'-NoProfile','-ExecutionPolicy','Bypass','-File',str(b/'check-wan.ps1'),'-SessionFile',str(b/'session.json'),'-ReportFile',str(b/'report')],capture_output=True,timeout=12,env=env)
   return r,(b/'args').read_text().splitlines() if (b/'args').exists() else None,(b/'stdin').read_bytes() if (b/'stdin').exists() else None,(b/'report').read_text(encoding='utf-8') if (b/'report').exists() else None
 def test_native_fixed_command_lf_payload_and_valid_report(self):
  r,args,stdin,report=self.invoke();self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual(args[-1],'timeout -k 1 20 sh -s --');self.assertIn('StrictHostKeyChecking=yes',args)
  self.assertEqual(stdin,b'#!/bin/sh\nprintf test\nexit 0\n\r\n')
  self.assertIn('HG_WAN_READINESS_V1',report)
 def test_wrong_identity_or_modified_payload_refused_before_ssh(self):
  for case in ('identity','tampered'):
   with self.subTest(case=case):
    r,args,stdin,report=self.invoke(case);self.assertNotEqual(r.returncode,0);self.assertIsNone(args);self.assertIsNone(report)
 def test_source_schema_and_state_mismatch_not_saved(self):
  for case in ('source','extra','state'):
   with self.subTest(case=case):
    r,args,stdin,report=self.invoke(case);self.assertNotEqual(r.returncode,0);self.assertIsNone(report)
 def test_ssh_failure_is_not_success_or_raw_report(self):
  r,args,stdin,report=self.invoke('ssh');self.assertNotEqual(r.returncode,0)
  self.assertNotIn('HG_WAN_READINESS_V1',report or '')
if __name__=='__main__':unittest.main()
