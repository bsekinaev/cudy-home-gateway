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

    def run_gate(self):
        command = os.environ.get('HG_TEST_SHELL', '/bin/sh').split()
        return subprocess.run(command + [str(SCRIPT), '--test-root', str(self.root)],
                              capture_output=True, timeout=5).returncode

    def state(self, phase='COMMITTED', receipt=True):
        self.base.mkdir(mode=0o700, exist_ok=True)
        (self.base / 'phase').write_text(phase + '\n')
        (self.base / 'phase').chmod(0o600)
        if receipt:
            (self.base / 'admission').write_text('HG_MIGRATION_ADMITTED_V1 ' + phase + '\n')
            (self.base / 'admission').chmod(0o600)

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

    def test_noncanonical_terminal_bytes_refused(self):
        self.state()
        for raw in (b'COMMITTED', b'COMMITTED\n\n', b'COMMITTED\x00\n'):
            (self.base / 'phase').write_bytes(raw)
            self.assertNotEqual(self.run_gate(), 0)
        self.state()
        (self.base / 'admission').write_bytes(b'HG_MIGRATION_ADMITTED_V1 COMMITTED')
        self.assertNotEqual(self.run_gate(), 0)


if __name__ == '__main__': unittest.main()
