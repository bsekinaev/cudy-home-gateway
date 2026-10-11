"""Actual gzip/tar/hash/private filesystem tests with public synthetic content."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.path = self.base / 'backup.tar.gz'
        self.required = {'etc/config/network', 'etc/home-gateway/state/notifications.jsonl'}

    def archive(self, entries=None):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:', format=tarfile.USTAR_FORMAT) as tar:
            for name, data, kind in entries or [(p, b'private-synthetic-value\n', tarfile.REGTYPE) for p in sorted(self.required)]:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.mode = 0o600
                entry.size = len(data) if kind == tarfile.REGTYPE else 0
                if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE): entry.linkname = '../shadow'
                tar.addfile(entry, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
        self.write(gzip.compress(output.getvalue()))
        return output.getvalue()

    def write(self, data):
        self.path.write_bytes(data)
        self.path.chmod(0o600)
        self.digest = hashlib.sha256(data).hexdigest()

    def check(self):
        return verify.verify(self.path, self.digest, self.required)

    def test_valid_archive_is_read_only_and_never_claims_full_restore(self):
        self.archive()
        before = self.path.read_bytes()
        result = self.check()
        self.assertEqual(result['status'], 'VERIFIED')
        self.assertEqual(result['files'], 2)
        self.assertEqual(result['completeness'], 'OWNER_INVENTORY_ONLY')
        self.assertFalse(result['transaction_consistent'])
        self.assertFalse(result['restore_supported'])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(set(p.name for p in self.base.iterdir()), {'backup.tar.gz'})
        self.assertNotIn('synthetic', json.dumps(result))
        self.assertNotIn('notifications.jsonl', json.dumps(result))

    def test_unapproved_extra_file_rejected(self):
        entries = [(p, b'data', tarfile.REGTYPE) for p in sorted(self.required)]
        self.archive(entries + [('etc/config/unapproved', b'extra', tarfile.REGTYPE)])
        with self.assertRaisesRegex(verify.BackupError, 'INCOMPLETE_OWNER_INVENTORY'):
            self.check()

    def test_sparse_and_hidden_extension_headers_rejected(self):
        for kind in (tarfile.GNUTYPE_SPARSE, tarfile.XHDTYPE, tarfile.XGLTYPE,
                     tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
            plain = self.archive()
            hidden = tarfile.TarInfo('etc/extension')
            hidden.type = kind
            hidden.size = 0
            header = hidden.tobuf(format=tarfile.USTAR_FORMAT)
            self.write(gzip.compress(header + plain))
            with self.assertRaisesRegex(verify.BackupError, 'UNSUPPORTED_ARCHIVE_ENTRY'):
                self.check()

    def test_zero_file_contents_never_substitute_for_end_headers(self):
        self.required = {'etc/config/network'}
        plain = self.archive([('etc/config/network', b'\0' * 1024, tarfile.REGTYPE)])
        self.write(gzip.compress(plain[:1536]))
        with self.assertRaisesRegex(verify.BackupError, 'INVALID_TAR_END'):
            self.check()
        self.write(gzip.compress(plain[:2048]))
        with self.assertRaisesRegex(verify.BackupError, 'INVALID_TAR_END'):
            self.check()
        self.write(gzip.compress(plain[:2560]))
        self.assertEqual(self.check()['status'], 'VERIFIED')

    def test_corrupt_inventory_integer_and_depth_have_fixed_cli_error(self):
        self.archive()
        path = self.base / 'inventory.json'
        for data in ('[' + '1' * 5000 + ']', '[' * 1500 + '0' + ']' * 1500):
            path.write_text(data)
            path.chmod(0o600)
            result = subprocess.run([sys.executable, str(Path(verify.__file__)), str(self.path),
                                     '--sha256', self.digest, '--inventory', str(path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)['status'], 'INVALID_INVENTORY')
            self.assertEqual(result.stderr, '')

    def test_persisted_deployment_runtime_inventory_is_supported(self):
        self.required = {'usr/bin/home-gateway-ci-smoke',
                         'usr/libexec/home-gateway-deploy/engine.sh',
                         'usr/libexec/home-gateway-deploy/wrapper.sh'}
        entries = [(p, b'data', tarfile.REGTYPE) for p in sorted(self.required)]
        entries += [(p, b'', tarfile.DIRTYPE) for p in ('usr', 'usr/bin', 'usr/libexec', 'usr/libexec/home-gateway-deploy')]
        self.archive(entries)
        self.assertEqual(self.check()['files'], 3)
        path = self.base / 'inventory.json'
        path.write_text(json.dumps(sorted(self.required)))
        path.chmod(0o600)
        self.assertEqual(verify.inventory(path), self.required)

    def test_checksum_and_invalid_hash_rejected_before_parsing(self):
        self.archive()
        for value, reason in [('0' * 64, 'CHECKSUM_MISMATCH'), ('invalid', 'INVALID_SHA256')]:
            with self.assertRaisesRegex(verify.BackupError, reason):
                verify.verify(self.path, value, self.required)

    def test_private_permissions_symlink_and_nonfile_rejected(self):
        self.archive()
        self.path.chmod(0o644)
        with self.assertRaisesRegex(verify.BackupError, 'UNSAFE_PRIVATE_INPUT'): self.check()
        self.path.unlink()
        self.path.symlink_to(self.base / 'absent')
        with self.assertRaises(OSError): self.check()
        self.path.unlink()
        self.path.mkdir()
        with self.assertRaises(OSError): self.check()

    def test_path_traversal_absolute_duplicate_and_foreign_path(self):
        for name in ('../etc/shadow', '/etc/shadow', 'etc/../shadow', 'etc//shadow', 'etc/./shadow', 'tmp/private', 'etc/name with space'):
            self.archive([(name, b'data', tarfile.REGTYPE)])
            with self.assertRaisesRegex(verify.BackupError, 'INVALID_ARCHIVE_PATH'): self.check()
        self.archive([('etc/config/network', b'one', tarfile.REGTYPE), ('etc/config/network', b'two', tarfile.REGTYPE)])
        with self.assertRaisesRegex(verify.BackupError, 'INVALID_ARCHIVE_PATH'): self.check()

    def test_links_devices_fifo_never_accepted(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE, tarfile.FIFOTYPE):
            self.archive([('etc/config/network', b'', kind)])
            with self.assertRaisesRegex(verify.BackupError, 'UNSUPPORTED_ARCHIVE_ENTRY'): self.check()

    def test_missing_inventory_and_directory_not_file(self):
        self.archive([('etc/config/network', b'network', tarfile.REGTYPE)])
        with self.assertRaisesRegex(verify.BackupError, 'INCOMPLETE_OWNER_INVENTORY'): self.check()
        self.archive([('etc/config/network', b'', tarfile.DIRTYPE)])
        with self.assertRaisesRegex(verify.BackupError, 'INCOMPLETE_OWNER_INVENTORY'): self.check()

    def test_member_archive_expansion_and_entry_limits(self):
        self.archive([('etc/config/network', b'x' * (verify.MAX_FILE + 1), tarfile.REGTYPE)])
        with self.assertRaisesRegex(verify.BackupError, 'MEMBER_LIMIT'): self.check()
        self.write(gzip.compress(b'\0' * (verify.MAX_TOTAL + 1)))
        with self.assertRaisesRegex(verify.BackupError, 'EXPANSION_LIMIT'): self.check()
        self.write(b'x' * (verify.MAX_ARCHIVE + 1))
        with self.assertRaisesRegex(verify.BackupError, 'UNSAFE_PRIVATE_INPUT'): self.check()
        self.archive([(f'etc/file{i}', b'', tarfile.REGTYPE) for i in range(verify.MAX_ENTRIES + 1)])
        with self.assertRaisesRegex(verify.BackupError, 'ENTRY_LIMIT'): self.check()

    def test_corrupt_truncated_gzip_tar_and_concatenated_tar(self):
        plain = self.archive()
        for raw in (b'invalid', self.path.read_bytes()[:-4], gzip.compress(plain[:512]), gzip.compress(plain + plain)):
            self.write(raw)
            with self.assertRaises(verify.BackupError): self.check()

    def test_fifo_input_does_not_block_before_type_validation(self):
        os.mkfifo(self.path, 0o600)
        with self.assertRaisesRegex(verify.BackupError, 'UNSAFE_PRIVATE_INPUT'):
            self.check_with_hash('0' * 64)

    def check_with_hash(self, digest):
        return verify.verify(self.path, digest, self.required)

    def test_invalid_deflate_never_escapes_fixed_error_boundary(self):
        self.write(bytes.fromhex('1f8b08000000000000ff') + b'\xff' * 40)
        with self.assertRaisesRegex(verify.BackupError, 'INVALID_ARCHIVE'): self.check()

    def test_inventory_is_private_bounded_unique_allowlisted(self):
        path = self.base / 'inventory.json'
        path.write_text(json.dumps(sorted(self.required)))
        path.chmod(0o600)
        self.assertEqual(verify.inventory(path), self.required)
        for data in ([], ['../shadow'], ['etc/config/network'] * 2, {}, ['etc/config/network', 1]):
            path.write_text(json.dumps(data))
            with self.assertRaisesRegex(verify.BackupError, 'INVALID_INVENTORY'): verify.inventory(path)

    def test_cli_errors_never_echo_names_contents_or_traceback(self):
        self.archive([('etc/private-sensitive-filename', b'private-synthetic-value', tarfile.SYMTYPE)])
        inventory = self.base / 'inventory.json'
        inventory.write_text(json.dumps(sorted(self.required)))
        inventory.chmod(0o600)
        result = subprocess.run([sys.executable, str(Path(verify.__file__)), str(self.path), '--sha256', self.digest,
                                 '--inventory', str(inventory)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['status'], 'UNSUPPORTED_ARCHIVE_ENTRY')
        for word in ('private-sensitive-filename', 'private-synthetic-value', 'Traceback'):
            self.assertNotIn(word, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
