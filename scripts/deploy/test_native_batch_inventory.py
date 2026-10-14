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
        marker = self.root / '.hg-deploy-test-root'
        marker.write_bytes(b'DISPOSABLE\n'); marker.chmod(0o600)

    def run_inventory(self):
        return subprocess.run(['ucode', str(SCRIPT), '--', '--test-root', str(self.root)], capture_output=True, text=True, timeout=5)

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
        self.assertEqual([p.name for p in self.root.iterdir()], ['.hg-deploy-test-root'])

    def test_inventory_bound_refuses_without_deleting_unknown_entries(self):
        for n in range(129): (self.root / str(n)).touch()
        result = self.run_inventory()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(list(self.root.iterdir())), 130)

    def test_directory_substitution_never_enumerates_outside_original_handle(self):
        import shutil
        compiler = shutil.which('cc')
        self.assertIsNotNone(compiler)
        outside = tempfile.TemporaryDirectory(prefix='hg-inventory-outside-', dir='/tmp')
        self.addCleanup(outside.cleanup)
        external = Path(outside.name)
        (external / 'private-sentinel').write_bytes(b'NEVER_ENUMERATE')
        inside = self.root / 'inside'; inside.mkdir(mode=0o700)
        (inside / 'owned').touch()
        source = external / 'swap.c'
        source.write_text(r'''#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
static int swapped;
DIR *opendir(const char *path) {
    DIR *(*real_opendir)(const char *) = dlsym(RTLD_NEXT, "opendir");
    const char *owned = getenv("HG_SWAP_DIRECTORY");
    const char *target = getenv("HG_SWAP_TARGET");
    char resolved[4096], moved[4096];
    ssize_t n = readlink(path, resolved, sizeof(resolved)-1);
    size_t len = strlen(path);
    if (n < 0 && len > 2 && len < sizeof(moved) && !strncmp(path, "/proc/self/fd/", 14) &&
        !strcmp(path + len - 2, "/.")) {
        memcpy(moved, path, len - 2); moved[len - 2] = 0;
        n = readlink(moved, resolved, sizeof(resolved)-1);
    }
    if (n >= 0) resolved[n] = 0; else resolved[0] = 0;
    if (!swapped && owned && (!strcmp(path, owned) || !strcmp(resolved, owned) ||
        (n >= 0 && !strncmp(resolved, owned, strlen(owned)) && !strcmp(resolved + strlen(owned), "/.")))) {
        swapped = 1;
        snprintf(moved, sizeof(moved), "%s-moved", owned);
        if (rename(owned, moved) || symlink(target, owned)) _exit(99);
        int fd = open(getenv("HG_SWAP_ENTERED"), O_WRONLY|O_CREAT|O_EXCL, 0600);
        if (fd < 0) _exit(98); close(fd);
    }
    DIR *d = real_opendir(path);
    struct stat actual, outside;
    if (d && swapped && !fstat(dirfd(d), &actual) && !stat(target, &outside) &&
        actual.st_dev == outside.st_dev && actual.st_ino == outside.st_ino) {
        int fd = open(getenv("HG_SWAP_LEAK"), O_WRONLY|O_CREAT|O_EXCL, 0600);
        if (fd < 0) _exit(97); close(fd);
    }
    return d;
}
''')
        library = external / 'swap.so'
        subprocess.run([compiler, '-shared', '-fPIC', str(source), '-ldl', '-o', str(library)], check=True)
        entered, leaked = external / 'entered', external / 'leaked'
        env = dict(os.environ, LD_PRELOAD=str(library), HG_SWAP_DIRECTORY=str(inside),
                   HG_SWAP_TARGET=str(external), HG_SWAP_ENTERED=str(entered), HG_SWAP_LEAK=str(leaked))
        result = subprocess.run(['ucode', str(SCRIPT), '--', '--test-root', str(self.root)],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertTrue(entered.exists(), 'directory substitution hook must actually execute')
        self.assertNotEqual(result.returncode, 0, 'changed live tree must refuse')
        self.assertFalse(leaked.exists(), 'outside directory must never be enumerated')
        self.assertEqual(result.stdout, '')
        self.assertEqual((external / 'private-sentinel').read_bytes(), b'NEVER_ENUMERATE')
