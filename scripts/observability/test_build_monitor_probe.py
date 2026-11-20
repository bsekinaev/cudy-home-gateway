"""Readiness packages are determined by a committed source, not mutable checkout."""
from pathlib import Path
import subprocess, tempfile, unittest, zipfile
from unittest.mock import patch
import build_monitor_probe
class MonitorProbeBuildTests(unittest.TestCase):
 def test_exact_source_and_closed_public_archive(self):
  with tempfile.TemporaryDirectory() as d:
   b=Path(d); r=b/'repo'; r.mkdir()
   def git(*args): return subprocess.check_output(['git','-C',str(r),*args])
   git('init','-q'); git('config','core.autocrlf','false')
   paths=['src/usr/lib/home-gateway/'+n+'.sh' for n in build_monitor_probe.MODULES]
   paths+=['scripts/observability/router-monitor-probe-footer.sh','scripts/observability/check-monitor.ps1']
   for name in paths:
    p=r/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(('# committed '+name+'\n').encode())
   git('add','.'); git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','Fixture')
   source=git('rev-parse','HEAD').decode().strip()
   for name in paths: (r/name).write_bytes(b'UNCOMMITTED_PRIVATE_VALUE\n')
   with patch.object(build_monitor_probe,'ROOT',r):
    archive=build_monitor_probe.build(b/'out')
    with self.assertRaises(FileExistsError): build_monitor_probe.build(b/'out')
   payload=(b/'out/router-monitor-probe.sh').read_bytes()
   self.assertIn(source.encode(),payload); self.assertNotIn(b'UNCOMMITTED_PRIVATE_VALUE',payload)
   for name in build_monitor_probe.MODULES: self.assertIn(('# committed src/usr/lib/home-gateway/'+name+'.sh').encode(),payload)
   with zipfile.ZipFile(archive) as z:
    self.assertEqual(set(z.namelist()), {'router-monitor-probe.sh','check-monitor.ps1','CHECK-MONITOR.cmd','SOURCE.txt','README.txt','SHA256SUMS.txt'}); self.assertIsNone(z.testzip())
    self.assertFalse(any('session' in n or 'transport' in n for n in z.namelist()))
if __name__=='__main__': unittest.main()
