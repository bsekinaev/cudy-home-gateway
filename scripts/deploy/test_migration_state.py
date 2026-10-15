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

    def test_failed_first_chmod_leaves_private_reusable_kernel_lock(self):
        # Real open(2)/chmod(2), with only chmod fault-injected by the loader.
        # A permissive caller umask must never expose or strand a 0644 lock.
        compiler = shutil.which('cc')
        self.assertIsNotNone(compiler, 'C compiler required for syscall fault injection')
        source = self.root / 'deny-chmod.c'
        source.write_text(r'''#define _GNU_SOURCE
#include <sys/stat.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
int chmod(const char *path, mode_t mode) {
    const char *deny = getenv("HG_DENY_CHMOD");
    if (deny && !strcmp(path, deny)) { errno = EIO; return -1; }
    int (*real_chmod)(const char *, mode_t) = dlsym(RTLD_NEXT, "chmod");
    return real_chmod(path, mode);
}
''')
        library = self.root / 'deny-chmod.so'
        subprocess.run([compiler, '-shared', '-fPIC', str(source), '-ldl', '-o', str(library)], check=True)
        lock = self.root / 'etc/home-gateway-migration.lock'
        env = dict(os.environ, LD_PRELOAD=str(library), HG_DENY_CHMOD=str(lock))
        result = subprocess.run(self.command(), env=env, umask=0, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        self.assertEqual(lock.read_bytes(), b'')
        self.assertFalse(self.base.exists())
        self.success('s.fence();')
        self.assertTrue(self.ram.is_symlink())

    def test_closed_guard_and_wrong_root_cannot_mutate_state(self):
        self.success('s.fence();')
        for op in ('s.transition("PREPARED");', 's.fence();', 's.release();', 's.assert_root(ARGV[0]);'):
            result = self.run_state('s.close(); ' + op, False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.base / 'phase').read_bytes(), b'PREPARING\n')
            self.assertTrue(self.ram.is_symlink())
        self.assertNotEqual(self.run_state('s.assert_root("/not-the-held-root");', False).returncode, 0)
        self.success('s.assert_root(ARGV[0]);', False)

    def test_fence_initialization_fsync_failure_retries_without_adoption(self):
        self.success()
        shim = self.root / 'fence-fsync-failure'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/fence.initializing."*) exit 1;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        self.assertNotEqual(self.run_state('s.fence();', False, str(shim)).returncode, 0)
        self.assertFalse((self.base / 'fence').exists())
        self.assertFalse(self.ram.is_symlink())
        staged = list(self.base.glob('fence.initializing.*'))
        self.assertEqual(len(staged), 1)
        (staged[0] / 'foreign').write_bytes(b'KEEP')
        self.success('s.fence();', False)
        self.assertEqual((staged[0] / 'foreign').read_bytes(), b'KEEP')
        self.assertEqual((self.base / 'fence/marker').read_bytes(), (self.base / 'marker').read_bytes())
        self.assertTrue(self.ram.is_symlink())

    def test_sigkill_before_fence_publication_allows_fresh_fence(self):
        self.success()
        ready = self.root / 'fence-write-entered'
        shim = self.root / 'fence-fsync-block'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/fence.initializing."*) touch "' + str(ready) + '"; sleep 10;; esac\nexec "' + self.bb + '" "$@"\n')
        shim.chmod(0o700)
        child = subprocess.Popen(self.command('s.fence();', False, str(shim)),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(ready.exists())
            child.kill(); child.wait(timeout=3)
            self.assertFalse((self.base / 'fence').exists())
            staged = list(self.base.glob('fence.initializing.*'))
            self.assertEqual(len(staged), 1)
            self.success('s.fence();', False)
            self.assertTrue(staged[0].is_dir())
            self.assertTrue(self.ram.is_symlink())
        finally:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=3)

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
        admission.write_bytes(('HG_MIGRATION_ADMITTED_V2 ROLLED_BACK ' + (self.base / 'marker').read_text().split()[1] + ' ' + str((self.root / 'etc/home-gateway-migration.lock').stat().st_ino) + '\n').encode()); admission.chmod(0o600)
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
        p.write_text('HG_MIGRATION_ADMITTED_V2 COMMITTED ' + (self.base / 'marker').read_text().split()[1] + ' ' + str((self.root / 'etc/home-gateway-migration.lock').stat().st_ino) + '\n'); p.chmod(0o600)
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


    def boot_fence(self):
        script='import { restore_boot_fence } from '+json.dumps(str(MODULE))+'; print(restore_boot_fence(ARGV[0],ARGV[1]));'
        return subprocess.run(['ucode','-e',script,'--',str(self.root),self.bb],capture_output=True,text=True,timeout=10)

    def test_early_boot_without_migration_creates_no_state(self):
        r=self.boot_fence();self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout,'NO_MIGRATION');self.assertFalse(self.base.exists());self.assertFalse(self.ram.exists())
        self.assertFalse((self.root/'etc/home-gateway-migration.lock').exists())

    def test_early_boot_rebuilds_ram_fence_before_refusing_pending_or_bad_phase(self):
        self.success('s.fence(); s.transition("PREPARED");')
        identity=(self.root/'etc/home-gateway-migration.lock').stat().st_ino
        self.ram.unlink();r=self.boot_fence();self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout,'PREPARED');self.assertTrue(self.ram.is_symlink())
        pending=self.base/'phase.new';pending.write_bytes(b'APPL');pending.chmod(0o600)
        self.ram.unlink();self.assertNotEqual(self.boot_fence().returncode,0)
        self.assertTrue(self.ram.is_symlink());self.assertEqual(pending.read_bytes(),b'APPL')
        pending.unlink();(self.base/'phase').write_bytes(b'FOREIGN\n')
        self.ram.unlink();self.assertNotEqual(self.boot_fence().returncode,0)
        self.assertTrue(self.ram.is_symlink());self.assertEqual((self.base/'phase').read_bytes(),b'FOREIGN\n')
        self.assertEqual(identity,(self.root/'etc/home-gateway-migration.lock').stat().st_ino)

    def test_boot_terminal_requires_bound_admission_before_releasing_fence(self):
        self.success('s.fence(); s.transition("PREPARED"); s.transition("RESTORING"); s.transition("ROLLED_BACK");')
        self.ram.unlink();self.assertNotEqual(self.boot_fence().returncode,0);self.assertTrue(self.ram.is_symlink())
        nonce=(self.base/'marker').read_text().split()[1]
        inode=(self.root/'etc/home-gateway-migration.lock').stat().st_ino
        p=self.base/'admission';p.write_text(f'HG_MIGRATION_ADMITTED_V2 ROLLED_BACK {nonce} {inode}\n');p.chmod(0o600)
        r=self.boot_fence();self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout,'ROLLED_BACK');self.assertFalse(self.ram.is_symlink())

    def run_boot_init(self):
        import shlex
        source=MODULE.with_name('migration-boot.init').read_text()
        source=source.replace('/etc/home-gateway-migration',str(self.base)).replace('/tmp/home-gateway-deploy.lock',str(self.ram))
        source=source.replace('/usr/bin/ucode',shutil.which('ucode')).replace('/usr/libexec/home-gateway-deploy/migration-state.uc',str(MODULE))
        source=source.replace('restore_boot_fence("",null)','restore_boot_fence('+json.dumps(str(self.root))+','+json.dumps(self.bb)+')')
        return subprocess.run(shlex.split(os.environ.get('HG_TEST_SHELL','sh'))+['-c',source+'\nlogger() { :; }; start\n'],capture_output=True,text=True,timeout=10)

    def test_boot_init_unknown_marker_blocks_legacy_without_stopping_boot(self):
        self.success('s.fence();');self.ram.unlink();(self.base/'marker').write_bytes(b'FOREIGN\n')
        r=self.run_boot_init();self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(self.ram.is_dir());self.assertFalse(self.ram.is_symlink())
        self.assertEqual(self.ram.stat().st_mode&0o777,0o700);self.assertEqual(list(self.ram.iterdir()),[])
        self.assertEqual((self.base/'marker').read_bytes(),b'FOREIGN\n')

    def test_boot_init_never_replaces_foreign_ram_lock(self):
        self.success('s.fence();');self.ram.unlink();(self.base/'marker').write_bytes(b'FOREIGN\n')
        foreign=self.root/'foreign';foreign.write_bytes(b'KEEP');self.ram.symlink_to(foreign)
        r=self.run_boot_init();self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(self.ram.readlink(),foreign);self.assertEqual(foreign.read_bytes(),b'KEEP')


if __name__ == '__main__': unittest.main()
