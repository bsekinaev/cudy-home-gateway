"""Delivery A acceptance: real pinned native processes, no production access."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest
import importlib.util
spec=importlib.util.spec_from_file_location("rc_builder",Path(__file__).with_name("build.py"))
build=importlib.util.module_from_spec(spec);spec.loader.exec_module(build)

class Package(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(prefix='hg-rc-tests-')
        cls.base=Path(cls.tmp.name)
        cls.archive=build.build(build.REPO,'HEAD',cls.base/'one')
        cls.env=os.environ.copy()
        cls.bb=cls.env.get('HG_TEST_BUSYBOX_PATH','/bin/busybox')
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def kit(self):
        p=Path(tempfile.mkdtemp(dir=self.base));p.chmod(0o700)
        subprocess.run(['tar','-xzpf',str(self.archive),'-C',str(p)],check=True)
        return p
    def runstage(self,kit,stage,*args,ok=True):
        p=subprocess.run(['sh',str(kit/'rc-a.sh'),'--test-busybox',self.bb,stage,*args],env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
        self.assertEqual(p.returncode==0,ok,p.stdout)
        return p.stdout
    def test_deterministic_manifest(self):
        other=build.build(build.REPO,'HEAD',self.base/'two')
        self.assertEqual(self.archive.read_bytes(),other.read_bytes())
        commit,files,m=build.content(build.REPO,'HEAD')
        self.assertFalse(m['production_apply'])
        self.assertEqual(len([p for p in files if p.startswith('candidate/')]),24)
        with tarfile.open(self.archive) as t:
            for member in t:
                self.assertEqual((member.uid,member.gid),(0,0))
                self.assertTrue(member.isdir() or member.isfile())
                self.assertFalse(member.name.startswith('/') or '..' in member.name.split('/'))
    def test_native_full_cycle_and_repeat_rollback(self):
        kit=self.kit();out=self.runstage(kit,'prepare')
        root=re.search(r'^RC_LAB=(.+)$',out,re.M).group(1)
        for stage in ('apply','verify','rollback','rollback'): self.runstage(kit,stage,root)
        self.assertFalse((Path(root)/'usr/lib/home-gateway/actions.uc').exists())
        self.assertFalse((Path(root)/'usr/lib/home-gateway/notifications.uc').exists())
        self.runstage(kit,'apply',root,ok=False)
    def test_package_tampering_refused(self):
        kit=self.kit();p=kit/'candidate/usr/bin/gateway';p.write_bytes(p.read_bytes()+b'# tamper\n')
        self.runstage(kit,'prepare',ok=False)
    def test_extra_file_refused(self):
        kit=self.kit();(kit/'unexpected').write_text('x')
        self.runstage(kit,'prepare',ok=False)
    def test_hardlink_refused(self):
        kit=self.kit();os.link(kit/'candidate/usr/bin/gateway',self.base/'linked')
        self.runstage(kit,'prepare',ok=False)
    def test_production_and_foreign_root_refused(self):
        kit=self.kit()
        self.runstage(kit,'production-apply',ok=False)
        self.runstage(kit,'apply','/',ok=False)
        self.runstage(kit,'rollback','/tmp/hg-native-main.cPHJib',ok=False)

if __name__=='__main__': unittest.main()
