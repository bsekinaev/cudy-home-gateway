"""Execute actual PowerShell runner with local SSH/SCP command doubles."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('rc_builder',Path(__file__).with_name('build.py'))
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)

@unittest.skipUnless(shutil.which('pwsh'),'PowerShell runtime unavailable')
class Runner(unittest.TestCase):
    def test_stages_and_interrupted_prepare_identity(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);archive=builder.build(builder.REPO,'HEAD',root/'bundle')
            digest=hashlib.sha256(archive.read_bytes()).hexdigest()
            shutil.copyfile(archive,root/('rc-a-'+digest+'.tar.gz'))
            commands=root/'commands';commands.mkdir();log=root/'calls'
            script='''#!/usr/bin/env python3
import os,sys
with open(os.environ['RC_CALLS'],'a') as f:f.write(sys.argv[0].split('/')[-1]+' '+sys.argv[-1]+'\\n')
s=sys.argv[-1]
if 'mktemp -d' in s:print('/tmp/hgdeploy2-rc-a-kit.Abc123')
if s.endswith('rc-a.sh prepare'):
 print('RC_LAB=/tmp/hgdeploy2-rc-a.Def456')
 if os.environ.get('RC_FAIL')=='prepare':sys.exit(255)
if 'rc-a.sh apply ' in s and os.environ.get('RC_FAIL')=='apply':sys.exit(70)
'''
            for name in ('ssh','scp'):
                p=commands/name;p.write_text(script);p.chmod(0o755)
            env=dict(os.environ,PATH=str(commands)+os.pathsep+os.environ['PATH'],RC_CALLS=str(log))
            def run(session,stage,fail=''):
                env['RC_FAIL']=fail
                return subprocess.run(['pwsh','-NoProfile','-File',str(Path(__file__).with_name('owner.ps1')),'-Target','root@cudy.test','-BundleUrl','https://raw.githubusercontent.com/bsekinaev/cudy-home-gateway/'+'a'*40+'/artifacts/test.tar.gz','-BundleSha256',digest,'-SessionFile',str(root/session),'-Stage',stage],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
            p=run('one.json','Preflight');self.assertEqual(p.returncode,0,p.stdout)
            self.assertNotIn('rc-a.sh apply',log.read_text())
            p=run('one.json','All');self.assertEqual(p.returncode,0,p.stdout)
            self.assertIn('rc-a.sh verify /tmp/hgdeploy2-rc-a.Def456',log.read_text())
            p=run('one.json','Rollback');self.assertEqual(p.returncode,0,p.stdout)
            p=run('two.json','All','prepare');self.assertNotEqual(p.returncode,0,p.stdout)
            self.assertEqual(json.loads((root/'two.json').read_text(encoding='utf-8-sig'))['lab'],'/tmp/hgdeploy2-rc-a.Def456')
            log.write_text('')
            p=run('three.json','All','apply');self.assertNotEqual(p.returncode,0,p.stdout)
            self.assertNotIn('rc-a.sh rollback',log.read_text());self.assertNotIn('rc-a.sh verify',log.read_text())

if __name__=='__main__':unittest.main()
