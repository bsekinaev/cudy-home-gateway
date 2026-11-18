"""Bounded, non-extracting USTAR reader for untrusted owner packages.

Deliberately does not use tarfile's permissive format/extension handling.
The caller must also validate the manifest's exact file inventory and hashes.
"""
import hashlib
from pathlib import PurePosixPath
import re
import zlib

MAX_ARCHIVE = 8 * 1024 * 1024
MAX_FILE = 262144
MAX_MANIFEST = 65536
MAX_ENTRIES = 256


def _octal(field):
    if not re.fullmatch(rb'[0-7]+[\0 ]*', field):
        raise ValueError('ARCHIVE_OCTAL')
    return int(field.rstrip(b'\0 '), 8)


def _text(field):
    text, separator, padding = field.partition(b'\0')
    if separator and any(padding):
        raise ValueError('ARCHIVE_TEXT_PADDING')
    try:
        return text.decode('ascii')
    except UnicodeDecodeError as error:
        raise ValueError('ARCHIVE_PATH_ENCODING') from error


def read_archive(raw, expected_sha256):
    """Return only ordinary file bytes after checking the entire gzip/USTAR.

    No filesystem operations, link resolution or external commands are used.
    expected_sha256 is the independently supplied package pin, not its filename.
    """
    if len(raw) > MAX_ARCHIVE:
        raise ValueError('ARCHIVE_COMPRESSED_SIZE')
    if (not isinstance(expected_sha256, str) or
            not re.fullmatch(r'[0-9a-f]{64}', expected_sha256) or
            hashlib.sha256(raw).hexdigest() != expected_sha256):
        raise ValueError('ARCHIVE_DIGEST')
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        data = decoder.decompress(raw, MAX_ARCHIVE + 1)
    except zlib.error as error:
        raise ValueError('ARCHIVE_GZIP') from error
    if (len(data) > MAX_ARCHIVE or decoder.unconsumed_tail or
            not decoder.eof or decoder.unused_data):
        raise ValueError('ARCHIVE_GZIP_SIZE_OR_TRAILING')
    if len(data) % 512:
        raise ValueError('ARCHIVE_ALIGNMENT')
    files, directories, seen = {}, set(), set()
    offset = 0
    terminated = False
    while offset < len(data):
        header = data[offset:offset + 512]
        if not any(header):
            if len(data) - offset < 1024 or any(data[offset:]):
                raise ValueError('ARCHIVE_TERMINATOR')
            terminated = True
            break
        if len(seen) >= MAX_ENTRIES:
            raise ValueError('ARCHIVE_ENTRY_COUNT')
        if _octal(header[148:156]) != sum(header[:148]) + 256 + sum(header[156:]):
            raise ValueError('ARCHIVE_CHECKSUM')
        if (header[257:265] != b'ustar\x0000' or any(header[500:]) or
                any(header[157:257]) or any(header[265:329]) or
                _octal(header[108:116]) or _octal(header[116:124]) or
                any(header[329:345])):
            raise ValueError('ARCHIVE_METADATA')
        _octal(header[136:148])  # mtime must also be ordinary octal
        name, prefix = _text(header[:100]), _text(header[345:500])
        path = prefix + '/' + name if prefix else name
        kind = header[156:157]
        if kind not in (b'0', b'5'):
            raise ValueError('ARCHIVE_TYPE')
        directory = kind == b'5'
        if directory and path.endswith('/'):
            path = path[:-1]
        if (not re.fullmatch(r'[A-Za-z0-9._/-]+', path) or
                any(part in ('', '.', '..') for part in path.split('/')) or
                len(path.split('/')) > 8 or len(path) > 255):
            raise ValueError('ARCHIVE_PATH')
        if path in seen:
            raise ValueError('ARCHIVE_DUPLICATE')
        seen.add(path)
        mode, size = _octal(header[100:108]), _octal(header[124:136])
        limit = MAX_MANIFEST if path == 'manifest.json' else MAX_FILE
        if (directory and (size or mode != 0o700) or
                not directory and (mode not in (0o600, 0o644, 0o700, 0o755) or size > limit)):
            raise ValueError('ARCHIVE_MODE_OR_SIZE')
        offset += 512
        end = offset + size
        padded_end = offset + ((size + 511) // 512) * 512
        if padded_end > len(data) or any(data[end:padded_end]):
            raise ValueError('ARCHIVE_BODY_OR_PADDING')
        if directory:
            directories.add(path)
        else:
            files[path] = (mode, data[offset:end])
        offset = padded_end
    if not terminated or not files:
        raise ValueError('ARCHIVE_INCOMPLETE')
    parents = {str(parent) for path in files for parent in PurePosixPath(path).parents
               if str(parent) != '.'}
    if parents != directories or parents.intersection(files):
        raise ValueError('ARCHIVE_DIRECTORY_CLOSURE')
    return files
