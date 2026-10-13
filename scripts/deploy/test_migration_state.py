"""Actual ucode/BusyBox flock, fsync and symlink fence; not runtime migration."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

MODULE = Path(__file__).with_name('migration-state.uc').resolve()


class MigrationStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / '.hg-deploy-test-root').write_text('DISPOSABLE\n')
        (self.root / 'etc').mkdir(); (self.root / 'tmp').mkdir()
        self.base = self.root / 'etc/home-gateway-migration'
        self.ram = self.root / 'tmp/home-gateway-deploy.lock'
        self.bb = shutil.which(os.environ.get('HG_TEST_BUSYBOX', 'busybox'))
        self.assertIsNotNone(self.bb)

    def command(self, body='', create=True, bb=None):
        script = f'import {{ open_state }} from {json.dumps(str(MODULE))}; let s=open_state(ARGV[0], {str(create).lower()}, ARGV[1]); ' + body
        return ['ucode', '-e', script, str(self.root), bb or self.bb]

    def run_state(self, body='', create=True, bb=None):
        return subprocess.run(self.command(body, create, bb), capture_output=True, text=True, timeout=10)

    def success(self, body='', create=True):
        result = self.run_state(body, create)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_closed_guard_and_wrong_root_cannot_mutate_state(self):
        self.success('s.fence();')
        for op in ('s.transition("PREPARED");', 's.fence();', 's.release();', 's.assert_root(ARGV[0]);'):
            result = self.run_state('s.close(); ' + op, False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARING\n')
            self.assertTrue(self.ram.is_symlink())
        self.assertNotEqual(self.run_state('s.assert_root("/not-the-held-root");', False).returncode, 0)
        self.success('s.assert_root(ARGV[0]);', False)

    def test_private_durable_initialization_and_readonly_reopen(self):
        self.assertEqual(self.success('print(s.phase());'), 'PREPARING')
        self.assertEqual(self.base.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.base / 'phase').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.success('print(s.phase());', False), 'PREPARING')
        self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARING\n')

    def test_interrupted_private_initialization_retries_without_adoption(self):
        shim = self.root / 'initial-fsync-failure'
        shim.write_text('#!/bin/sh\ncase "$*" in *".initializing."*) exit 1;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        self.assertNotEqual(self.run_state(bb=str(shim)).returncode, 0)
        self.assertFalse(self.base.exists())
        staged = list((self.root / 'etc').glob('home-gateway-migration.initializing.*'))
        self.assertEqual(len(staged), 1)
        original = (staged[0] / 'marker').read_bytes()
        (staged[0] / 'foreign').write_bytes(b'KEEP')
        self.success()
        self.assertEqual((staged[0] / 'marker').read_bytes(), original)
        self.assertEqual((staged[0] / 'foreign').read_bytes(), b'KEEP')
        self.assertNotEqual((self.base / 'marker').read_bytes(), original)
        self.assertFalse(self.ram.is_symlink())

    def test_sigkill_before_initial_phase_publication_allows_fresh_init(self):
        ready = self.root / 'initial-write-entered'
        shim = self.root / 'initial-fsync-block'
        shim.write_text('#!/bin/sh\ncase "$*" in *".initializing."*) touch "' + str(ready) + '"; sleep 10;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        child = subprocess.Popen(self.command(bb=str(shim)), stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(ready.exists())
            child.kill(); child.wait(timeout=3)
            self.assertFalse(self.base.exists())
            stranded = list((self.root / 'etc').glob('home-gateway-migration.initializing.*'))
            self.assertEqual(len(stranded), 1)
            self.success('s.fence();')
            self.assertTrue(stranded[0].is_dir())
            self.assertTrue(self.ram.is_symlink())
        finally:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=3)

    def test_transitions_require_owned_ram_and_persistent_fence(self):
        self.success()
        self.assertNotEqual(self.run_state('s.transition("PREPARED");', False).returncode, 0)
        self.success('s.fence(); s.transition("PREPARED");', False)
        self.ram.unlink()
        self.assertNotEqual(self.run_state('s.transition("APPLYING");', False).returncode, 0)
        self.ram.symlink_to('/not-our-fence')
        self.assertNotEqual(self.run_state('s.transition("RESTORING");', False).returncode, 0)
        self.assertEqual(self.ram.readlink(), Path('/not-our-fence'))
        self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARED\n')

    def test_pending_admission_never_releases_terminal_fence(self):
        self.success('s.fence(); s.transition("PREPARED"); s.transition("RESTORING"); s.transition("ROLLED_BACK");')
        admission = self.base / 'admission'
        admission.write_bytes(b'HG_MIGRATION_ADMITTED_V1 ROLLED_BACK\n'); admission.chmod(0o600)
        pending = self.base / 'admission.new'
        pending.write_bytes(admission.read_bytes()); pending.chmod(0o600)
        self.assertNotEqual(self.run_state('s.release();', False).returncode, 0)
        self.assertTrue(self.ram.is_symlink())
        self.assertTrue(pending.exists())

    def test_atomic_pidless_fence_blocks_actual_old_and_new_receiver(self):
        self.success('s.fence();')
        self.assertTrue(self.ram.is_symlink())
        self.assertEqual(self.ram.readlink(), self.base / 'fence')
        self.assertFalse((self.ram / 'pid').exists())
        (self.root / 'etc/home-gateway-deploy').mkdir(mode=0o700)
        for file in ('engine.sh', 'fixtures/legacy-engine-18.sh'):
            result = subprocess.run([self.bb, 'ash', str(MODULE.parent / file), '--test-root', str(self.root), 'status'], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(self.ram.is_symlink())

    def test_foreign_directory_and_dangling_symlink_never_removed(self):
        self.ram.mkdir()
        self.assertNotEqual(self.run_state('s.fence();').returncode, 0)
        self.assertTrue(self.ram.is_dir())
        self.ram.rmdir(); self.ram.symlink_to('/not-our-fence')
        self.assertNotEqual(self.run_state('s.fence();').returncode, 0)
        self.assertEqual(self.ram.readlink(), Path('/not-our-fence'))

    def test_ram_loss_reacquires_owned_fence_without_apply_replay(self):
        self.success('s.fence(); s.transition("PREPARED"); s.transition("APPLYING");')
        self.ram.unlink()
        self.success('s.fence();', False)
        self.assertNotEqual(self.run_state('s.transition("APPLYING");', False).returncode, 0)
        self.assertEqual((self.base / 'phase').read_bytes(), b'APPLYING\n')
        self.assertTrue(self.ram.is_symlink())

    def test_terminal_phase_does_not_release_without_verified_admission(self):
        self.success('s.fence(); s.transition("PREPARED"); s.transition("APPLYING"); s.transition("COMMITTED");')
        self.assertNotEqual(self.run_state('s.release();', False).returncode, 0)
        self.assertTrue(self.ram.is_symlink())
        p = self.base / 'admission'
        p.write_text('HG_MIGRATION_ADMITTED_V1 COMMITTED\n'); p.chmod(0o600)
        self.success('s.release();', False); self.success('s.release();', False)
        self.assertFalse(self.ram.is_symlink())

    def test_unknown_or_linked_phase_refused_without_cleanup(self):
        self.success('s.fence();')
        p = self.base / 'phase'
        p.write_text('UNKNOWN\n')
        self.assertNotEqual(self.run_state(create=False).returncode, 0)
        p.write_text('PREPARING\n'); os.link(p, self.base / 'other')
        self.assertNotEqual(self.run_state(create=False).returncode, 0)
        self.assertTrue(self.ram.is_symlink())

    def test_unknown_existing_state_not_adopted(self):
        self.base.mkdir(mode=0o700)
        self.assertNotEqual(self.run_state().returncode, 0)
        self.assertEqual(list(self.base.iterdir()), [])
        self.assertFalse((self.root / 'etc/home-gateway-migration.lock').exists())

    def test_nonce_bound_fence_and_symlink_hardlink_refused(self):
        self.success('s.fence();')
        marker = self.base / 'fence/marker'
        original = marker.read_bytes()
        marker.write_bytes(b'HG_MIGRATION_STATE_V1 00000000-0000-0000-0000-000000000000\n')
        self.assertNotEqual(self.run_state('s.fence();', False).returncode, 0)
        marker.write_bytes(original)
        os.link(self.ram, self.root / 'tmp/foreign-link', follow_symlinks=False)
        self.assertNotEqual(self.run_state('s.fence();', False).returncode, 0)
        self.assertTrue(self.ram.is_symlink())

    def test_busy_lock_and_cloexec_after_exact_owner_sigkill(self):
        self.success('s.fence();')
        ready = self.root / 'hold-ready'
        body = 'let p=fs.popen("sleep 10", "r"); fs.writefile(' + json.dumps(str(ready)) + ', "READY"); p.read("all");'
        # Import fs is part of this controlled harness, not the production API.
        cmd = self.command(body, False)
        cmd[2] = 'import * as fs from "fs"; ' + cmd[2]
        child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(ready.exists(), child.poll())
            self.assertNotEqual(self.run_state(create=False).returncode, 0)
            child.kill(); child.wait(timeout=3)
            # External sleep must not retain the kernel lock inherited from ucode.
            self.success('print(s.phase());', False)
            self.assertTrue(self.ram.is_symlink())
        finally:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=3)

    def test_checked_fsync_failure_and_sigkill_leave_incomplete_phase_blocked(self):
        self.success('s.fence(); s.transition("PREPARED");')
        shim = self.root / 'fsync-shim'
        ack = self.root / 'fsync-entered'
        # Only explicit lab roots accept a test BusyBox path. Block the actual
        # fsync subprocess after the unpublished phase is written, then SIGKILL
        # the known coordinator process; never search for or signal other PIDs.
        shim.write_text('#!/bin/sh\ncase "$*" in *phase.new*) touch "' + str(ack) + '"; sleep 10;; esac\nexit 1\n')
        shim.chmod(0o700)
        child = subprocess.Popen(self.command('s.transition("APPLYING");', False, str(shim)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while not ack.exists() and child.poll() is None and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(ack.exists())
            child.kill(); child.wait(timeout=3)
            self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARED\n')
            self.assertEqual((self.base / 'phase.new').read_bytes(), b'APPLYING\n')
            self.assertNotEqual(self.run_state(create=False).returncode, 0)
            self.assertTrue(self.ram.is_symlink())
        finally:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=3)


if __name__ == '__main__': unittest.main()
