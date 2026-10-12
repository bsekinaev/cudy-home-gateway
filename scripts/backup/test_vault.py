"""Actual private filesystem, SQLite transactions, rotation and crash recovery."""
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify import BackupError
import vault


class VaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.path = self.base / 'vault'
        self.archive = self.base / 'backup.tar.gz'
        self.inventory = self.base / 'inventory.json'
        self.inventory.write_text(json.dumps(['etc/config/network']))
        self.inventory.chmod(0o600)
        self.make_archive()

    def make_archive(self, value=b'synthetic-private-value'):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:', format=tarfile.USTAR_FORMAT) as tar:
            member = tarfile.TarInfo('etc/config/network'); member.size = len(value); member.mode = 0o600
            tar.addfile(member, io.BytesIO(value))
        self.archive.write_bytes(gzip.compress(data.getvalue()))
        self.archive.chmod(0o600)
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def fail_cleanup_after_new_commit(self, store, error):
        real = store.garbage_collect
        def failure():
            if any(sha == self.digest for _,sha,_,_ in store.records()): raise error
            return real()
        return patch.object(store, 'garbage_collect', side_effect=failure)

    def store(self):
        with vault.Vault(self.path, create=True) as store:
            return store.import_archive(self.archive, self.digest, self.inventory)

    def test_full_capacity_inventory_survives_private_copy_and_show(self):
        paths = ['etc/' + 'a' * 150 + '/' + 'c' * 77 + f'{i:04d}.cfg' for i in range(1024)]
        self.inventory.write_text(json.dumps(paths)); self.inventory.chmod(0o600)
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:', format=tarfile.USTAR_FORMAT) as tar:
            for path in paths:
                tar.addfile(tarfile.TarInfo(path))
        self.archive.write_bytes(gzip.compress(output.getvalue())); self.archive.chmod(0o600)
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.assertEqual(self.store()['copies'], 1)
        manifest = next(self.path.glob('*.inventory.json'))
        self.assertGreater(manifest.stat().st_size, 65536)
        with vault.Vault(self.path, readonly=True) as store:
            self.assertEqual(store.show()['copies'], 1)

    def test_catalog_rollback_preserves_unreferenced_committed_pair(self):
        self.store()
        catalog = (self.path / 'vault.sqlite').read_bytes()
        self.make_archive(b'second-committed'); self.store()
        pairs = {p.name: p.read_bytes() for p in self.path.iterdir() if vault.COPY.fullmatch(p.name)}
        (self.path / 'vault.sqlite').write_bytes(catalog)
        with vault.Vault(self.path) as store:
            self.assertEqual(store.garbage_collect(), 0)
            self.assertEqual(store.show()['status'], 'QUARANTINED')
            self.assertEqual(store.show()['unreferenced_preserved'], 2)
        self.assertEqual(pairs, {p.name: p.read_bytes() for p in self.path.iterdir() if vault.COPY.fullmatch(p.name)})
        self.make_archive(b'next-import'); self.store()
        for name,data in pairs.items(): self.assertEqual((self.path / name).read_bytes(), data)

    def test_empty_catalog_initialization_can_retry_without_losing_files(self):
        self.path.mkdir(mode=0o700)
        database = self.path / 'vault.sqlite'
        database.touch(mode=0o600)
        self.assertEqual(self.store()['status'], 'STORED')
        with vault.Vault(self.path, readonly=True) as store:
            self.assertEqual(store.show()['copies'], 1)

    def test_empty_catalog_with_archive_is_never_reinitialized(self):
        self.path.mkdir(mode=0o700)
        (self.path / 'vault.sqlite').touch(mode=0o600)
        unknown = self.path / ('0' * 32 + '.tar.gz')
        unknown.write_bytes(self.archive.read_bytes()); unknown.chmod(0o600)
        with self.assertRaisesRegex(BackupError, 'CATALOG_MISSING_RECOVERY_REQUIRED'):
            self.store()
        self.assertEqual(unknown.read_bytes(), self.archive.read_bytes())

    def test_post_commit_directory_sync_failure_reports_committed_and_retry_deduplicates(self):
        for i in range(5): self.make_archive(str(i).encode()); self.store()
        old_files = {p.name: p.read_bytes() for p in self.path.glob('*.tar.gz')}
        self.make_archive(b'postcommit-sync-fault')
        with vault.Vault(self.path) as store:
            real = vault.os.fsync
            def fail_after_commit(fd):
                if fd == store.fd and any(r[1] == self.digest for r in store.records()):
                    raise OSError('injected directory EIO after SQL commit')
                return real(fd)
            with patch.object(vault.os, 'fsync', side_effect=fail_after_commit):
                result = store.import_archive(self.archive, self.digest, self.inventory)
                accepted_before_retry = store.records()
                blocked_retry = store.import_archive(self.archive, self.digest, self.inventory)
                self.assertEqual(blocked_retry['status'], 'COMMITTED_DURABILITY_UNKNOWN')
                self.assertEqual(store.records(), accepted_before_retry)
            self.assertEqual(result['status'], 'COMMITTED_DURABILITY_UNKNOWN')
            self.assertTrue(result['committed']); self.assertTrue(result['durability_error'])
            for name, data in old_files.items():
                self.assertEqual((self.path / name).read_bytes(), data)
            accepted = store.records()
            retry = store.import_archive(self.archive, self.digest, self.inventory)
            self.assertEqual(retry['status'], 'ALREADY_STORED')
            self.assertEqual(store.records(), accepted)

    def test_readonly_show_uses_noncreating_readonly_lock(self):
        self.store(); real = vault.os.open
        observed = []
        def opened(path, flags, *args, **kwargs):
            if path == 'vault.lock':
                observed.append(flags)
                self.assertEqual(flags & os.O_ACCMODE, os.O_RDONLY)
                self.assertFalse(flags & os.O_CREAT)
            return real(path, flags, *args, **kwargs)
        with patch.object(vault.os, 'open', side_effect=opened):
            with vault.Vault(self.path, readonly=True) as store:
                self.assertEqual(store.show()['copies'], 1)
        self.assertEqual(len(observed), 1)
        (self.path / 'vault.lock').unlink()
        with self.assertRaises(FileNotFoundError):
            vault.Vault(self.path, readonly=True)
        self.assertFalse((self.path / 'vault.lock').exists())
    def test_empty_corrupt_catalog_never_deletes_committed_pair(self):
        self.store()
        pairs = {p.name: p.read_bytes() for p in self.path.iterdir() if vault.COPY.fullmatch(p.name)}
        with vault.Vault(self.path) as store:
            store.db.execute('BEGIN IMMEDIATE')
            store.db.execute('DELETE FROM copies'); store.db.execute('DELETE FROM audit')
            store.db.execute('COMMIT')
            self.assertEqual(store.garbage_collect(), 0)
            self.assertEqual(store.show()['unreferenced_preserved'], 2)
        self.assertEqual(pairs, {p.name: p.read_bytes() for p in self.path.iterdir() if vault.COPY.fullmatch(p.name)})

    def test_corrupt_retired_copy_blocks_all_deletion(self):
        self.store()
        first = next(self.path.glob('*.tar.gz'))
        for i in range(4): self.make_archive(str(i).encode()); self.store()
        self.make_archive(b'sixth')
        with vault.Vault(self.path) as store:
            with self.fail_cleanup_after_new_commit(store, SystemExit('post-commit crash')):
                with self.assertRaises(SystemExit): store.import_archive(self.archive, self.digest, self.inventory)
        first.write_bytes(b'corrupted-retired-copy')
        before = {p.name: p.read_bytes() for p in self.path.iterdir() if vault.COPY.fullmatch(p.name)}
        with vault.Vault(self.path) as store:
            with self.assertRaisesRegex(BackupError, 'RETIRED_CHECKSUM_MISMATCH'): store.garbage_collect()
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.path.iterdir() if vault.COPY.fullmatch(p.name)})

    def test_new_copy_readback_fault_preserves_old_index_before_rotation(self):
        for i in range(5): self.make_archive(str(i).encode()); self.store()
        self.make_archive(b'new-readback-fault-copy')
        with vault.Vault(self.path) as store:
            before = store.records()
            original = {name: (self.path / name).read_bytes() for name in
                        [identifier + suffix for identifier, *_ in before for suffix in ('.tar.gz','.inventory.json')]}
            real = store.write_copy
            for suffix, reason in (('.tar.gz', 'CHECKSUM_MISMATCH'), ('.inventory.json', 'INVENTORY_CHECKSUM_MISMATCH')):
                def corrupt(name, data):
                    real(name, data)
                    if name.endswith(suffix): (self.path / name).write_bytes(b'silent-storage-fault')
                with patch.object(store, 'write_copy', corrupt):
                    with self.assertRaisesRegex(BackupError, reason):
                        store.import_archive(self.archive, self.digest, self.inventory)
                self.assertEqual(store.records(), before)
                self.assertEqual(store.show()['copies'], 5)
                for name,data in original.items(): self.assertEqual((self.path / name).read_bytes(), data)
            self.assertEqual(store.show()['unreferenced_preserved'], 4)

    def test_missing_retired_archive_preserves_inventory_metadata(self):
        self.store(); first = next(self.path.glob('*.tar.gz'))
        for i in range(4): self.make_archive(str(i).encode()); self.store()
        self.make_archive(b'new-retired-pair')
        with vault.Vault(self.path) as store:
            with self.fail_cleanup_after_new_commit(store, SystemExit('post-commit crash')):
                with self.assertRaises(SystemExit): store.import_archive(self.archive, self.digest, self.inventory)
        manifest = self.path / (first.name.removesuffix('.tar.gz') + '.inventory.json')
        saved = manifest.read_bytes(); first.unlink()
        with vault.Vault(self.path) as store:
            self.assertEqual(store.garbage_collect(), 0)
            self.assertEqual(store.show()['status'], 'QUARANTINED')
        self.assertEqual(manifest.read_bytes(), saved)

    def test_committed_gc_failure_and_exact_retries_never_rotate_again(self):
        for i in range(5): self.make_archive(str(i).encode()); self.store()
        self.make_archive(b'new-commit')
        with vault.Vault(self.path) as store:
            with self.fail_cleanup_after_new_commit(store, OSError('synthetic cleanup failure')):
                result = store.import_archive(self.archive, self.digest, self.inventory)
                self.assertEqual(result['status'], 'STORED_CLEANUP_PENDING')
                self.assertTrue(result['cleanup_pending'])
                committed = store.records()
                events = store.show()['audit_events']
                for _ in range(3):
                    retry = store.import_archive(self.archive, self.digest, self.inventory)
                    self.assertEqual(retry['status'], 'ALREADY_STORED_CLEANUP_PENDING')
                    self.assertEqual(store.records(), committed)
                    self.assertEqual(store.show()['audit_events'], events)
            self.assertEqual(store.import_archive(self.archive, self.digest, self.inventory)['status'], 'ALREADY_STORED')
            self.assertEqual(store.records(), committed)

    def test_blocked_cleanup_preserves_receipt_and_stops_further_rotations(self):
        for i in range(5): self.make_archive(str(i).encode()); self.store()
        first = next(self.path.glob('*.tar.gz'))
        self.make_archive(b'new-retirement')
        with vault.Vault(self.path) as store:
            with self.fail_cleanup_after_new_commit(store, SystemExit('commit')):
                with self.assertRaises(SystemExit): store.import_archive(self.archive,self.digest,self.inventory)
        # Find the actual retired ID rather than relying on directory ordering.
        with vault.Vault(self.path) as store:
            identifier = store.db.execute("SELECT id FROM audit WHERE event='ROTATED'").fetchone()[0]
            first = self.path / (identifier + '.tar.gz'); original = first.read_bytes()
            first.write_bytes(b'corrupt-retirement')
            before = store.records(); events = store.db.execute('SELECT count(*) FROM audit').fetchone()[0]
            with self.assertRaisesRegex(BackupError,'RETIRED_CHECKSUM_MISMATCH'): store.show()
            for i in range(105):
                self.make_archive(('blocked-' + str(i)).encode())
                with self.assertRaisesRegex(BackupError,'RETIRED_CHECKSUM_MISMATCH'):
                    store.import_archive(self.archive,self.digest,self.inventory)
            self.assertEqual(store.records(), before)
            self.assertEqual(store.db.execute('SELECT count(*) FROM audit').fetchone()[0], events)
            first.write_bytes(original)
            self.assertEqual(store.show()['status'],'CLEANUP_PENDING')
            self.assertEqual(store.garbage_collect(),2)
            self.assertEqual(store.show()['status'],'VERIFIED')

    def test_directory_creation_syncs_each_parent_entry(self):
        real_mkdir, real_sync = vault.os.mkdir, vault.os.fsync
        events = []
        def mkdir(path,*args,**kwargs):
            result=real_mkdir(path,*args,**kwargs)
            if 'dir_fd' in kwargs: events.append(('mkdir',os.fstat(kwargs['dir_fd']).st_ino))
            return result
        def sync(fd):
            result=real_sync(fd);events.append(('sync',os.fstat(fd).st_ino));return result
        self.path = self.base / 'nested' / 'private' / 'vault'
        with patch.object(vault.os,'mkdir',mkdir),patch.object(vault.os,'fsync',sync): self.store()
        made = [(i,inode) for i,(kind,inode) in enumerate(events) if kind=='mkdir']
        self.assertEqual(len(made),3)
        for i,inode in made: self.assertEqual(events[i+1],('sync',inode))

    def test_post_commit_active_corruption_reports_integrity_not_cleanup(self):
        for i in range(5): self.make_archive(str(i).encode());self.store()
        old_files=set(self.path.glob('*.tar.gz'))
        self.make_archive(b'new-integrity-copy')
        with vault.Vault(self.path) as store:
            real=store.commit_copy
            def corrupt(identifier,digest,manifest_digest):
                real(identifier,digest,manifest_digest)
                (self.path/(identifier+'.tar.gz')).write_bytes(b'post-commit-corruption')
            with patch.object(store,'commit_copy',corrupt):
                result=store.import_archive(self.archive,self.digest,self.inventory)
            self.assertEqual(result['status'],'COMMITTED_INTEGRITY_ERROR')
            self.assertTrue(result['integrity_error'])
            self.assertTrue(result['committed'])
            self.assertFalse(result['cleanup_pending'])
            with self.assertRaises(BackupError):store.show()
        self.assertTrue(all(path.exists() for path in old_files))

    def test_partial_cleanup_exact_retry_keeps_pending_status(self):
        for i in range(5):self.make_archive(str(i).encode());self.store()
        self.make_archive(b'new-partial-cleanup')
        with vault.Vault(self.path) as store:
            with self.fail_cleanup_after_new_commit(store,SystemExit('commit')):
                with self.assertRaises(SystemExit):store.import_archive(self.archive,self.digest,self.inventory)
            identifier=store.db.execute("SELECT id FROM audit WHERE event='ROTATED'").fetchone()[0]
            (self.path/(identifier+'.inventory.json')).unlink()
            before=store.records()
            result=store.import_archive(self.archive,self.digest,self.inventory)
            self.assertEqual(result['status'],'ALREADY_STORED_CLEANUP_PENDING')
            self.assertTrue(result['cleanup_pending'])
            self.assertEqual(store.records(),before)
            self.assertTrue(store.show()['cleanup_pending'])

    def test_verified_copy_private_files_and_fixed_summary(self):
        result = self.store()
        self.assertEqual(result['status'], 'STORED')
        self.assertEqual(result['copies'], 1)
        self.assertFalse(result['restore_supported'])
        self.assertFalse(result['transaction_consistent'])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o700)
        for file in self.path.iterdir(): self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        with vault.Vault(self.path, readonly=True) as store:
            self.assertEqual(store.show()['copies'], 1)
            self.assertEqual(store.show()['audit_events'], 1)
        self.assertNotIn('synthetic', json.dumps(result))

    def test_rotation_keeps_last_five_and_audits_retirement(self):
        hashes = []
        for i in range(7):
            self.make_archive(str(i).encode()); hashes.append(self.digest); self.store()
        with vault.Vault(self.path) as store:
            records = store.records()
            self.assertEqual([r[1] for r in records], hashes[-5:])
            self.assertEqual(store.show()['audit_events'], 9)
        self.assertEqual(len(list(self.path.glob('*.tar.gz'))), 5)
        self.assertEqual(len(list(self.path.glob('*.inventory.json'))), 5)

    def test_rejected_archive_does_not_enter_catalog(self):
        with vault.Vault(self.path, create=True) as store:
            with self.assertRaisesRegex(BackupError, 'CHECKSUM_MISMATCH'):
                store.import_archive(self.archive, '0' * 64, self.inventory)
            self.assertEqual(store.records(), [])
        self.assertFalse(list(self.path.glob('*.tar.gz')))

    def test_parallel_store_is_rejected_by_kernel_lock(self):
        with vault.Vault(self.path, create=True):
            with self.assertRaisesRegex(BackupError, 'VAULT_BUSY'):
                vault.Vault(self.path)
            result = subprocess.run([sys.executable, str(Path(vault.__file__)), 'show', '--vault', str(self.path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)['status'], 'VAULT_BUSY')
            self.assertEqual(result.stderr, '')

    def test_crash_before_catalog_commit_preserves_previous_copy(self):
        self.store()
        self.make_archive(b'new-before-commit')
        with vault.Vault(self.path) as store:
            old = store.records()
            with patch.object(store, 'commit_copy', side_effect=SystemExit):
                with self.assertRaises(SystemExit): store.import_archive(self.archive, self.digest, self.inventory)
        with vault.Vault(self.path) as store:
            self.assertEqual(store.records(), old)
            self.assertEqual(store.garbage_collect(), 0)
            self.assertEqual(store.show()['copies'], 1)
            self.assertEqual(store.show()['unreferenced_preserved'], 2)
            self.assertEqual(store.show()['status'], 'QUARANTINED')

    def test_crash_after_commit_retains_new_index_until_gc(self):
        for i in range(5): self.make_archive(str(i).encode()); self.store()
        self.make_archive(b'newest')
        with vault.Vault(self.path) as store:
            with self.fail_cleanup_after_new_commit(store, SystemExit('post-commit crash')):
                with self.assertRaises(SystemExit): store.import_archive(self.archive, self.digest, self.inventory)
        self.assertEqual(len(list(self.path.glob('*.tar.gz'))), 6)
        with vault.Vault(self.path) as store:
            self.assertEqual(store.records()[-1][1], self.digest)
            self.assertEqual(store.show()['copies'], 5)
            self.assertEqual(store.garbage_collect(), 2)
        self.assertEqual(len(list(self.path.glob('*.tar.gz'))), 5)

    def test_actual_sigkill_during_sql_transaction_rolls_back(self):
        self.store()
        code = '''import sys,time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from vault import Vault
with Vault(Path(sys.argv[2])) as v:
 v.db.execute('BEGIN IMMEDIATE')
 v.db.execute('DELETE FROM copies')
 v.db.execute('DELETE FROM audit')
 print('READY',flush=True)
 time.sleep(30)
'''
        child = subprocess.Popen([sys.executable, '-c', code, str(Path(vault.__file__).parent), str(self.path)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'READY')
            child.kill(); child.communicate(timeout=3)
        finally:
            if child.poll() is None: child.kill(); child.communicate(timeout=3)
        with vault.Vault(self.path) as store:
            self.assertEqual(store.show()['copies'], 1)
            self.assertEqual(store.show()['audit_events'], 1)

    def test_existing_corrupt_copy_blocks_rotation_and_gc(self):
        self.store()
        copy = next(self.path.glob('*.tar.gz'))
        copy.write_bytes(b'corrupt')
        before = {p.name: p.read_bytes() for p in self.path.iterdir() if p.is_file()}
        with vault.Vault(self.path) as store:
            with self.assertRaisesRegex(BackupError, 'CHECKSUM_MISMATCH'): store.garbage_collect()
            with self.assertRaisesRegex(BackupError, 'CHECKSUM_MISMATCH'):
                store.import_archive(self.archive, self.digest, self.inventory)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.path.iterdir() if p.is_file()})

    def test_inventory_checksum_corruption_is_detected(self):
        self.store()
        next(self.path.glob('*.inventory.json')).write_text('["etc/config/unapproved"]')
        with vault.Vault(self.path) as store:
            with self.assertRaisesRegex(BackupError, 'INVENTORY_CHECKSUM_MISMATCH'): store.show()

    def test_corrupt_catalog_fixed_cli_error_without_traceback(self):
        self.store()
        (self.path / 'vault.sqlite').write_bytes(b'corrupt')
        result = subprocess.run([sys.executable, str(Path(vault.__file__)), 'show', '--vault', str(self.path)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['status'], 'VAULT_UNAVAILABLE')
        self.assertEqual(result.stderr, '')
        self.assertNotIn(str(self.path), result.stdout)

    def test_shared_path_and_symlink_ancestor_do_not_change_mode(self):
        self.path.mkdir(mode=0o755)
        with self.assertRaisesRegex(BackupError, 'UNSAFE_VAULT_DIRECTORY'): vault.Vault(self.path, create=True)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o755)
        self.path.rmdir(); self.path.symlink_to(self.base)
        with self.assertRaises(OSError): vault.Vault(self.path, create=True)
        self.assertFalse((self.base / 'vault.sqlite').exists())
        for path in ('/', '/tmp'):
            with self.assertRaisesRegex(BackupError, 'UNSAFE_VAULT_DIRECTORY'): vault.directory(Path(path), True)

    def test_unexpected_or_symlink_entries_stop_before_delete(self):
        self.store()
        foreign = self.path / 'foreign'
        foreign.write_text('private'); foreign.chmod(0o600)
        with self.assertRaisesRegex(BackupError, 'UNEXPECTED_VAULT_ENTRY'): vault.Vault(self.path)
        self.assertTrue(foreign.exists())
        foreign.unlink()
        link = self.path / ('b' * 32 + '.tar.gz'); link.symlink_to(self.archive)
        with self.assertRaisesRegex(BackupError, 'UNSAFE_VAULT_FILE'): vault.Vault(self.path)
        self.assertTrue(link.is_symlink())

    def test_catalog_path_injection_rejected_before_gc(self):
        self.store()
        with vault.Vault(self.path) as store:
            store.db.execute('UPDATE copies SET id=?', ('../escape',))
            with self.assertRaisesRegex(BackupError, 'INVALID_CATALOG'): store.garbage_collect()
        self.assertEqual(len(list(self.path.glob('*.tar.gz'))), 1)

    def test_missing_catalog_never_reinitializes_over_existing_archives(self):
        self.store()
        (self.path / 'vault.sqlite').unlink()
        with self.assertRaisesRegex(BackupError, 'CATALOG_MISSING_RECOVERY_REQUIRED'):
            vault.Vault(self.path, create=True)
        self.assertFalse((self.path / 'vault.sqlite').exists())
        self.assertEqual(len(list(self.path.glob('*.tar.gz'))), 1)

    def test_deleted_index_or_receipt_pauses_before_garbage_collection(self):
        self.store()
        with vault.Vault(self.path) as store:
            store.db.execute('DELETE FROM copies')
            with self.assertRaisesRegex(BackupError, 'INVALID_CATALOG'): store.garbage_collect()
        self.assertEqual(len(list(self.path.glob('*.tar.gz'))), 1)

    def test_audit_retention_is_bounded(self):
        for i in range(105):
            self.make_archive(str(i).encode())
            self.store()
        with vault.Vault(self.path) as store:
            self.assertEqual(store.show()['audit_events'], 200)
            self.assertEqual(store.show()['copies'], 5)


if __name__ == '__main__': unittest.main()
