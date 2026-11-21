import hashlib,os,subprocess,tempfile,unittest,zipfile
from pathlib import Path
from unittest.mock import patch
import build_wan_probe

class WanBuildTests(unittest.TestCase):
 def test_committed_source_and_pins_only_no_mutable_or_private_files(self):
  with tempfile.TemporaryDirectory() as tmp:
   b=Path(tmp);repo=b/'repo';repo.mkdir()
   def git(*args):return subprocess.check_output(['git','-C',str(repo),*args])
   git('init','-q');git('config','core.autocrlf','false')
   for name,raw in [('router-wan-probe.uc',b"// committed collector\nprint('TRANSPORT_OK:'+ARGV[0]);\n"),('check-wan.ps1.in',b'# @@SOURCE@@ @@SCRIPT_SHA@@\n')]:
    p=repo/'scripts/observability'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(raw)
   git('add','.');git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','Fixture')
   source=git('rev-parse','HEAD').decode().strip()
   (repo/'scripts/observability/router-wan-probe.uc').write_text('PRIVATE_UNCOMMITTED')
   with patch.object(build_wan_probe,'ROOT',repo):
    archive=build_wan_probe.build(b/'out')
    with self.assertRaises(FileExistsError):build_wan_probe.build(b/'out')
   raw=(b/'out/router-wan-probe.sh').read_bytes()
   self.assertIn(b'committed collector',raw);self.assertIn(source.encode(),raw)
   self.assertNotIn(b'PRIVATE_UNCOMMITTED',raw);self.assertNotIn(b'\r',raw)
   if os.name!='nt':
    r=subprocess.run(['sh',str(b/'out/router-wan-probe.sh')],capture_output=True,text=True,timeout=5)
    self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout,'TRANSPORT_OK:'+source)
   runner=(b/'out/check-wan.ps1').read_text(encoding='utf-8-sig')
   self.assertIn(hashlib.sha256(raw).hexdigest(),runner);self.assertIn(source,runner);self.assertNotIn('@@',runner)
   for row in (b/'out/SHA256SUMS.txt').read_text().splitlines():
    pin,name=row.split('  ');self.assertEqual(pin,hashlib.sha256((b/'out'/name).read_bytes()).hexdigest())
   with zipfile.ZipFile(archive) as z:
    self.assertEqual(set(z.namelist()),{'router-wan-probe.sh','check-wan.ps1','CHECK-WAN.cmd','SOURCE.txt','README-RU.md','SHA256SUMS.txt'})
    self.assertIsNone(z.testzip())
if __name__=='__main__':unittest.main()
