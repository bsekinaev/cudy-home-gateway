"""Real ucode file publication and restoration; no production entrypoint."""
import json
from pathlib import Path
import subprocess
import unittest
import test_native_candidate
from migration_lab import ALL, OLD, mode

MODULE=Path(__file__).with_name('migration-runtime.uc').resolve()

class NativeRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_native_candidate.NativeCandidateTests('test_pinned_candidate_20_plus_3_preserves_live_legacy_and_phase')
        self.fixture.setUp(); self.addCleanup(self.fixture.doCleanups)
        self.root,self.base,self.bb=self.fixture.root,self.fixture.base,self.fixture.bb
        self.assertEqual(self.fixture.run_candidate().returncode,0)

    def run_native(self,action,bb=None):
        script=('import { open_state } from '+json.dumps(str(MODULE.with_name('migration-state.uc')))+'; '
                'import { prepare_runtime, apply_runtime, restore_runtime, verify_runtime } from '+json.dumps(str(MODULE))+'; '
                'let s=open_state(ARGV[0],false,ARGV[1]); '+action+';')
        return subprocess.run(['ucode','-e',script,'--',str(self.root),bb or self.bb],capture_output=True,text=True,timeout=30)

    def test_actual_18_to_20_to_18_preserves_legacy_journal_and_latest(self):
        for action in ('prepare_runtime','apply_runtime'):
            r=self.run_native(action+'(ARGV[0],s,ARGV[1])'); self.assertEqual(r.returncode,0,r.stderr)
        for rel in ALL:
            self.assertEqual((self.root/rel).read_bytes(),(self.base/'candidate'/rel).read_bytes())
            self.assertEqual((self.root/rel).stat().st_mode&0o777,mode(rel))
        self.assertEqual((self.base/'phase').read_bytes(),b'APPLYING\n')
        self.assertFalse((self.base/'admission').exists())
        self.assertNotEqual(self.run_native('apply_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        r=self.run_native('restore_runtime(ARGV[0],s,ARGV[1])'); self.assertEqual(r.returncode,0,r.stderr)
        self.fixture.lab.assert_previous()
        self.assertEqual((self.base/'phase').read_bytes(),b'RESTORING\n')
        r=self.run_native('restore_runtime(ARGV[0],s,ARGV[1])'); self.assertEqual(r.returncode,0,r.stderr)
        self.fixture.lab.assert_previous()

    def test_foreign_live_bytes_refused_before_restore(self):
        self.assertEqual(self.run_native('prepare_runtime(ARGV[0],s,ARGV[1]); apply_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        p=self.root/OLD[-1]; p.write_bytes(b'foreign\n')
        r=self.run_native('restore_runtime(ARGV[0],s,ARGV[1])'); self.assertNotEqual(r.returncode,0)
        self.assertEqual(p.read_bytes(),b'foreign\n')
        self.assertEqual((self.base/'phase').read_bytes(),b'APPLYING\n')

    def test_live_permissions_and_new_deployment_refused(self):
        self.assertEqual(self.run_native('prepare_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        p=self.root/OLD[-1]; p.chmod(0o600)
        self.assertNotEqual(self.run_native('apply_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        p.chmod(mode(OLD[-1])); (self.fixture.lab.base/'latest').write_bytes(b'tx.foreign\n')
        self.assertNotEqual(self.run_native('apply_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual((self.base/'phase').read_bytes(),b'PREPARED\n')

    def test_unknown_pending_retained_without_restore(self):
        self.assertEqual(self.run_native('prepare_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        p=self.base/'runtime-pending'/'foreign'; p.write_bytes(b'KEEP'); p.chmod(0o600)
        self.assertNotEqual(self.run_native('restore_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual(p.read_bytes(),b'KEEP')
        self.fixture.lab.assert_previous()

    def test_sigkill_mid_apply_and_restore_preserve_fence_and_resume_only_restore(self):
        import os, signal, time
        self.assertEqual(self.run_native('prepare_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        for action in ('apply_runtime','restore_runtime'):
            ready=self.root/'runtime-blocked'; ready.unlink(missing_ok=True)
            shim=self.root/'runtime-fsync-block'
            shim.write_text('#!/bin/sh\ncase "$*" in *"/runtime-pending/usr_bin_gateway"*) touch "'+str(ready)+'"; sleep 10;; esac\nexec "'+self.bb+'" "$@"\n')
            shim.chmod(0o700)
            script=('import { open_state } from '+json.dumps(str(MODULE.with_name('migration-state.uc')))+'; '
                    'import { '+action+' } from '+json.dumps(str(MODULE))+'; let s=open_state(ARGV[0],false,ARGV[1]); '+action+'(ARGV[0],s,ARGV[1]);')
            child=subprocess.Popen(['ucode','-e',script,'--',str(self.root),str(shim)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            try:
                deadline=time.monotonic()+5
                while not ready.exists() and child.poll() is None and time.monotonic()<deadline: time.sleep(.01)
                self.assertTrue(ready.exists(),action)
                # New init remains guarded through an interrupted restore.
                expected=self.base/'candidate'/ALL[0]
                self.assertEqual((self.root/ALL[0]).read_bytes(),expected.read_bytes())
                child.kill(); child.wait(timeout=3)
            finally:
                os.killpg(child.pid,signal.SIGKILL); child.communicate(timeout=3)
            self.assertTrue((self.root/'tmp/home-gateway-deploy.lock').is_symlink())
            self.assertFalse((self.base/'admission').exists())
            self.assertNotEqual(self.run_native('apply_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        result=self.run_native('restore_runtime(ARGV[0],s,ARGV[1])')
        self.assertEqual(result.returncode,0,result.stderr)
        self.fixture.lab.assert_previous()

    def test_owned_partial_stage_restores_but_unknown_bytes_refused(self):
        self.assertEqual(self.run_native('prepare_runtime(ARGV[0],s,ARGV[1]); apply_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        pending=self.base/'runtime-pending'/'usr_bin_gateway'
        pending.write_bytes(b'FOREIGN');pending.chmod(0o600)
        self.assertNotEqual(self.run_native('restore_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual(pending.read_bytes(),b'FOREIGN')
        pending.write_bytes((self.base/'candidate/usr/bin/gateway').read_bytes()[:15])
        r=self.run_native('restore_runtime(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse(pending.exists());self.fixture.lab.assert_previous()
        self.assertEqual((self.base/'runtime-pending/owner').read_bytes(),(self.base/'marker').read_bytes())

    def test_legacy_init_publication_waits_for_all_other_restored_bytes(self):
        import os, signal, time
        self.assertEqual(self.run_native('prepare_runtime(ARGV[0],s,ARGV[1]); apply_runtime(ARGV[0],s,ARGV[1])').returncode,0)
        ready=self.root/'legacy-init-blocked';shim=self.root/'legacy-init-fsync-block'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/runtime-pending/etc_init.d_home-gateway-telegram"*) touch "'+str(ready)+'"; sleep 10;; esac\nexec "'+self.bb+'" "$@"\n');shim.chmod(0o700)
        script=('import { open_state } from '+json.dumps(str(MODULE.with_name('migration-state.uc')))+'; '
                'import { restore_runtime } from '+json.dumps(str(MODULE))+'; let s=open_state(ARGV[0],false,ARGV[1]); restore_runtime(ARGV[0],s,ARGV[1]);')
        child=subprocess.Popen(['ucode','-e',script,'--',str(self.root),str(shim)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        try:
            deadline=time.monotonic()+5
            while not ready.exists() and child.poll() is None and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(ready.exists())
            for rel,raw in self.fixture.lab.previous.items():
                expected=(self.base/'candidate'/rel).read_bytes() if rel==ALL[0] else raw
                self.assertEqual((self.root/rel).read_bytes(),expected,rel)
            for rel in ('usr/lib/home-gateway/actions.uc','usr/lib/home-gateway/notifications.uc'):
                self.assertFalse((self.root/rel).exists())
            child.kill();self.assertEqual(child.wait(timeout=3),-signal.SIGKILL)
        finally:
            os.killpg(child.pid,signal.SIGKILL);child.communicate(timeout=3)
        r=self.run_native('restore_runtime(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.fixture.lab.assert_previous()
