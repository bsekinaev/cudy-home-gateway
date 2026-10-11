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

    def test_exact_persisted_init_links_preserved_and_validated(self):
        self.required |= set(verify.PERSISTED_LINKS)
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:', format=tarfile.USTAR_FORMAT) as tar:
            for name in sorted(self.required):
                entry = tarfile.TarInfo(name)
                if name in verify.PERSISTED_LINKS:
                    entry.type = tarfile.SYMTYPE; entry.linkname = verify.PERSISTED_LINKS[name]
                    tar.addfile(entry)
                else:
                    entry.size = 4; tar.addfile(entry, io.BytesIO(b'data'))
        self.write(gzip.compress(output.getvalue()))
        self.assertEqual(self.check()['links'], 5)
        for name in verify.PERSISTED_LINKS:
            self.archive([(name, b'data', tarfile.REGTYPE)])
            with self.assertRaisesRegex(verify.BackupError, 'UNSUPPORTED_ARCHIVE_ENTRY'): self.check()
        # Wrong or unapproved target is rejected even for an expected path.
        self.archive([(next(iter(verify.PERSISTED_LINKS)), b'', tarfile.SYMTYPE)])
        with self.assertRaisesRegex(verify.BackupError, 'UNSUPPORTED_ARCHIVE_ENTRY'): self.check()

    def test_hidden_regular_member_padding_rejected(self):
        plain = bytearray(self.archive([('etc/config/network', b'data', tarfile.REGTYPE)]))
        plain[516] = 65
        self.write(gzip.compress(plain))
        with self.assertRaisesRegex(verify.BackupError, 'NONZERO_MEMBER_PADDING'): self.check()

    def test_raw_directory_path_multiple_trailing_separators_rejected(self):
        plain = self.archive()
        for name in ('etc//', 'etc/config///', '/etc/config/', 'etc/../config/'):
            entry = tarfile.TarInfo(name); entry.type = tarfile.DIRTYPE
            header = entry.tobuf(format=tarfile.USTAR_FORMAT)
            self.write(gzip.compress(header + plain))
            with self.assertRaisesRegex(verify.BackupError, 'INVALID_ARCHIVE_PATH'): self.check()

    def test_actual_busybox_tar_persisted_links_format(self):
        source = self.base / 'source'
        source.mkdir()
        self.required |= set(verify.PERSISTED_LINKS)
        for name in sorted(self.required):
            path = source / name; path.parent.mkdir(parents=True, exist_ok=True)
            if name in verify.PERSISTED_LINKS:
                path.symlink_to(verify.PERSISTED_LINKS[name])
            else:
                path.write_bytes(b'public-synthetic-data')
        subprocess.run([os.environ.get('HG_TEST_BUSYBOX', 'busybox'), 'tar', '-czf', str(self.path),
                        '-C', str(source), *sorted(self.required)], check=True, capture_output=True)
        self.path.chmod(0o600)
        self.digest = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.assertEqual(self.check()['links'], 5)

    def test_hidden_padding_in_approved_symlink_target_rejected(self):
        name, target = next(iter(verify.PERSISTED_LINKS.items()))
        entry = tarfile.TarInfo(name); entry.type = tarfile.SYMTYPE; entry.linkname = target
        header = bytearray(entry.tobuf(format=tarfile.USTAR_FORMAT))
        header[157 + len(target) + 1] = 65
        header[148:156] = b' ' * 8
        checksum = sum(header)
        header[148:156] = f'{checksum:06o}\0 '.encode()
        self.write(gzip.compress(bytes(header) + b'\0' * 1024))
        self.required = {name}
        with self.assertRaisesRegex(verify.BackupError, 'INVALID_ARCHIVE_PATH'): self.check()

    def test_leading_nul_size_cannot_hide_extension_header(self):
        entry = tarfile.TarInfo('etc/config/network')
        header = bytearray(entry.tobuf(format=tarfile.USTAR_FORMAT))
        header[124:136] = b'\x00' + b'00000001000'
        header[148:156] = b' ' * 8
        header[148:156] = f'{sum(header):06o}\0 '.encode()
        extension = tarfile.TarInfo('hidden-extension'); extension.type = tarfile.XHDTYPE
        following = tarfile.TarInfo('etc/config/firewall')
        plain = bytes(header) + extension.tobuf(format=tarfile.USTAR_FORMAT) + following.tobuf(format=tarfile.USTAR_FORMAT) + b'\0' * 1024
        self.required = {'etc/config/network', 'etc/config/firewall'}
        self.write(gzip.compress(plain))
        with self.assertRaisesRegex(verify.BackupError, 'INVALID_ARCHIVE'): self.check()

    def test_nonzero_physical_header_tail_rejected(self):
        plain = bytearray(self.archive([('etc/config/network', b'data', tarfile.REGTYPE)]))
        plain[500] = 65
        plain[148:156] = b' ' * 8
        plain[148:156] = f'{sum(plain[:512]):06o}\0 '.encode()
        self.write(gzip.compress(plain))
        with self.assertRaisesRegex(verify.BackupError, 'NONZERO_HEADER_PADDING'): self.check()

    def test_owner_confirmed_vtest_absolute_target_is_exact_only(self):
        self.required = {'usr/bin/vtest'}
        entry = tarfile.TarInfo('usr/bin/vtest'); entry.type = tarfile.SYMTYPE
        for target, valid in (('/root/vless-auto.sh', True), ('/root/other.sh', False), ('../../root/vless-auto.sh', False)):
            entry.linkname = target
            self.write(gzip.compress(entry.tobuf(format=tarfile.USTAR_FORMAT) + b'\0' * 1024))
            if valid:
                self.assertEqual(self.check()['links'], 1)
            else:
                with self.assertRaises(verify.BackupError): self.check()

    def test_non_ustar_magic_cannot_reinterpret_prefix_path(self):
        entry = tarfile.TarInfo('config/network')
        header = bytearray(entry.tobuf(format=tarfile.USTAR_FORMAT))
        header[257:263] = b'BADMAG'
        header[345:349] = b'etc\0'
        header[148:156] = b' ' * 8
        header[148:156] = f'{sum(header):06o}\0 '.encode()
        self.required = {'etc/config/network'}
        self.write(gzip.compress(bytes(header) + b'\0' * 1024))
        with self.assertRaisesRegex(verify.BackupError, 'INVALID_ARCHIVE'): self.check()

    def test_fixed_width_metadata_nul_padding_is_validated(self):
        template = self.archive([('etc/config/network', b'data', tarfile.REGTYPE)])
        for start, end in ((100,108), (108,116), (116,124), (136,148), (265,297), (297,329), (329,337), (337,345)):
            with self.subTest(field=(start,end)):
                plain = bytearray(template)
                plain[start:end] = b'\0' + b'7' * (end-start-1)
                plain[148:156] = b' ' * 8
                plain[148:156] = f'{sum(plain[:512]):06o}\0 '.encode()
                self.write(gzip.compress(plain))
                with self.assertRaises(verify.BackupError): self.check()
        # Checksum is validated too; there is no alternate hidden suffix form.
        plain = bytearray(template); plain[148:156] = b'\0' + b'7' * 7
        self.write(gzip.compress(plain))
        with self.assertRaises(verify.BackupError): self.check()

    def test_full_capacity_long_path_inventory_and_archive(self):
        paths = ['etc/' + 'a' * 150 + '/' + 'c' * 77 + f'{i:04d}.cfg' for i in range(verify.MAX_ENTRIES)]
        self.assertTrue(all(len(p) == verify.MAX_PATH for p in paths))
        path = self.base / 'inventory.json'
        path.write_text(json.dumps(paths)); path.chmod(0o600)
        self.assertGreater(path.stat().st_size, 65536)
        self.required = verify.inventory(path)
        self.archive([(p, b'', tarfile.REGTYPE) for p in paths])
        self.assertEqual(self.check()['files'], verify.MAX_ENTRIES)

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
