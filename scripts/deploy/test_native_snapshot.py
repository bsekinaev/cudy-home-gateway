"""Native ucode snapshot of an authentic 18-file shell-receiver transaction."""
import json
import os
from pathlib import Path
import shutil
import signal
import time
import subprocess
import unittest

import test_migration
from migration_lab import OLD, RECEIVERS, mode

MODULE = Path(__file__).with_name('migration-snapshot.uc').resolve()
STATE = MODULE.with_name('migration-state.uc')


class NativeSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.lab = test_migration.MigrationTests('test_apply_idempotent_rollback_and_legacy_rollback_preserved')
        self.lab.setUp()
        self.addCleanup(self.lab.doCleanups)
        self.root = self.lab.root
        self.base = self.root / 'etc/home-gateway-migration'
        self.bb = shutil.which(os.environ.get('HG_TEST_BUSYBOX', 'busybox'))
        self.assertIsNotNone(self.bb)

    def snapshot_command(self, bb=None):
        script = ('import { open_state } from ' + json.dumps(str(STATE)) + '; '
                  'import { prepare_legacy_snapshot } from ' + json.dumps(str(MODULE)) + '; '
                  'let s=open_state(ARGV[0], true, ARGV[1]); '
                  'let result=prepare_legacy_snapshot(ARGV[0], s, ARGV[1]); print(sprintf("%J", result));')
        return ['ucode', '-e', script, '--', str(self.root), bb or self.bb]

    def run_snapshot(self, bb=None):
        return subprocess.run(self.snapshot_command(bb), capture_output=True, text=True, timeout=30)

    def run_verify(self):
        script = ('import { open_state } from ' + json.dumps(str(STATE)) + '; '
                  'import { verify_legacy_snapshot } from ' + json.dumps(str(MODULE)) + '; '
                  'let s=open_state(ARGV[0], false, ARGV[1]); '
                  'let result=verify_legacy_snapshot(ARGV[0], s, ARGV[1]); print(sprintf("%J", result));')
        return subprocess.run(['ucode', '-e', script, '--', str(self.root), self.bb],
                              capture_output=True, text=True, timeout=30)

    def test_verified_snapshot_preserves_runtime_receiver_latest_and_journal(self):
        result = self.run_snapshot()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        verified = self.run_verify()
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(json.loads(verified.stdout), receipt)
        self.assertEqual(receipt['format'], 'HG_LEGACY_SNAPSHOT_V1')
        self.assertEqual(receipt['latest'], (self.lab.base / 'latest').read_text())
        for rel in (*OLD, *RECEIVERS):
            copy = self.base / 'old/runtime' / rel
            self.assertEqual(copy.read_bytes(), self.lab.previous[rel])
            self.assertEqual(copy.stat().st_mode & 0o777, mode(rel))
        self.assertEqual(self.lab.freeze(self.base / 'old/journal'), self.lab.journal)
        self.lab.assert_previous()
        self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARING\n')
        self.assertTrue((self.root / 'tmp/home-gateway-deploy.lock').is_symlink())
        self.assertFalse((self.base / 'admission').exists())
        # Snapshots cannot be silently adopted/replaced by a second preparation.
        old = (self.base / 'snapshot.json').read_bytes()
        self.assertNotEqual(self.run_snapshot().returncode, 0)
        self.assertEqual((self.base / 'snapshot.json').read_bytes(), old)

    def test_each_legacy_pin_mismatch_refused_before_snapshot_writes(self):
        for rel in RECEIVERS:
            path = self.root / rel
            original = path.read_bytes()
            path.write_bytes(original + b'# mismatch\n')
            result = self.run_snapshot()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('LEGACY_IDENTITY', result.stderr)
            self.assertFalse((self.base / 'old').exists())
            path.write_bytes(original)
        self.lab.assert_previous()

    def test_corrupt_manifest_traversal_noncanonical_latest_and_metadata(self):
        targets = [(self.lab.tx / 'new.sha256', b'0' * 64 + b'  ../../etc/shadow\n'),
                   (self.lab.base / 'latest', (self.lab.base / 'latest').read_bytes().rstrip(b'\n'))]
        for path, data in targets:
            original = path.read_bytes(); path.write_bytes(data)
            self.assertNotEqual(self.run_snapshot().returncode, 0)
            self.assertFalse((self.base / 'old').exists())
            path.write_bytes(original)
        path = self.root / OLD[-1]; path.chmod(0o600)
        self.assertNotEqual(self.run_snapshot().returncode, 0)
        self.assertFalse((self.base / 'old').exists())
        path.chmod(mode(OLD[-1]))
        self.lab.assert_previous()

    def test_unexpected_inventory_and_hardlink_refused(self):
        path = self.root / 'usr/lib/home-gateway/foreign.sh'
        path.write_bytes(b'KEEP'); path.chmod(0o644)
        self.assertNotEqual(self.run_snapshot().returncode, 0)
        self.assertEqual(path.read_bytes(), b'KEEP')
        path.unlink()
        os.link(self.root / OLD[-1], self.root / 'linked-runtime')
        self.assertNotEqual(self.run_snapshot().returncode, 0)
        self.assertFalse((self.base / 'old').exists())

    def test_snapshot_fsync_failure_preserves_partial_and_does_not_replay(self):
        shim = self.root / 'fsync-failure'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/old/"*) exit 1;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        result = self.run_snapshot(str(shim))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.base / 'old').exists())
        self.assertFalse((self.base / 'snapshot.json').exists())
        before = self.lab.freeze(self.base / 'old')
        self.assertNotEqual(self.run_snapshot().returncode, 0)
        self.assertEqual(self.lab.freeze(self.base / 'old'), before)
        self.lab.assert_previous()

    def test_insufficient_space_refused_before_copy(self):
        shim = self.root / 'df-shim'
        shim.write_text('#!/bin/sh\ncase "$1" in df) printf "Filesystem 1024-blocks Used Available Capacity Mounted\\nroot 1000 999 1 99%% /\\n"; exit 0;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        result = self.run_snapshot(str(shim))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SPACE', result.stderr)
        self.assertFalse((self.base / 'old').exists())
        self.lab.assert_previous()

    def test_snapshot_corruption_unknown_entry_and_receipt_nonce_refused(self):
        result = self.run_snapshot()
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.base / 'old/runtime' / OLD[-1]
        original = path.read_bytes(); path.write_bytes(original + b'# corruption\n')
        self.assertNotEqual(self.run_verify().returncode, 0)
        path.write_bytes(original)
        unknown = self.base / 'old/foreign'
        unknown.write_bytes(b'KEEP'); unknown.chmod(0o600)
        self.assertNotEqual(self.run_verify().returncode, 0)
        self.assertEqual(unknown.read_bytes(), b'KEEP'); unknown.unlink()
        path = self.base / 'snapshot.json'
        original = path.read_bytes(); receipt = json.loads(original)
        receipt['marker'] = 'HG_MIGRATION_STATE_V1 00000000-0000-0000-0000-000000000000\n'
        path.write_text(json.dumps(receipt))
        self.assertNotEqual(self.run_verify().returncode, 0)
        path.write_bytes(original)
        os.link(self.base / 'old/latest', self.root / 'linked-snapshot')
        self.assertNotEqual(self.run_verify().returncode, 0)
        self.lab.assert_previous()

    def test_actual_sigkill_keeps_fence_and_refuses_partial_snapshot_replay(self):
        shim = self.root / 'fsync-block'
        ready = self.root / 'snapshot-write-entered'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/old/"*) touch "' + str(ready) + '"; sleep 10;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        child = subprocess.Popen(self.snapshot_command(str(shim)), stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(ready.exists(), child.poll())
            child.kill(); child.wait(timeout=3)
            self.assertTrue((self.base / 'old').is_dir())
            self.assertFalse((self.base / 'snapshot.json').exists())
            self.assertTrue((self.root / 'tmp/home-gateway-deploy.lock').is_symlink())
            self.assertNotEqual(self.run_snapshot().returncode, 0)
            self.lab.assert_previous()
        finally:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=3)

    def test_source_drift_during_snapshot_does_not_publish_receipt(self):
        path = self.root / OLD[-1]
        original = path.read_bytes()
        shim = self.root / 'fsync-drift'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/old/"*) printf "# drift\\n" >> "' + str(path) + '";; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        result = self.run_snapshot(str(shim))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SOURCE_CHANGED', result.stderr)
        self.assertFalse((self.base / 'snapshot.json').exists())
        self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARING\n')
        path.write_bytes(original)
        self.lab.assert_previous()

    def test_committed_journal_requires_all_three_original_logs(self):
        for name in ('preflight.log','postflight.log','service.log'):
            path=self.lab.tx / name; raw=path.read_bytes(); path.unlink()
            result=self.run_snapshot()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.base / 'old').exists())
            path.write_bytes(raw); path.chmod(0o600)
        self.lab.assert_previous()

    def test_pending_legacy_pointers_refused_without_adoption(self):
        for name in ('active.new','latest.new'):
            path=self.lab.base / name; path.write_bytes(b'tx.pending\n'); path.chmod(0o600)
            self.assertNotEqual(self.run_snapshot().returncode, 0)
            self.assertFalse((self.base / 'old').exists())
            self.assertEqual(path.read_bytes(), b'tx.pending\n')
            path.unlink()
        self.lab.assert_previous()

    def test_library_or_journal_addition_during_copy_refuses_publication(self):
        for area in ('library','journal'):
            # Each subcase needs a fresh authentic legacy transaction/snapshot.
            if area == 'journal':
                self.doCleanups(); self.setUp()
            target=(self.root / 'usr/lib/home-gateway/actions.uc') if area == 'library' else (self.lab.tx / 'foreign.log')
            shim=self.root / 'add-during-snapshot'
            shim.write_text('#!/bin/sh\ncase "$*" in *"/old/"*) if [ ! -e "' + str(target) + '" ]; then printf "added\n" > "' + str(target) + '"; chmod 600 "' + str(target) + '"; fi;; esac\nexec "' + self.bb + '" "$@"\n')
            shim.chmod(0o700)
            result=self.run_snapshot(str(shim))
            self.assertNotEqual(result.returncode, 0, area)
            self.assertTrue(target.exists(), 'writer fault must execute')
            self.assertFalse((self.base / 'snapshot.json').exists())
            self.assertTrue((self.root / 'tmp/home-gateway-deploy.lock').is_symlink())


if __name__ == '__main__': unittest.main()
