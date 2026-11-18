"""Exercise actual archive bytes at the untrusted package boundary."""
import gzip
import hashlib
import io
import tarfile
import unittest

from archive import read_archive


def packed(entries=None, fmt=tarfile.USTAR_FORMAT):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w', format=fmt) as tar:
        for name, body, kind, mode in entries or [('manifest.json', b'{}\n', tarfile.REGTYPE, 0o600)]:
            entry = tarfile.TarInfo(name)
            entry.type, entry.mode = kind, mode
            entry.size = len(body) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                entry.linkname = 'manifest.json'
            tar.addfile(entry, io.BytesIO(body) if entry.size else None)
    return gzip.compress(data.getvalue(), mtime=0)


def read(raw):
    return read_archive(raw, hashlib.sha256(raw).hexdigest())


def changed_header(start, field):
    tar = bytearray(gzip.decompress(packed()))
    tar[start:start + len(field)] = field
    tar[148:156] = b'        '
    checksum = sum(tar[:512])
    tar[148:156] = ('%06o\0 ' % checksum).encode()
    return gzip.compress(tar, mtime=0)


class ArchiveTests(unittest.TestCase):
    def test_valid_ustar_returns_exact_files_and_modes(self):
        raw = packed([('candidate/', b'', tarfile.DIRTYPE, 0o700),
                      ('candidate/status.sh', b'echo ok\n', tarfile.REGTYPE, 0o644),
                      ('manifest.json', b'{}\n', tarfile.REGTYPE, 0o600)])
        self.assertEqual(read(raw), {'candidate/status.sh': (0o644, b'echo ok\n'),
                                     'manifest.json': (0o600, b'{}\n')})

    def test_digest_checked_before_parsing(self):
        with self.assertRaisesRegex(ValueError, 'ARCHIVE_DIGEST'):
            read_archive(b'not gzip', '0' * 64)

    def test_duplicates_and_traversal_are_rejected(self):
        for name in ('../escape', '/escape', 'a/../escape', 'a//b', './escape',
                     'a\\b', 'a\nb', 'a/' * 9 + 'b'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                read(packed([(name, b'x', tarfile.REGTYPE, 0o600)]))
        with self.assertRaisesRegex(ValueError, 'DUPLICATE'):
            read(packed([('x', b'a', tarfile.REGTYPE, 0o600),
                         ('x', b'b', tarfile.REGTYPE, 0o600)]))

    def test_links_devices_and_extended_headers_are_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE,
                     tarfile.BLKTYPE, tarfile.FIFOTYPE, tarfile.XHDTYPE,
                     tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                read(packed([('x', b'', kind, 0o600)]))
        with self.assertRaises(ValueError):
            read(packed(fmt=tarfile.GNU_FORMAT))

    def test_modes_and_directory_closure_are_rejected(self):
        for mode in (0o777, 0o4755, 0o666, 0):
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                read(packed([('x', b'a', tarfile.REGTYPE, mode)]))
        for entries in ([('a/x', b'x', tarfile.REGTYPE, 0o600)],
                        [('unused/', b'', tarfile.DIRTYPE, 0o700)],
                        [('a', b'x', tarfile.REGTYPE, 0o600),
                         ('a/x', b'x', tarfile.REGTYPE, 0o600)]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                read(packed(entries))

    def test_untrusted_header_metadata_is_rejected(self):
        for start, field in ((108, b'0000001\0'), (116, b'0000001\0'),
                             (265, b'root'), (297, b'root'), (329, b'0000001\0'),
                             (500, b'x'), (100, b'\x80'), (136, b'\x80'),
                             (0, b'x\0hidden'), (263, b'01')):
            with self.subTest(start=start, field=field), self.assertRaises(ValueError):
                read(changed_header(start, field))

    def test_exact_file_and_manifest_limits_are_accepted(self):
        files = read(packed([('x', b'x' * 262144, tarfile.REGTYPE, 0o644),
                             ('manifest.json', b' ' * 65536, tarfile.REGTYPE, 0o600)]))
        self.assertEqual(len(files['x'][1]), 262144)
        self.assertEqual(len(files['manifest.json'][1]), 65536)

    def test_corruption_and_truncation_rejected(self):
        good = packed()
        for raw in (good[:-1], good + b'junk', good + good):
            with self.subTest(length=len(raw)), self.assertRaises(ValueError):
                read(raw)
        tar = bytearray(gzip.decompress(good))
        tar[0] ^= 1
        with self.assertRaisesRegex(ValueError, 'CHECKSUM'):
            read(gzip.compress(tar, mtime=0))
        with self.assertRaises(ValueError):
            read(gzip.compress(gzip.decompress(good)[:1024], mtime=0))

    def test_nonzero_padding_and_post_terminator_data_rejected(self):
        tar = bytearray(gzip.decompress(packed()))
        for position in (515, 2048):
            changed = tar.copy()
            changed[position] = 1
            with self.subTest(position=position), self.assertRaises(ValueError):
                read(gzip.compress(changed, mtime=0))

    def test_size_and_count_limits(self):
        with self.assertRaises(ValueError):
            read(packed([('x', b'x' * 262145, tarfile.REGTYPE, 0o600)]))
        with self.assertRaises(ValueError):
            read(packed([('manifest.json', b'x' * 65537, tarfile.REGTYPE, 0o600)]))
        with self.assertRaises(ValueError):
            read(packed([(str(i), b'x', tarfile.REGTYPE, 0o600) for i in range(257)]))
        with self.assertRaises(ValueError):
            read(gzip.compress(b'\0' * (8 * 1024 * 1024 + 512), mtime=0))
        with self.assertRaises(ValueError):
            read(b'x' * (8 * 1024 * 1024 + 1))


if __name__ == '__main__':
    unittest.main()
