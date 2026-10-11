"""Real filesystem/BusyBox legacy receiver migration rehearsals; no CUDY access."""
import base64
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from migration_lab import Migration, Refused, OLD, NEW, ALL, ADDED, RECEIVERS, digest, mode
import test_deploy
COMMIT = test_deploy.COMMIT

LEGACY = Path(__file__).with_name('fixtures') / 'legacy-engine-18.sh'


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_deploy.DeployTests('test_plan_never_changes_runtime')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root, self.base = self.fixture.root, self.fixture.base
        self.base.chmod(0o700)
        (self.root / '.hg-migration-lab').write_bytes(b'DISPOSABLE_HG_MIGRATION_LAB\n')
        for p in ADDED:
            (self.root / p).unlink()
        self.assertEqual(digest(LEGACY.read_bytes()), '4b1f9ea568167a67f24470615b31efe4b9fd7a68374e666443ad31945e58922e')
        for rel in RECEIVERS:
            data = LEGACY.read_bytes() if rel == RECEIVERS[0] else b'#!/bin/sh\nexit 0\n'
            self.fixture.put(self.root / rel, data, mode(rel))
        # Create an authentic COMMITTED 18-file journal using the original receiver.
        self.old = {p: (self.root / p).read_bytes() for p in OLD + RECEIVERS}
        self.live = dict(self.old)
        self.live['usr/lib/home-gateway/common.sh'] += b'# installed legacy update\n'
        wire = [f'HGDEPLOY1 {COMMIT}\n'.encode()]
        for rel in OLD:
            data = self.live[rel]
            wire += [f'{mode(rel):04o} {len(data)} {digest(data)}\n'.encode(), base64.b64encode(data) + b'\n']
        wire = b''.join(wire) + b'END\n'
        result = self.legacy('apply', wire)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.tx = self.base / (self.base / 'latest').read_text().strip()
        self.journal = self.freeze(self.tx)
        self.previous = {p: (self.root / p).read_bytes() for p in OLD + RECEIVERS}
        self.candidate = self.root / 'candidate'
        for rel in ALL:
            if rel == RECEIVERS[0]:
                data = Path(__file__).with_name('engine.sh').read_bytes()
            else:
                data = self.previous.get(rel, b'// new module\n') + b'\n# candidate\n'
            self.fixture.put(self.candidate / rel, data, mode(rel))
        raw = ''.join(f'{digest((self.candidate / p).read_bytes())}  {p}\n' for p in ALL).encode()
        self.fixture.put(self.candidate / 'migration.sha256', raw, 0o600)
        self.sha = digest(raw)
        self.m = Migration(self.root)
        self.addCleanup(self.m.close)

    def freeze(self, base):
        return {str(p.relative_to(base)): (p.read_bytes(), p.stat().st_mode & 0o777)
                for p in base.rglob('*') if p.is_file()}

    def legacy(self, operation, wire=None):
        cmd = os.environ.get('HG_TEST_SHELL', '/bin/sh').split() + [str(LEGACY), '--test-root', str(self.root), operation]
        if wire is not None:
            cmd += [COMMIT, digest(wire)]
        return subprocess.run(cmd, input=wire, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env=self.fixture.env, timeout=30)

    def prepare(self):
        self.assertEqual(self.m.prepare(self.candidate, self.sha), 'PREPARED')

    def assert_previous(self):
        for p, data in self.previous.items():
            self.assertEqual((self.root / p).read_bytes(), data)
            self.assertEqual((self.root / p).stat().st_mode & 0o777, mode(p))
        for p in ADDED:
            self.assertFalse((self.root / p).exists())
        self.assertEqual(self.freeze(self.tx), self.journal)
        self.assertTrue(self.fixture.running.exists())

    def test_apply_idempotent_rollback_and_legacy_rollback_preserved(self):
        self.prepare()
        self.assert_previous()
        self.assertEqual(self.m.apply(), 'COMMITTED')
        self.assertEqual(self.m.apply(), 'ALREADY_COMMITTED')
        self.assertEqual(self.freeze(self.tx), self.journal)
        for p in ALL:
            self.assertEqual((self.root / p).read_bytes(), (self.candidate / p).read_bytes())
        self.assertEqual(self.m.rollback(), 'ROLLED_BACK')
        self.assertEqual(self.m.rollback(), 'ROLLED_BACK')
        self.assert_previous()
        result = self.legacy('rollback')
        self.assertEqual(result.returncode, 0, result.stdout)
        for p in OLD:
            self.assertEqual((self.root / p).read_bytes(), self.old[p])

    def test_corrupted_new_and_backup_manifests(self):
        for name in ('new.sha256', 'backup.sha256'):
            path = self.tx / name
            old = path.read_bytes()
            path.write_bytes(b'0' * 64 + old[64:])
            with self.assertRaises(Refused):
                self.m.legacy()
            path.write_bytes(old)
        self.assert_previous()

    def test_manifest_traversal_duplicates_wrong_inventory(self):
        p = self.tx / 'new.sha256'
        original = p.read_bytes()
        for raw in (original.replace(b'usr/bin/gateway', b'../../etc/shadow'),
                    original + original.splitlines(True)[0], b''):
            p.write_bytes(raw)
            with self.assertRaises(Refused):
                self.m.legacy()
        p.write_bytes(original)
        self.assert_previous()

    def test_wrong_phase_active_and_mixed_format(self):
        p = self.tx / 'phase'
        p.write_bytes(b'APPLYING\n')
        with self.assertRaises(Refused):
            self.m.legacy()
        p.write_bytes(b'COMMITTED\n')
        (self.tx / 'inventory-version').write_bytes(b'HGDEPLOY2\n')
        with self.assertRaises(Refused):
            self.m.legacy()
        (self.tx / 'inventory-version').unlink()
        (self.base / 'active').symlink_to('/nonexistent')
        with self.assertRaises(Refused):
            self.m.legacy()
        (self.base / 'active').unlink()
        self.assert_previous()

    def test_symlink_runtime_parent_journal_and_hardlink(self):
        p = self.root / OLD[1]
        saved = p.read_bytes()
        p.unlink()
        p.symlink_to(self.root / OLD[2])
        with self.assertRaises(Refused):
            self.m.legacy()
        p.unlink()
        self.fixture.put(p, saved, mode(OLD[1]))
        os.link(p, self.root / 'hardlink')
        with self.assertRaises(Refused):
            self.m.legacy()
        (self.root / 'hardlink').unlink()
        parent = self.root / 'usr/lib/home-gateway'
        parent.rename(self.root / 'saved-library')
        parent.symlink_to(self.root / 'saved-library')
        with self.assertRaises(Refused):
            self.m.legacy()
        parent.unlink()
        (self.root / 'saved-library').rename(parent)
        latest = self.base / 'latest'
        data = latest.read_bytes()
        latest.unlink()
        latest.symlink_to(self.root / 'missing')
        with self.assertRaises(Refused):
            self.m.legacy()
        latest.unlink()
        self.fixture.put(latest, data, 0o600)
        self.assert_previous()

    def test_missing_file_drift_mode_and_owner(self):
        p = self.root / OLD[3]
        data = p.read_bytes()
        p.unlink()
        with self.assertRaises(OSError):
            self.m.legacy()
        self.fixture.put(p, data + b'drift', mode(OLD[3]))
        with self.assertRaises(Refused):
            self.m.legacy()
        self.fixture.put(p, data, 0o600)
        with self.assertRaises(Refused):
            self.m.legacy()
        p.chmod(mode(OLD[3]))
        # This runtime maps only UID 0; exercise caller/actual stat mismatch
        # without pretending chown to an unmapped UID succeeded.
        with patch('migration_lab.os.geteuid', return_value=os.geteuid() + 17):
            with self.assertRaisesRegex(Refused, 'OWNER'):
                self.m.legacy()
        self.assert_previous()

    def test_candidate_hash_and_missing_member(self):
        with self.assertRaises(Refused):
            self.m.prepare(self.candidate, '0' * 64)
        (self.candidate / ADDED[0]).unlink()
        with self.assertRaises(OSError):
            self.m.prepare(self.candidate, self.sha)
        self.assert_previous()

    def test_repeat_preparation_and_parallel_lock_refused(self):
        self.prepare()
        with self.assertRaises(Refused):
            self.m.prepare(self.candidate, self.sha)
        with self.assertRaisesRegex(Refused, 'MIGRATION_BUSY'):
            Migration(self.root)
        self.assert_previous()

    def test_drift_after_preparation_refuses_before_write(self):
        self.prepare()
        p = self.root / OLD[3]
        saved = p.read_bytes()
        p.write_bytes(saved + b'drift')
        with self.assertRaises(Refused):
            self.m.apply()
        self.assertEqual((self.m.state / 'phase').read_text(), 'PREPARED\n')
        p.write_bytes(saved)
        self.assert_previous()

    def test_interrupted_apply_retains_fence_and_recovers_previous(self):
        self.prepare()
        import migration_lab
        real = migration_lab.write
        count = 0
        def fail(path, data, permissions):
            nonlocal count
            real(path, data, permissions)
            if str(path).endswith('usr/lib/home-gateway/actions.uc'):
                count += 1
                raise SystemExit('crash after real rename')
        with patch.object(migration_lab, 'write', fail), self.assertRaises(SystemExit):
            self.m.apply()
        self.assertEqual(count, 1)
        self.assertEqual((self.m.state / 'phase').read_text(), 'APPLYING\n')
        self.assertNotEqual(self.legacy('recover').returncode, 0)
        with self.assertRaisesRegex(Refused, 'RECOVERY_REQUIRED'):
            self.m.apply()
        self.assertEqual(self.m.rollback(), 'ROLLED_BACK')
        self.assert_previous()

    def test_interrupted_rollback_can_repeat(self):
        self.prepare()
        self.m.apply()
        import migration_lab
        real = migration_lab.write
        def fail(path, data, permissions):
            real(path, data, permissions)
            if path == self.root / OLD[3]:
                raise SystemExit('crash')
        with patch.object(migration_lab, 'write', fail), self.assertRaises(SystemExit):
            self.m.rollback()
        self.assertEqual(self.m.rollback(), 'ROLLED_BACK')
        self.assert_previous()

    def test_corrupted_snapshot_and_receipt_refuse_rollback(self):
        self.prepare()
        self.m.apply()
        p = self.m.state / 'old' / OLD[3]
        p.write_bytes(p.read_bytes() + b'drift')
        before = self.freeze(self.root / 'usr')
        with self.assertRaises(Refused):
            self.m.rollback()
        self.assertEqual(self.freeze(self.root / 'usr'), before)
        (self.m.state / 'receipt.json').write_text('{}')
        with self.assertRaises(Refused):
            self.m.rollback()

    def test_later_v2_deployment_refuses_migration_rollback(self):
        self.prepare()
        self.m.apply()
        self.fixture.put(self.base / 'latest', b'tx.newv2\n', 0o600)
        with self.assertRaisesRegex(Refused, 'NEW_DEPLOYMENT_EXISTS'):
            self.m.rollback()

    def test_external_deploy_lock_and_partial_fence_refused(self):
        self.prepare()
        lock = self.root / 'tmp/home-gateway-deploy.lock'
        lock.mkdir(mode=0o700)
        with self.assertRaisesRegex(Refused, 'DEPLOYMENT_BUSY'):
            self.m.apply()
        self.assert_previous()

    def test_actual_sigkill_during_apply_then_reopen_rollback(self):
        self.prepare()
        self.m.close()
        script = """import os,signal,sys
from pathlib import Path
import migration_lab
m=migration_lab.Migration(sys.argv[1])
real=migration_lab.write
def crash(path,data,permissions):
    real(path,data,permissions)
    if path == m.root / 'usr/lib/home-gateway/actions.uc':
        os.kill(os.getpid(), signal.SIGKILL)
migration_lab.write=crash
m.apply()
"""
        env = dict(os.environ, PYTHONPATH=str(Path(__file__).parent.resolve()))
        result = subprocess.run([os.sys.executable, '-c', script, str(self.root)], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.returncode, -9, result.stderr)
        self.m = Migration(self.root)
        self.addCleanup(self.m.close)
        self.assertEqual(self.m.rollback(), 'ROLLED_BACK')
        self.assert_previous()

    def test_real_busybox_readonly_preflight_and_drift_refusal(self):
        cmd = os.environ.get('HG_TEST_SHELL', '/bin/sh').split() + [str(Path(__file__).with_name('legacy-preflight.sh')), '--test-root', str(self.root), digest(LEGACY.read_bytes())]
        before = self.freeze(self.base)
        result = subprocess.run(cmd, capture_output=True, env=self.fixture.env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'MUTATIONS=0', result.stdout)
        self.assertEqual(self.freeze(self.base), before)
        (self.root / OLD[3]).write_bytes(b'drift')
        result = subprocess.run(cmd, capture_output=True, env=self.fixture.env, timeout=30)
        self.assertEqual(result.returncode, 70)
        self.assertNotIn(b'common.sh', result.stderr)

    def test_real_root_and_no_sentinel_refused(self):
        with self.assertRaises(Refused):
            Migration('/')
        (self.root / '.hg-migration-lab').unlink()
        with self.assertRaises(OSError):
            Migration(self.root)


if __name__ == '__main__':
    unittest.main()
