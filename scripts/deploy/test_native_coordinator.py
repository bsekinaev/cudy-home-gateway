"""Single native apply/rollback integrates verified runtime and journal anchor."""
import json
from pathlib import Path
import subprocess
import unittest
import test_native_runtime

MODULE=Path(__file__).with_name('migration-coordinator.uc').resolve()
class NativeCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_native_runtime.NativeRuntimeTests('test_actual_18_to_20_to_18_preserves_legacy_journal_and_latest')
        self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        self.root,self.base,self.bb=self.fixture.root,self.fixture.base,self.fixture.bb
        self.legacy=self.fixture.fixture.lab
    def run_native(self,body,bb=None,recovery=False):
        script=('import { open_state,open_rollback_state } from '+json.dumps(str(MODULE.with_name('migration-state.uc')))+'; '
                'import { prepare_coordinator,apply_coordinator,rollback_coordinator } from '+json.dumps(str(MODULE))+'; '
                + ('let s=open_rollback_state(ARGV[0],ARGV[1]); s.fence(); ' if recovery else 'let s=open_state(ARGV[0],false,ARGV[1]); ')+body+';')
        return subprocess.run(['ucode','-e',script,'--',str(self.root),bb or self.bb],capture_output=True,text=True,timeout=30)
    def prepare(self):
        r=self.run_native('prepare_coordinator(ARGV[0],s,ARGV[1],"'+'c'*40+'",0)');self.assertEqual(r.returncode,0,r.stderr)
    def test_single_apply_hg2_anchor_then_single_rollback_exact_legacy(self):
        self.prepare();self.assertTrue((self.base/'handoff.json').exists())
        self.legacy.assert_previous()
        r=self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        latest=self.legacy.base/(self.legacy.base/'latest').read_text().strip()
        self.assertEqual((latest/'inventory-version').read_bytes(),b'HGDEPLOY2\n')
        self.assertEqual(len((latest/'backup.sha256').read_text().splitlines()),20)
        self.assertFalse((self.base/'admission').exists())
        self.assertNotEqual(self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        r=self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.legacy.assert_previous()
        self.assertEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
    def test_corrupt_prepared_anchor_prevents_all_live_writes(self):
        self.prepare();(self.base/'handoff/backup/usr/bin/gateway').write_bytes(b'foreign\n')
        self.assertNotEqual(self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual((self.base/'phase').read_bytes(),b'PREPARED\n');self.legacy.assert_previous()
    def test_partial_private_anchor_can_restore_original_without_adoption(self):
        self.prepare();(self.base/'handoff.json').unlink()
        r=self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.legacy.assert_previous();self.assertTrue((self.base/'handoff').exists())
    def test_pending_owned_latest_is_restored_but_foreign_pending_refused(self):
        self.prepare();self.assertEqual(self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        pending=self.base/'latest.pending';pending.write_bytes(b'tx.foreign\n');pending.chmod(0o600)
        self.assertNotEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        latest=(self.legacy.base/'latest').read_bytes();pending.write_bytes(latest[:8])
        r=self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.legacy.assert_previous()

    def test_foreign_live_runtime_refusal_keeps_latest_and_anchor_unchanged(self):
        self.prepare();self.assertEqual(self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        latest=(self.legacy.base/'latest').read_bytes();anchor=self.legacy.base/latest.decode().strip()
        original=self.legacy.freeze(anchor)
        (self.root/'usr/bin/gateway').write_bytes(b'FOREIGN')
        self.assertNotEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual((self.legacy.base/'latest').read_bytes(),latest)
        self.assertEqual(self.legacy.freeze(anchor),original)
        self.assertEqual((self.base/'phase').read_bytes(),b'APPLYING\n')

    def test_receipt_published_pending_anchor_restores_without_adoption(self):
        self.prepare();pending=self.base/'handoff.publish-pending'
        pending.write_bytes((self.base/'marker').read_bytes());pending.chmod(0o600)
        r=self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.legacy.assert_previous();self.assertTrue(pending.exists())
        self.assertEqual((self.base/'phase').read_bytes(),b'RESTORING\n')

    def test_preparing_space_failure_abort_does_not_rewrite_original_files(self):
        shim=self.root/'no-runtime-space'
        shim.write_text('#!/bin/sh\nif [ "$1" = df ]; then printf "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 1 1 0 100%% /\n"; exit 0; fi\nexec "'+self.bb+'" "$@"\n');shim.chmod(0o700)
        before={p:(self.root/p).stat().st_ino for p in self.legacy.previous}
        r=self.run_native('prepare_coordinator(ARGV[0],s,ARGV[1],"'+'c'*40+'",0)',str(shim))
        self.assertNotEqual(r.returncode,0);self.assertTrue((self.base/'coordinator.json').exists())
        self.assertEqual((self.base/'phase').read_bytes(),b'PREPARING\n')
        r=self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual(before,{p:(self.root/p).stat().st_ino for p in self.legacy.previous})
        self.legacy.assert_previous();self.assertEqual((self.base/'phase').read_bytes(),b'RESTORING\n')

    def test_legacy_journal_drift_refuses_before_latest_changes(self):
        self.prepare();self.assertEqual(self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        latest=(self.legacy.base/'latest').read_bytes();anchor=self.legacy.base/latest.decode().strip()
        (self.legacy.tx/'preflight.log').write_bytes(b'foreign journal\n')
        self.assertNotEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        self.assertEqual((self.legacy.base/'latest').read_bytes(),latest);self.assertTrue(anchor.exists())
        self.assertEqual((self.legacy.tx/'preflight.log').read_bytes(),b'foreign journal\n')

    def test_restore_space_refusal_keeps_latest_anchor_and_runtime(self):
        self.prepare();self.assertEqual(self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        latest=(self.legacy.base/'latest').read_bytes();anchor=self.legacy.base/latest.decode().strip()
        before={p:(self.root/p).read_bytes() for p in self.legacy.previous}
        shim=self.root/'no-restore-space'
        shim.write_text('#!/bin/sh\nif [ "$1" = df ]; then printf "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 1 1 0 100%% /\n"; exit 0; fi\nexec "'+self.bb+'" "$@"\n');shim.chmod(0o700)
        self.assertNotEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])',str(shim)).returncode,0)
        self.assertEqual((self.legacy.base/'latest').read_bytes(),latest);self.assertTrue(anchor.exists())
        self.assertEqual(before,{p:(self.root/p).read_bytes() for p in self.legacy.previous})

    def test_prepared_anchor_failure_abort_preserves_all_original_inodes(self):
        shim=self.root/'fail-anchor-space';counter=self.root/'df-counter'
        shim.write_text('#!/bin/sh\nif [ "$1" = df ]; then n=$(cat "'+str(counter)+'" 2>/dev/null || printf 0); n=$((n+1)); printf "%s" "$n" > "'+str(counter)+'"; if [ "$n" -gt 1 ]; then printf "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 1 1 0 100%% /\n"; exit 0; fi; fi\nexec "'+self.bb+'" "$@"\n');shim.chmod(0o700)
        before={p:(self.root/p).stat().st_ino for p in self.legacy.previous}
        self.assertNotEqual(self.run_native('prepare_coordinator(ARGV[0],s,ARGV[1],"'+'c'*40+'",0)',str(shim)).returncode,0)
        self.assertEqual((self.base/'phase').read_bytes(),b'PREPARED\n')
        r=self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])');self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(before,{p:(self.root/p).stat().st_ino for p in self.legacy.previous})
        self.legacy.assert_previous()

    def test_sigkill_phase_publication_requires_explicit_verified_rollback(self):
        import os, signal, time
        self.prepare()
        before={p:(self.root/p).stat().st_ino for p in self.legacy.previous}
        ready=self.root/'phase-blocked';shim=self.root/'phase-fsync-block'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/phase.new"*) touch "'+str(ready)+'"; sleep 10;; esac\nexec "'+self.bb+'" "$@"\n');shim.chmod(0o700)
        script=('import { open_state } from '+json.dumps(str(MODULE.with_name('migration-state.uc')))+'; '
                'import { apply_coordinator } from '+json.dumps(str(MODULE))+'; '
                'let s=open_state(ARGV[0],false,ARGV[1]); apply_coordinator(ARGV[0],s,ARGV[1]);')
        child=subprocess.Popen(['ucode','-e',script,'--',str(self.root),str(shim)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        try:
            deadline=time.monotonic()+5
            while not ready.exists() and child.poll() is None and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(ready.exists());child.kill();self.assertEqual(child.wait(timeout=3),-signal.SIGKILL)
        finally:
            os.killpg(child.pid,signal.SIGKILL);child.communicate(timeout=3)
        self.assertEqual((self.base/'phase.new').read_bytes(),b'APPLYING\n')
        self.assertNotEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        r=self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])',recovery=True);self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.base/'phase.interrupted').read_bytes(),b'APPLYING\n')
        self.assertEqual(before,{p:(self.root/p).stat().st_ino for p in self.legacy.previous})
        self.legacy.assert_previous();self.assertFalse((self.base/'admission').exists())

    def test_interrupted_restoring_after_ram_loss_restores_without_replay(self):
        self.prepare();self.assertEqual(self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])').returncode,0)
        pending=self.base/'phase.new';pending.write_bytes(b'REST');pending.chmod(0o600)
        (self.root/'tmp/home-gateway-deploy.lock').unlink()
        r=self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])',recovery=True);self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.base/'phase.interrupted').read_bytes(),b'REST')
        self.legacy.assert_previous()
        self.assertEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])',recovery=True).returncode,0)
        self.assertTrue((self.root/'tmp/home-gateway-deploy.lock').is_symlink())

    def test_unknown_or_unsafe_phase_pending_is_preserved(self):
        self.prepare();pending=self.base/'phase.new'
        for raw in (b'FOREIGN',b'COMMITTED\n',b'RESTORING\nEXTRA'):
            pending.write_bytes(raw);pending.chmod(0o600)
            self.assertNotEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])',recovery=True).returncode,0)
            self.assertEqual(pending.read_bytes(),raw);self.assertFalse((self.base/'phase.interrupted').exists())
        pending.write_bytes(b'APPLYING\n');pending.chmod(0o644)
        self.assertNotEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])',recovery=True).returncode,0)
        self.assertTrue(pending.exists());self.legacy.assert_previous()

    def test_phase_recovery_refuses_snapshot_drift_before_archiving(self):
        self.prepare();pending=self.base/'phase.new';pending.write_bytes(b'APPLYING\n');pending.chmod(0o600)
        (self.base/'old/runtime/usr/bin/gateway').write_bytes(b'FOREIGN')
        self.assertNotEqual(self.run_native('rollback_coordinator(ARGV[0],s,ARGV[1])',recovery=True).returncode,0)
        self.assertEqual(pending.read_bytes(),b'APPLYING\n');self.assertFalse((self.base/'phase.interrupted').exists())
        self.legacy.assert_previous()

    def test_recovery_handle_cannot_apply_even_without_pending_phase(self):
        self.prepare();before={p:(self.root/p).stat().st_ino for p in self.legacy.previous}
        self.assertNotEqual(self.run_native('apply_coordinator(ARGV[0],s,ARGV[1])',recovery=True).returncode,0)
        self.assertEqual((self.base/'phase').read_bytes(),b'PREPARED\n')
        self.assertEqual(before,{p:(self.root/p).stat().st_ino for p in self.legacy.previous})
