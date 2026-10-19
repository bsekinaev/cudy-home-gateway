"""Actual shell read-only persistent admission, independent of migration mocks."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('migration-admission.sh')


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / '.hg-deploy-test-root').write_text('DISPOSABLE\n')
        (self.root / 'etc').mkdir()
        (self.root / 'tmp').mkdir()
        self.base = self.root / 'etc/home-gateway-migration'

    def run_gate(self, *flags):
        command = os.environ.get('HG_TEST_SHELL', '/bin/sh').split()
        return subprocess.run(command + [str(SCRIPT), '--test-root', str(self.root), *flags],
                              capture_output=True, timeout=5).returncode

    def state(self, phase='COMMITTED', receipt=True):
        self.base.mkdir(mode=0o700, exist_ok=True)
        marker=self.base / 'marker'
        marker.write_text('HG_MIGRATION_STATE_V1 11111111-2222-3333-4444-555555555555\n'); marker.chmod(0o600)
        lock=self.root / 'etc/home-gateway-migration.lock'
        if not lock.exists(): lock.touch(mode=0o600)
        (self.base / 'phase').write_text(phase + '\n')
        (self.base / 'phase').chmod(0o600)
        if receipt:
            (self.base / 'admission').write_text('HG_MIGRATION_ADMITTED_V2 ' + phase + ' 11111111-2222-3333-4444-555555555555 ' + str(lock.stat().st_ino) + '\n')
            (self.base / 'admission').chmod(0o600)

    def test_terminal_marker_and_guard_identity_required(self):
        self.state()
        for path in (self.base / 'marker', self.root / 'etc/home-gateway-migration.lock'):
            raw=path.read_bytes(); path.unlink()
            self.assertNotEqual(self.run_gate(), 0)
            path.write_bytes(raw); path.chmod(0o600)
            path.chmod(0o644); self.assertNotEqual(self.run_gate(), 0); path.chmod(0o600)
            path.write_bytes(b'CORRUPT\n'); self.assertNotEqual(self.run_gate(), 0)
            path.write_bytes(raw)
        self.state()
        self.assertEqual(self.run_gate(), 0)

    def test_replaced_valid_marker_or_empty_guard_cannot_reuse_old_receipt(self):
        self.state()
        (self.base / 'marker').write_text('HG_MIGRATION_STATE_V1 aaaaaaaa-2222-3333-4444-555555555555\n')
        self.assertNotEqual(self.run_gate(), 0)
        self.state()
        lock=self.root / 'etc/home-gateway-migration.lock'
        lock.rename(lock.with_name('saved-guard'))
        lock.touch(mode=0o600)
        self.assertNotEqual(self.run_gate(), 0)

    def test_terminal_gate_refuses_held_coordinator_guard(self):
        import fcntl
        self.state("ROLLED_BACK")
        with (self.root / 'etc/home-gateway-migration.lock').open('rb') as guard:
            fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.run_gate('--telegram-start'), 0)
            self.assertNotEqual(self.run_gate('--receiver-recover'), 0)
        self.assertEqual(self.run_gate('--telegram-start'), 0)

    def test_borrowed_start_guard_survives_complete_parent_handshake(self):
        import json
        import shlex
        import shutil
        self.state("ROLLED_BACK")
        self.assertNotEqual(self.run_gate('--telegram-start', '--held-telegram-guard'), 0)
        bb=shutil.which(os.environ.get('HG_TEST_BUSYBOX', 'busybox'))
        command=os.environ.get('HG_TEST_SHELL', '/bin/sh').split()
        gate=command + [str(SCRIPT), '--test-root', str(self.root), '--telegram-start', '--held-telegram-guard']
        module=SCRIPT.with_name('migration-state.uc').resolve()
        code='import { open_state } from ' + json.dumps(str(module)) + '; open_state(ARGV[0], false, ARGV[1]);'
        probe=['ucode', '-e', code, '--', str(self.root), bb]
        body=('exec 8< ' + shlex.quote(str(self.root / 'etc/home-gateway-migration.lock')) + '\n' +
              shlex.join([bb, 'flock', '-n', '8']) + ' || exit 1\n' +
              shlex.join(gate) + ' || exit 2\nif ' + shlex.join(probe) + '; then exit 3; fi\n' +
              shlex.join(gate) + ' || exit 4\nexec 8<&-\n' + shlex.join(probe))
        result=subprocess.run(command + ['-c', body], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('BUSY', result.stderr)

    def test_committed_telegram_requires_a_published_runtime_journal(self):
        self.state()
        self.assertNotEqual(self.run_gate('--telegram-start'),0)
        self.assertEqual(self.run_gate(),0)  # receiver may create its own lease

    def test_missing_state_allows_and_does_not_create_files(self):
        self.assertEqual(self.run_gate(), 0)
        self.assertFalse(self.base.exists())

    def test_terminal_exact_receipt_required(self):
        self.state(receipt=False)
        self.assertNotEqual(self.run_gate(), 0)
        self.state()
        self.assertEqual(self.run_gate(), 0)
        self.state('ROLLED_BACK')
        self.assertEqual(self.run_gate(), 0)
        (self.base / 'admission').write_text('HG_MIGRATION_ADMITTED_V1 COMMITTED\n')
        self.assertNotEqual(self.run_gate(), 0)

    def test_incomplete_unknown_and_interrupted_phases_block_after_reboot(self):
        self.base.mkdir(mode=0o700)
        self.assertNotEqual(self.run_gate(), 0)
        for phase in ('PREPARING', 'PREPARED', 'APPLYING', 'RESTORING', 'UNKNOWN', ''):
            self.state(phase)
            self.assertNotEqual(self.run_gate(), 0)
            self.assertFalse((self.root / 'tmp/home-gateway-deploy.lock').exists())

    def test_foreign_and_dangling_fence_is_not_removed(self):
        fence = self.root / 'tmp/home-gateway-deploy.lock'
        fence.symlink_to('/not-a-real-lock-target')
        self.assertNotEqual(self.run_gate(), 0)
        self.assertTrue(fence.is_symlink())
        fence.unlink(); fence.mkdir()
        self.assertNotEqual(self.run_gate(), 0)
        self.assertTrue(fence.is_dir())

    def test_symlink_hardlink_and_wrong_mode_refused(self):
        self.state()
        p = self.base / 'phase'; original = p.read_bytes()
        p.chmod(0o644)
        self.assertNotEqual(self.run_gate(), 0)
        p.chmod(0o600)
        os.link(p, self.base / 'other')
        self.assertNotEqual(self.run_gate(), 0)
        (self.base / 'other').unlink()
        p.unlink(); (self.base / 'other').write_bytes(original)
        p.symlink_to('other')
        self.assertNotEqual(self.run_gate(), 0)

    def test_terminal_recover_accepts_only_canonical_pid_lease_without_cleanup(self):
        self.state()
        fence = self.root / 'tmp/home-gateway-deploy.lock'; fence.mkdir(mode=0o700)
        pid = fence / 'pid'; pid.write_text('999999999\n'); pid.chmod(0o600)
        self.assertNotEqual(self.run_gate(), 0)
        self.assertEqual(self.run_gate('--receiver-recover'), 0)
        self.assertEqual(pid.read_bytes(), b'999999999\n')
        for raw in (b'0\n', b'12', b'12\n\n', b'../pid\n'):
            pid.write_bytes(raw)
            self.assertNotEqual(self.run_gate('--receiver-recover'), 0)
        pid.write_text('999999999\n')
        self.state('APPLYING')
        self.assertNotEqual(self.run_gate('--receiver-recover'), 0)
        self.assertTrue(fence.is_dir())

    def test_terminal_receipt_never_admits_migration_symlink_as_receiver_lease(self):
        self.state()
        fence = self.root / 'tmp/home-gateway-deploy.lock'
        fence.symlink_to(self.base)
        self.assertNotEqual(self.run_gate('--receiver-recover'), 0)
        self.assertTrue(fence.is_symlink())

    def test_telegram_checking_restored_require_exact_hgdeploy2_runtime(self):
        import hashlib
        import test_deploy
        fixture = test_deploy.DeployTests('test_plan_never_changes_runtime')
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        self.root = fixture.root; self.base = self.root / 'etc/home-gateway-migration'
        fixture.base.chmod(0o700)
        self.state()
        tx = fixture.base / 'tx.vm'; tx.mkdir(mode=0o700)
        for name, raw in {'inventory-version': b'HGDEPLOY2\n', 'phase': b'CHECKING\n'}.items(): fixture.put(tx / name, raw, 0o600)
        fixture.put(fixture.base / 'active', 'tx.vm\n', 0o600)
        manifest = ''.join(hashlib.sha256((self.root / rel).read_bytes()).hexdigest() + '  ' + rel + '\n' for rel in test_deploy.PATHS)
        for name in ('new.sha256', 'backup.sha256'): fixture.put(tx / name, manifest, 0o600)
        fence = self.root / 'tmp/home-gateway-deploy.lock'; fence.mkdir(mode=0o700)
        fixture.put(fence / 'pid', str(os.getpid()) + '\n', 0o600)
        for phase in ('CHECKING', 'RESTORED', 'COMMITTED'):
            fixture.put(tx / 'phase', phase + '\n', 0o600)
            self.assertEqual(self.run_gate('--telegram-start'), 0, phase)
        fixture.put(tx / 'phase', 'APPLYING\n', 0o600)
        self.assertNotEqual(self.run_gate('--telegram-start'), 0)
        fixture.put(tx / 'phase', 'CHECKING\n', 0o600)
        fixture.put(tx / 'inventory-version', 'HGDEPLOY1\n', 0o600)
        self.assertNotEqual(self.run_gate('--telegram-start'), 0)
        fixture.put(tx / 'inventory-version', 'HGDEPLOY2\n', 0o600)
        target = self.root / test_deploy.PATHS[-1]
        target.write_bytes(target.read_bytes() + b'# drift\n')
        self.assertNotEqual(self.run_gate('--telegram-start'), 0)

    def test_later_hgdeploy2_sigkill_recovery_after_terminal_migration(self):
        import test_deploy
        fixture = test_deploy.DeployTests('test_plan_never_changes_runtime')
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        self.root = fixture.root; self.base = self.root / 'etc/home-gateway-migration'
        self.state()
        fixture.put(self.root / 'usr/libexec/home-gateway-deploy/migration-admission.sh', SCRIPT.read_bytes(), 0o700)
        fixture.new[test_deploy.PATHS[0]] += b'# new init\n'
        fixture.put(fixture.bin / 'mv', '#!/bin/sh\n/bin/mv "$@" || exit 1\ncase "$*" in *"' + str(self.root / test_deploy.PATHS[0]) + '"*) kill -KILL "$PPID";; esac\n', 0o755)
        self.assertNotEqual(fixture.run_engine('apply').returncode, 0)
        self.assertTrue((fixture.base / 'active').exists())
        (fixture.bin / 'mv').unlink()
        result = fixture.run_engine('recover')
        self.assertEqual(result.returncode, 0, result.stdout)
        fixture.assert_old()
        self.assertFalse((self.root / 'tmp/home-gateway-deploy.lock').exists())

    def test_terminal_receipt_with_unpublished_write_blocks_after_ram_loss(self):
        self.state()
        for name in ('phase.new', 'admission.new'):
            pending = self.base / name
            pending.write_bytes(b'INTERRUPTED\n'); pending.chmod(0o600)
            self.assertNotEqual(self.run_gate(), 0)
            self.assertNotEqual(self.run_gate('--receiver-recover'), 0)
            self.assertNotEqual(self.run_gate('--telegram-start'), 0)
            self.assertEqual(pending.read_bytes(), b'INTERRUPTED\n')
            pending.unlink()
        self.assertEqual(self.run_gate(), 0)

    def test_noncanonical_terminal_bytes_refused(self):
        self.state()
        for raw in (b'COMMITTED', b'COMMITTED\n\n', b'COMMITTED\x00\n'):
            (self.base / 'phase').write_bytes(raw)
            self.assertNotEqual(self.run_gate(), 0)
        self.state()
        (self.base / 'admission').write_bytes(b'HG_MIGRATION_ADMITTED_V1 COMMITTED')
        self.assertNotEqual(self.run_gate(), 0)


if __name__ == '__main__': unittest.main()
