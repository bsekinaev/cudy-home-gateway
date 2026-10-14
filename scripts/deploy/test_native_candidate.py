"""Native same-filesystem publication of a pinned 20+3 candidate snapshot."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest

import test_native_snapshot
from migration_lab import ALL, RECEIVERS, mode

MODULE = Path(__file__).with_name('migration-candidate.uc').resolve()
STATE = MODULE.with_name('migration-state.uc')
SNAPSHOT = MODULE.with_name('migration-snapshot.uc')

class NativeCandidateTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_native_snapshot.NativeSnapshotTests('test_verified_snapshot_preserves_runtime_receiver_latest_and_journal')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.lab = self.fixture.lab
        self.root, self.base, self.bb = self.fixture.root, self.fixture.base, self.fixture.bb
        result = self.fixture.run_snapshot()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.source = self.lab.candidate
        repo = MODULE.parents[2]
        for rel in ALL:
            origin = (repo / 'scripts/deploy' / {'engine.sh': 'engine.sh', 'wrapper.sh': 'wrapper.sh', 'home-gateway-deploy-recover': 'recovery.init'}[Path(rel).name]) if rel in RECEIVERS else repo / 'src' / rel
            path = self.source / rel
            path.write_bytes(origin.read_bytes()); path.chmod(mode(rel))
        for p in [self.source, *self.source.rglob('*')]:
            if p.is_dir(): p.chmod(0o700)
        self.raw = ''.join(f'{hashlib.sha256((self.source / p).read_bytes()).hexdigest()}  {p}\n' for p in ALL).encode()
        (self.source / 'migration.sha256').write_bytes(self.raw)
        self.pin = hashlib.sha256(self.raw).hexdigest()

    def candidate_command(self, verify=False, pin=None, bb=None):
        name = 'verify_candidate_snapshot' if verify else 'prepare_candidate_snapshot'
        script = ('import { open_state } from ' + json.dumps(str(STATE)) + '; '
                  'import { ' + name + ' } from ' + json.dumps(str(MODULE)) + '; '
                  'let s=open_state(ARGV[0], false, ARGV[1]); let r=' + name +
                  '(ARGV[0], s, ARGV[1]' + ('' if verify else ', ARGV[2], ARGV[3]') + '); print(sprintf("%J",r));')
        return ['ucode', '-e', script, '--', str(self.root), bb or self.bb, str(self.source), pin or self.pin]

    def run_candidate(self, verify=False, pin=None, bb=None):
        return subprocess.run(self.candidate_command(verify, pin, bb), capture_output=True, text=True, timeout=30)

    def test_pinned_candidate_20_plus_3_preserves_live_legacy_and_phase(self):
        result = self.run_candidate()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(len(receipt['files']), 23)
        self.assertEqual(receipt['scope'], 'RUNTIME20_RECEIVER3')
        self.assertEqual(self.run_candidate(True).returncode, 0)
        for rel in ALL:
            copy = self.base / 'candidate' / rel
            self.assertEqual(copy.read_bytes(), (self.source / rel).read_bytes())
            self.assertEqual(copy.stat().st_mode & 0o777, mode(rel))
        self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARING\n')
        self.assertFalse((self.base / 'admission').exists())
        self.lab.assert_previous()
        self.assertNotEqual(self.run_candidate().returncode, 0)

    def test_pin_and_source_hash_mismatch_refuse_before_copy(self):
        self.assertNotEqual(self.run_candidate(pin='0' * 64).returncode, 0)
        (self.source / ALL[0]).write_bytes(b'changed\n')
        self.assertNotEqual(self.run_candidate().returncode, 0)
        self.assertFalse((self.base / 'candidate').exists())
        self.lab.assert_previous()

    def test_extra_paths_symlink_hardlink_and_modes_refused(self):
        extra = self.source / 'foreign'; extra.mkdir(mode=0o700)
        self.assertNotEqual(self.run_candidate().returncode, 0); extra.rmdir()
        p = self.source / ALL[-1]; raw = p.read_bytes(); p.unlink()
        p.symlink_to(self.source / ALL[0])
        self.assertNotEqual(self.run_candidate().returncode, 0); p.unlink()
        os.link(self.source / ALL[0], p)
        self.assertNotEqual(self.run_candidate().returncode, 0); p.unlink()
        p.write_bytes(raw); p.chmod(0o600)
        self.assertNotEqual(self.run_candidate().returncode, 0)
        self.assertFalse((self.base / 'candidate').exists())
        self.lab.assert_previous()

    def test_manifest_traversal_even_with_matching_manifest_pin_refused(self):
        raw = self.raw.replace(ALL[0].encode(), b'../../etc/shadow', 1)
        (self.source / 'migration.sha256').write_bytes(raw)
        self.assertNotEqual(self.run_candidate(pin=hashlib.sha256(raw).hexdigest()).returncode, 0)
        self.assertFalse((self.base / 'candidate').exists())

    def test_partial_fsync_failure_is_retained_fenced_without_replay(self):
        shim = self.root / 'fail-candidate-fsync'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/candidate/"*) exit 1;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        self.assertNotEqual(self.run_candidate(bb=str(shim)).returncode, 0)
        self.assertTrue((self.base / 'candidate').exists())
        self.assertFalse((self.base / 'candidate.json').exists())
        self.assertNotEqual(self.run_candidate().returncode, 0)
        self.assertTrue((self.root / 'tmp/home-gateway-deploy.lock').is_symlink())
        self.lab.assert_previous()

    def test_corrupt_snapshot_or_receipt_never_admitted(self):
        self.assertEqual(self.run_candidate().returncode, 0)
        p = self.base / 'candidate' / ALL[0]; raw = p.read_bytes(); p.write_bytes(b'changed\n')
        self.assertNotEqual(self.run_candidate(True).returncode, 0); p.write_bytes(raw)
        receipt = self.base / 'candidate.json'
        original = receipt.read_bytes(); data = json.loads(original); data['scope'] = 'FULL_MIGRATION'
        receipt.write_text(json.dumps(data))
        self.assertNotEqual(self.run_candidate(True).returncode, 0)
        self.assertFalse((self.base / 'admission').exists())
        self.lab.assert_previous()

    def test_insufficient_space_refuses_before_candidate_copy(self):
        shim=self.root / 'no-candidate-space'
        shim.write_text('#!/bin/sh\nif [ "$1" = df ]; then printf "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 1 1 0 100%% /\n"; exit 0; fi\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        result=self.run_candidate(bb=str(shim))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SPACE', result.stderr)
        self.assertFalse((self.base / 'candidate').exists())
        self.lab.assert_previous()

    def test_sigkill_mid_copy_retains_partial_snapshot_and_never_reapplies(self):
        import signal
        import time
        entered=self.root / 'candidate-fsync-entered'
        shim=self.root / 'block-candidate-fsync'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/candidate/"*) touch "' + str(entered) + '"; sleep 10;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        child=subprocess.Popen(self.candidate_command(bb=str(shim)), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline=time.monotonic()+5
            while not entered.exists() and child.poll() is None and time.monotonic()<deadline: time.sleep(.01)
            self.assertTrue(entered.exists())
            child.kill(); child.wait(timeout=3)
            self.assertTrue((self.base / 'candidate').is_dir())
            self.assertFalse((self.base / 'candidate.json').exists())
            self.assertNotEqual(self.run_candidate().returncode, 0)
            self.assertTrue((self.root / 'tmp/home-gateway-deploy.lock').is_symlink())
            self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARING\n')
            self.lab.assert_previous()
        finally:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=3)

    def test_source_drift_during_pending_receipt_fsync_refuses_publication(self):
        for area in ('modify', 'add', 'remove'):
            if area != 'modify': self.doCleanups(); self.setUp()
            target = self.source / (ALL[-1] if area != 'add' else 'foreign')
            operation = ('printf "# late drift\\n" >> ' if area != 'remove' else 'rm -- ')
            shim = self.root / 'drift-candidate-receipt'
            shim.write_text('#!/bin/sh\ncase "$*" in *"/candidate.json.new"*) ' + operation + '"' + str(target) + '";; esac\nexec "' + self.bb + '" "$@"\n')
            shim.chmod(0o700)
            result = self.run_candidate(bb=str(shim))
            self.assertNotEqual(result.returncode, 0, area)
            self.assertTrue((self.base / 'candidate.json.new').exists())
            self.assertFalse((self.base / 'candidate.json').exists())
            self.assertTrue((self.root / 'tmp/home-gateway-deploy.lock').is_symlink())
            self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARING\n')
            self.lab.assert_previous()
