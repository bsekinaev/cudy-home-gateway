"""Native HGDEPLOY2 anchor without rewriting the trusted legacy journal."""
import json
from pathlib import Path
import subprocess
import unittest
import test_native_runtime

MODULE=Path(__file__).with_name('migration-handoff.uc').resolve()
class NativeHandoffTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_native_runtime.NativeRuntimeTests('test_actual_18_to_20_to_18_preserves_legacy_journal_and_latest')
        self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        self.root,self.base,self.bb=self.fixture.root,self.fixture.base,self.fixture.bb
        r=self.fixture.run_native('prepare_runtime(ARGV[0],s,ARGV[1]); apply_runtime(ARGV[0],s,ARGV[1])')
        self.assertEqual(r.returncode,0,r.stderr)
        self.legacy=self.fixture.fixture.lab
        self.original_latest=(self.legacy.base/'latest').read_bytes()

    def run_handoff(self,body,bb=None):
        script=('import { open_state } from '+json.dumps(str(MODULE.with_name('migration-state.uc')))+'; '
                'import { prepare_handoff,publish_handoff,restore_handoff } from '+json.dumps(str(MODULE))+'; '
                'let s=open_state(ARGV[0],false,ARGV[1]); '+body+';')
        return subprocess.run(['ucode','-e',script,'--',str(self.root),bb or self.bb],capture_output=True,text=True,timeout=30)
    def prepare(self):
        r=self.run_handoff('prepare_handoff(ARGV[0],s,ARGV[1],"'+'c'*40+'",0)');self.assertEqual(r.returncode,0,r.stderr)

    def test_real_hg2_anchor_and_verified_return_to_original_legacy_journal(self):
        self.prepare()
        r=self.run_handoff('publish_handoff(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        anchor=self.legacy.base/(self.legacy.base/'latest').read_text().strip()
        self.assertEqual((anchor/'inventory-version').read_bytes(),b'HGDEPLOY2\n')
        self.assertEqual(len((anchor/'new.sha256').read_text().splitlines()),20)
        self.assertEqual((anchor/'backup.sha256').read_bytes(),(anchor/'new.sha256').read_bytes())
        self.assertEqual(self.legacy.freeze(self.legacy.tx),self.legacy.journal)
        self.assertEqual(self.run_handoff('publish_handoff(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual(self.run_handoff('restore_handoff(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual((self.legacy.base/'latest').read_bytes(),self.original_latest)
        self.assertFalse(anchor.exists())
        self.assertEqual(self.run_handoff('restore_handoff(ARGV[0],s,ARGV[1])').returncode,0)
        r=self.fixture.run_native('restore_runtime(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.legacy.assert_previous()

    def test_later_deployment_refuses_migration_rollback(self):
        self.prepare();self.assertEqual(self.run_handoff('publish_handoff(ARGV[0],s,ARGV[1])').returncode,0)
        (self.legacy.base/'latest').write_bytes(b'tx.foreign\n')
        self.assertNotEqual(self.run_handoff('restore_handoff(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual((self.legacy.base/'latest').read_bytes(),b'tx.foreign\n')

    def test_corrupt_anchor_refuses_before_pointer_changes(self):
        self.prepare();(self.base/'handoff/backup/usr/bin/gateway').write_bytes(b'corrupt\n')
        self.assertNotEqual(self.run_handoff('publish_handoff(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual((self.legacy.base/'latest').read_bytes(),self.original_latest)

    def test_partial_anchor_fsync_preserved_and_never_adopted(self):
        shim=self.root/'fail-anchor-fsync'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/handoff/"*) exit 1;; esac\nexec "'+self.bb+'" "$@"\n');shim.chmod(0o700)
        r=self.run_handoff('prepare_handoff(ARGV[0],s,ARGV[1],"'+'c'*40+'",0)',str(shim))
        self.assertNotEqual(r.returncode,0)
        self.assertTrue((self.base/'handoff').exists());self.assertFalse((self.base/'handoff.json').exists())
        self.assertNotEqual(self.run_handoff('publish_handoff(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual((self.legacy.base/'latest').read_bytes(),self.original_latest)
