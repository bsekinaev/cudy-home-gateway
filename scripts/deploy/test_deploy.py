"""Integration tests of the actual shell receiver against an isolated filesystem."""
import base64
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from transport import PATHS

ENGINE = Path(__file__).with_name('engine.sh').resolve()
COMMIT = 'a' * 40


@unittest.skipUnless(os.name == 'posix', 'Router integration runs on Linux CI')
class DeployTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / '.hg-deploy-test-root').touch()
        self.base = self.root / 'etc/home-gateway-deploy'
        self.base.mkdir(parents=True)
        (self.root / 'tmp').mkdir()
        self.bin = self.root / 'test-bin'
        self.bin.mkdir()
        if os.environ.get('HG_TEST_BUSYBOX'):
            executable = shutil.which(os.environ['HG_TEST_BUSYBOX'])
            if not executable:
                raise RuntimeError('Requested BusyBox is unavailable')
            for applet in ('base64', 'sha256sum', 'stat', 'timeout', 'head', 'mktemp',
                           'cmp', 'cp', 'mv', 'df', 'du', 'awk', 'cat', 'cut', 'grep',
                           'mkdir', 'rm', 'chmod', 'wc', 'sh', 'id'):
                (self.bin / applet).symlink_to(executable)
        self.env = dict(os.environ, HG_TEST_BIN=str(self.bin))
        self.put(self.bin / 'ucode', '#!/bin/sh\nexit 0\n', 0o755)
        # Do not sync the whole host filesystem for every test file.
        self.put(self.bin / 'sync', '#!/bin/sh\nexit 0\n', 0o755)
        self.put(self.bin / 'sleep', '#!/bin/sh\nexit 0\n', 0o755)
        self.running = self.root / 'running'
        service = f'''#!/bin/sh
case "$1" in
 running) test -f '{self.running}';;
 stop) rm -f '{self.running}';;
 start) touch '{self.running}';;
esac
'''
        self.old = {}
        for name in PATHS:
            data = service if name == PATHS[0] else '#!/bin/sh\n# old\nexit 0\n'
            mode = 0o755 if name in PATHS[:3] else 0o644
            self.put(self.root / name, data, mode)
            self.old[name] = (self.root / name).read_bytes()
        self.running.touch()
        self.new = dict(self.old)
        self.new['usr/lib/home-gateway/common.sh'] += b'# new\n'

    def put(self, path, data, mode):
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink():
            path.unlink()
        path.write_bytes(data.encode() if isinstance(data, str) else data)
        path.chmod(mode)

    def wire(self, data=None):
        data = data or self.new
        lines = [f'HGDEPLOY1 {COMMIT}\n'.encode()]
        for name in PATHS:
            content = data[name]
            mode = '0755' if name in PATHS[:3] else '0644'
            lines += [f'{mode} {len(content)} {hashlib.sha256(content).hexdigest()}\n'.encode(),
                      base64.b64encode(content) + b'\n']
        return b''.join(lines) + b'END\n'

    def run_engine(self, op, wire=None):
        cmd = os.environ.get('HG_TEST_SHELL', '/bin/sh').split() + [str(ENGINE), '--test-root', str(self.root), op]
        if op in ('plan', 'apply'):
            wire = self.wire() if wire is None else wire
            cmd += [COMMIT, hashlib.sha256(wire).hexdigest()]
        return subprocess.run(cmd, input=wire, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env=self.env, timeout=30)

    def assert_old(self):
        for name, data in self.old.items():
            self.assertEqual((self.root / name).read_bytes(), data, name)
        self.assertTrue(self.running.exists())

    def test_plan_never_changes_runtime(self):
        result = self.run_engine('plan')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(b'CHANGED=1', result.stdout)
        self.assert_old()
        self.assertFalse(list(self.base.iterdir()))

    def test_apply_noop_and_manual_rollback(self):
        result = self.run_engine('apply')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(b'DEPLOY_RESULT=PASS', result.stdout)
        self.assertEqual((self.root / PATHS[4]).read_bytes(), self.new[PATHS[4]])
        self.assertTrue(self.running.exists())
        result = self.run_engine('apply')
        self.assertIn(b'NO_CHANGE', result.stdout)
        result = self.run_engine('rollback')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_old()
        self.assertNotEqual(self.run_engine('rollback').returncode, 0)

    def test_failed_postcheck_restores_all_files_and_modes(self):
        self.new['usr/bin/gateway'] = b'#!/bin/sh\nexit 1\n'
        (self.root / PATHS[4]).chmod(0o600)
        result = self.run_engine('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'DEPLOY_RESULT=ROLLED_BACK', result.stdout)
        self.assert_old()
        self.assertEqual((self.root / PATHS[4]).stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.base / 'active').exists())

    def test_preflight_failure_does_not_write(self):
        self.put(self.root / 'usr/bin/gateway', '#!/bin/sh\nexit 1\n', 0o755)
        result = self.run_engine('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / PATHS[4]).read_bytes(), self.old[PATHS[4]])
        self.assertFalse((self.base / 'active').exists())

    def test_stopped_service_stays_stopped(self):
        self.running.unlink()
        self.assertEqual(self.run_engine('apply').returncode, 0)
        self.assertFalse(self.running.exists())
        self.assertEqual(self.run_engine('rollback').returncode, 0)
        self.assertFalse(self.running.exists())

    def test_symlink_target_and_parent_rejected(self):
        target = self.root / PATHS[4]
        target.unlink()
        target.symlink_to(self.root / PATHS[5])
        self.assertNotEqual(self.run_engine('apply').returncode, 0)
        target.unlink()
        self.put(target, self.old[PATHS[4]], 0o644)
        library = self.root / 'usr/lib/home-gateway'
        library.rename(self.root / 'moved')
        library.symlink_to(self.root / 'moved', target_is_directory=True)
        self.assertNotEqual(self.run_engine('apply').returncode, 0)

    def test_transfer_truncation_and_extra_data(self):
        for wire in (self.wire()[:-6], self.wire() + b'extra\n', self.wire() + b'extra'):
            result = self.run_engine('apply', wire)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assert_old()

    def test_file_hash_mismatch(self):
        wire = self.wire().replace(hashlib.sha256(self.old[PATHS[0]]).hexdigest().encode(), b'0' * 64, 1)
        self.assertNotEqual(self.run_engine('apply', wire).returncode, 0)
        self.assert_old()

    def test_invalid_mode_and_command(self):
        self.assertNotEqual(self.run_engine('apply', self.wire().replace(b'0755 ', b'0777 ', 1)).returncode, 0)
        self.assertNotEqual(self.run_engine('sh').returncode, 0)
        self.assert_old()

    def test_busy_lock_rejected(self):
        lock = self.root / 'tmp/home-gateway-deploy.lock'
        lock.mkdir()
        (lock / 'pid').write_text(str(os.getpid()))
        self.assertNotEqual(self.run_engine('apply').returncode, 0)
        self.assertTrue(lock.exists())
        self.assert_old()

    def test_sigkill_then_recover(self):
        # Kill the receiver AFTER its first real target rename, leaving a mixed tree.
        self.new[PATHS[0]] += b'# new init\n'
        self.put(self.bin / 'mv', f'''#!/bin/sh
/bin/mv "$@" || exit 1
case "$*" in *'{self.root}/{PATHS[0]}'*) kill -KILL "$PPID";; esac
''', 0o755)
        result = self.run_engine('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.base / 'active').exists(), result.stdout)
        (self.bin / 'mv').unlink()
        result = self.run_engine('recover')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(b'RECOVERY_OK', result.stdout)
        self.assert_old()

    def test_reboot_recovery_without_runtime_lock(self):
        self.put(self.bin / 'mv', f"#!/bin/sh\n/bin/mv \"$@\" || exit 1\ncase \"$*\" in *'{self.root}/{PATHS[1]}'*) kill -KILL \"$PPID\";; esac\n", 0o755)
        self.assertNotEqual(self.run_engine('apply').returncode, 0)
        self.assertTrue((self.base / 'active').exists())
        (self.bin / 'mv').unlink()
        shutil.rmtree(self.root / 'tmp/home-gateway-deploy.lock')
        self.assertEqual(self.run_engine('recover').returncode, 0)
        self.assert_old()
        self.assertIn(b'RECOVERY_NOT_NEEDED', self.run_engine('recover').stdout)

    def test_target_write_failure_rolls_back(self):
        marker = self.root / 'failed-once'
        self.put(self.bin / 'mv', f"#!/bin/sh\ncase \"$*\" in *'{self.root}/{PATHS[1]}'*) if [ ! -f '{marker}' ]; then touch '{marker}'; exit 1; fi;; esac\nexec /bin/mv \"$@\"\n", 0o755)
        result = self.run_engine('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'ROLLED_BACK', result.stdout)
        self.assert_old()

    def test_mode_only_update(self):
        self.new = dict(self.old)
        (self.root / PATHS[4]).chmod(0o600)
        result = self.run_engine('apply')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.root / PATHS[4]).stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.run_engine('rollback').returncode, 0)
        self.assertEqual((self.root / PATHS[4]).stat().st_mode & 0o777, 0o600)

    def test_corrupt_backup_blocks_restore(self):
        self.assertEqual(self.run_engine('apply').returncode, 0)
        tx = self.base / (self.base / 'latest').read_text().strip()
        (tx / 'backup' / PATHS[4]).write_bytes(b'corrupted')
        self.assertNotEqual(self.run_engine('rollback').returncode, 0)
        self.assertTrue((self.base / 'active').exists())
        self.assertEqual((self.root / PATHS[4]).read_bytes(), self.new[PATHS[4]])

    def test_hup_during_rename_finishes(self):
        self.put(self.bin / 'mv', f"#!/bin/sh\n/bin/mv \"$@\" || exit 1\ncase \"$*\" in *'{self.root}/{PATHS[1]}'*) kill -HUP \"$PPID\";; esac\n", 0o755)
        result = self.run_engine('apply')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(b'DEPLOY_RESULT=PASS', result.stdout)

    def test_manual_rollback_refuses_drift(self):
        self.assertEqual(self.run_engine('apply').returncode, 0)
        (self.root / PATHS[4]).write_bytes(b'drift')
        self.assertNotEqual(self.run_engine('rollback').returncode, 0)
        self.assertEqual((self.root / PATHS[4]).read_bytes(), b'drift')

    def test_service_start_failure_restores_previous_service(self):
        self.new[PATHS[0]] = self.old[PATHS[0]].replace(b'start) touch', b'start) exit 1; touch')
        result = self.run_engine('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'ROLLED_BACK', result.stdout)
        self.assert_old()

    def test_manual_rollback_refuses_mode_drift(self):
        self.assertEqual(self.run_engine('apply').returncode, 0)
        (self.root / PATHS[4]).chmod(0o600)
        self.assertNotEqual(self.run_engine('rollback').returncode, 0)
        self.assertEqual((self.root / PATHS[4]).stat().st_mode & 0o777, 0o600)

    def test_disk_space_failure(self):
        self.put(self.bin / 'df', '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nroot 1000 999 1 99%% /\\n"\n', 0o755)
        result = self.run_engine('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'insufficient persistent space', result.stdout)
        self.assert_old()

    def test_status(self):
        self.assertIn(b'NO_DEPLOYMENTS', self.run_engine('status').stdout)
        self.assertEqual(self.run_engine('apply').returncode, 0)
        self.assertIn(b'COMMITTED', self.run_engine('status').stdout)


if __name__ == '__main__':
    unittest.main()
