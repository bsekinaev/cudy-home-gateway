"""Read-only diagnostics against real files, symlinks and kernel flock."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('native-batch-inventory.uc')

class NativeBatchInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hg-native-batch.', dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.root.chmod(0o700)

    def run_inventory(self):
        return subprocess.run(['ucode', str(SCRIPT), str(self.root)], capture_output=True, text=True, timeout=5)

    def test_reads_metadata_and_exact_kernel_holder_without_following_symlink(self):
        crash = self.root / 'crash/etc'
        crash.mkdir(parents=True)
        guard = crash / 'home-gateway-migration.lock'
        guard.touch(mode=0o600)
        (self.root / 'foreign').symlink_to('/etc')
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
        with guard.open('rb') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_inventory()
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual(data['mutations'], 0)
            self.assertRegex(data['kernel_guard_holders'][0]['kernel_pid'], r'^[1-9][0-9]*$')
            self.assertEqual(data['kernel_guard_holders'][0]['guard'], './crash/etc/home-gateway-migration.lock')
            self.assertEqual([p['path'] for p in data['entries'] if p['type'] == 'link'], ['./foreign'])
        self.assertEqual(before, sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*')))
        self.assertEqual(guard.read_bytes(), b'')

    def test_untrusted_root_permissions_refuse_without_changes(self):
        self.root.chmod(0o755)
        result = self.run_inventory()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_inventory_bound_refuses_without_deleting_unknown_entries(self):
        for n in range(129): (self.root / str(n)).touch()
        result = self.run_inventory()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(list(self.root.iterdir())), 129)
