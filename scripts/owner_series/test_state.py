"""Durable journal I/O with actual native ucode and kernel locks."""
import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).with_name('state.uc')


@unittest.skipUnless(shutil.which('ucode'), 'native ucode required')
class StateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        marker = self.root / '.hg-owner-series-test-root'
        marker.write_text('HG_OWNER_SERIES_TEST_ROOT_V1\n')
        marker.chmod(0o600)
        for name in ('etc', 'tmp'):
            (self.root / name).mkdir(mode=0o700)

    def run_code(self, source):
        self.assertTrue(MODULE.exists(), 'durable series state module missing')
        code = 'import { open_io } from ' + json.dumps(str(MODULE)) + ';let io=open_io(ARGV[0]);' + source
        return subprocess.run(['ucode', '-e', code, '--', str(self.root)],
                              capture_output=True, text=True, timeout=20)

    def test_exclusive_atomic_write_preserves_foreign_pending_file(self):
        result = self.run_code('io.mkdir("/etc/owned");io.exclusive("/etc/owned/value","old\\n",0600);'
                               'io.atomic("/etc/owned/value","new\\n",0600);')
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.root / 'etc/owned/value'
        self.assertEqual(path.read_bytes(), b'new\n')
        pending = path.with_name('value.new')
        pending.write_bytes(b'foreign')
        pending.chmod(0o600)
        result = self.run_code('io.atomic("/etc/owned/value","next\\n",0600);')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_bytes(), b'new\n')
        self.assertEqual(pending.read_bytes(), b'foreign')

    def test_existing_kernel_lock_is_held_and_released(self):
        import fcntl
        lock = self.root / 'tmp/serial'
        lock.touch(mode=0o600)
        with lock.open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_code('let guard=io.lock("/tmp/serial",false);')
            self.assertNotEqual(result.returncode, 0)
        result = self.run_code('let guard=io.lock("/tmp/serial",false);guard.close();')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_new_lock_is_exclusive_and_does_not_adopt_nonempty_file(self):
        result = self.run_code('let guard=io.lock("/tmp/new-serial",true);guard.close();')
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.root / 'tmp/new-serial'
        self.assertEqual(path.read_bytes(), b'')
        self.assertEqual(path.stat().st_mode & 0o7777, 0o600)
        path.write_bytes(b'foreign')
        result = self.run_code('let guard=io.lock("/tmp/new-serial",true);')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_bytes(), b'foreign')

    def test_copy_uses_known_mode_and_refuses_symlink_destination(self):
        result = self.run_code('io.mkdir("/etc/owned");io.exclusive("/etc/owned/source","bytes",0644);'
                               'io.copy("/etc/owned/source","/etc/owned/copy",0644);'
                               'print(io.hash("/etc/owned/copy",0644,262144));')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, hashlib.sha256(b'bytes').hexdigest())
        source = self.root / 'etc/owned/source'
        target = self.root / 'etc/owned/copy'
        self.assertEqual(target.read_bytes(), b'bytes')
        self.assertEqual(target.stat().st_mode & 0o7777, 0o644)
        target.unlink()
        target.symlink_to(source)
        result = self.run_code('io.copy("/etc/owned/source","/etc/owned/copy",0644);')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(source.read_bytes(), b'bytes')

    def test_sealed_operation_is_never_mutated(self):
        operation = '/etc/home-gateway-owner-series/generations/tx.' + 'a' * 32
        result = self.run_code('io.mkdir(' + json.dumps(operation) + ');'
            'io.exclusive(' + json.dumps(operation + '/phase') + ',"COMMITTED\\n",0600);'
            'io.exclusive(' + json.dumps(operation + '/sealed') + ',"HG_OWNER_SERIES_SEALED_V1\\n",0600);'
            'io.atomic(' + json.dumps(operation + '/phase') + ',"ROLLED_BACK\\n",0600);')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SEALED', result.stderr)
        self.assertEqual((self.root / operation.lstrip('/') / 'phase').read_bytes(), b'COMMITTED\n')

    def test_parent_symlink_and_cross_root_paths_are_rejected(self):
        (self.root / 'etc/escape').symlink_to('/tmp')
        for path in ('/etc/escape/payload', '/etc/../tmp/payload'):
            result = self.run_code('io.exclusive(' + json.dumps(path) + ',"no",0600);')
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
