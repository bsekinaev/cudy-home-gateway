"""Host-only private OpenWrt backup validation. Never extracts or contacts a router."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import tarfile
import zlib

MAX_ARCHIVE = 8 * 1024 * 1024
MAX_TOTAL = 16 * 1024 * 1024
MAX_FILE = 2 * 1024 * 1024
MAX_ENTRIES = 1024
MAX_PATH = 240
MAX_INVENTORY = 256 * 1024
# Exact managed enable links and owner-confirmed vtest mapping; no generic symlinks.
PERSISTED_LINKS = {
    'usr/bin/vtest': '/root/vless-auto.sh',
    'etc/rc.d/S94home-gateway-deploy-recover': '../init.d/home-gateway-deploy-recover',
    'etc/rc.d/K09home-gateway-deploy-recover': '../init.d/home-gateway-deploy-recover',
    'etc/rc.d/S95home-gateway-telegram': '../init.d/home-gateway-telegram',
    'etc/rc.d/K10home-gateway-telegram': '../init.d/home-gateway-telegram',
}


class BackupError(ValueError):
    """Fixed public reason; never include private names or contents."""


def require(condition, reason):
    if not condition:
        raise BackupError(reason)


def allowed(name):
    if not isinstance(name, str) or len(name) > MAX_PATH or not re.fullmatch(r'[A-Za-z0-9_./+-]+', name):
        return False
    if any(part in ('', '.', '..') for part in name.split('/')):
        return False
    return (name.startswith('etc/') or name.startswith('usr/lib/home-gateway/') or name.startswith('usr/libexec/home-gateway-deploy/') or
            name in ('usr/bin/gateway', 'usr/bin/home-gateway-ci-smoke', 'usr/bin/asata-udp-direct', 'usr/bin/vtest', 'root/vless-auto.sh'))


def private_read(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as file:
        before = os.fstat(file.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid in (0, os.geteuid()) and
                not before.st_mode & 0o077 and before.st_size <= limit, 'UNSAFE_PRIVATE_INPUT')
        data = file.read(limit + 1)
        after = os.fstat(file.fileno())
        require(len(data) <= limit and (before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'INPUT_CHANGED_OR_OVERSIZED')
        return data


def inventory(path):
    raw = private_read(path, MAX_INVENTORY)
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeError, RecursionError):
        raise BackupError('INVALID_INVENTORY') from None
    require(isinstance(data, list) and 0 < len(data) <= MAX_ENTRIES and
            all(allowed(name) for name in data) and len(set(data)) == len(data), 'INVALID_INVENTORY')
    return set(data)


def header_text(field):
    value, _, padding = field.partition(b'\0')
    require(not any(padding), 'INVALID_ARCHIVE_PATH')
    try:
        return value.decode('ascii')
    except UnicodeError:
        raise BackupError('INVALID_ARCHIVE_PATH') from None


def header_number(field):
    value, _, padding = field.partition(b'\0')
    require(all(byte in (0, 32) for byte in padding), 'INVALID_ARCHIVE')
    value = value.strip(b' ')
    require(all(byte in b'01234567' for byte in value), 'INVALID_ARCHIVE')
    return int(value, 8) if value else 0


def validate_physical_tar(plain):
    """Walk physical USTAR headers: tarfile hides extension and sparse records."""
    require(len(plain) % 512 == 0, 'INVALID_TAR_END')
    offset, entries = 0, 0
    while offset + 512 <= len(plain):
        header = plain[offset:offset + 512]
        if header == b'\0' * 512:
            require(offset + 1024 <= len(plain) and
                    plain[offset:offset + 1024] == b'\0' * 1024 and
                    not any(plain[offset + 1024:]), 'INVALID_TAR_END')
            return
        entries += 1
        require(entries <= MAX_ENTRIES, 'ENTRY_LIMIT')
        require(header[156:157] in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE, tarfile.SYMTYPE),
                'UNSUPPORTED_ARCHIVE_ENTRY')
        for start, end in ((100,108), (108,116), (116,124), (136,148), (148,156)):
            header_number(header[start:end])
        header_text(header[265:297])
        header_text(header[297:329])
        require(header_number(header[329:337]) == 0 and header_number(header[337:345]) == 0, 'INVALID_ARCHIVE')
        magic, version = header[257:263], header[263:265]
        require((magic == b'ustar\0' and version == b'00') or
                (magic == b'ustar ' and version == b' \0') or
                (not any(header[257:512])), 'INVALID_ARCHIVE')
        name = header_text(header[:100])
        if header[257:263] == b'ustar\0':
            prefix = header_text(header[345:500])
        else:
            require(not any(header[345:500]), 'INVALID_ARCHIVE')
            prefix = ''
        if prefix:
            name = prefix + '/' + name
        if header[156:157] == tarfile.DIRTYPE and name.endswith('/'):
            name = name[:-1]  # At most one conventional trailing separator.
        require(bool(name) and len(name) <= MAX_PATH and re.fullmatch(r'[A-Za-z0-9_./+-]+', name) and
                not name.startswith('/') and all(part not in ('', '.', '..') for part in name.split('/')),
                'INVALID_ARCHIVE_PATH')
        linkname = header_text(header[157:257])
        if header[156:157] == tarfile.SYMTYPE:
            require(PERSISTED_LINKS.get(name) == linkname, 'UNSUPPORTED_ARCHIVE_ENTRY')
        else:
            require(not linkname, 'UNSUPPORTED_ARCHIVE_ENTRY')
        # Accept ordinary octal sizes only; no GNU base-256/sparse encodings.
        size = header_number(header[124:136])
        require(not any(header[500:512]), 'NONZERO_HEADER_PADDING')
        require(size <= MAX_FILE and (header[156:157] in (tarfile.REGTYPE, tarfile.AREGTYPE) or size == 0), 'MEMBER_LIMIT')
        next_offset = offset + 512 + ((size + 511) // 512) * 512
        require(next_offset <= len(plain), 'TRUNCATED_MEMBER')
        require(not any(plain[offset + 512 + size:next_offset]), 'NONZERO_MEMBER_PADDING')
        offset = next_offset
    raise BackupError('INVALID_TAR_END')


def verify(path, expected_hash, required):
    require(isinstance(expected_hash, str) and re.fullmatch(r'[0-9a-f]{64}', expected_hash), 'INVALID_SHA256')
    require(isinstance(required, set) and required and len(required) <= MAX_ENTRIES and
            all(allowed(name) for name in required), 'INVALID_INVENTORY')
    raw = private_read(path, MAX_ARCHIVE)
    require(hashlib.sha256(raw).hexdigest() == expected_hash, 'CHECKSUM_MISMATCH')
    try:
        # Bound the decompressed stream before tar parsing, including metadata and
        # padding. Compressed archive size alone cannot bound gzip expansion.
        # zlib's gzip parser enforces reserved flags and FHCRC for each member.
        plain, remaining, members = bytearray(), raw, 0
        while remaining:
            members += 1
            require(members <= 64, 'GZIP_MEMBER_LIMIT')
            decoder = zlib.decompressobj(31)
            plain.extend(decoder.decompress(remaining, MAX_TOTAL - len(plain) + 1))
            require(len(plain) <= MAX_TOTAL, 'EXPANSION_LIMIT')
            require(decoder.eof, 'INVALID_ARCHIVE')
            remaining = decoder.unused_data
        plain = bytes(plain)
        validate_physical_tar(plain)
        seen, files, links, total = set(), set(), set(), 0
        with tarfile.open(fileobj=io.BytesIO(plain), mode='r:') as archive:
            for member in archive:
                require(len(seen) < MAX_ENTRIES, 'ENTRY_LIMIT')
                # Standard directory trailing slash may be normalized by tarfile.
                name = member.name.rstrip('/') if member.isdir() else member.name
                directory_allowed = member.isdir() and any(path.startswith(name + '/') for path in required)
                require((allowed(name) or directory_allowed) and name not in seen and
                        not name.startswith('/') and all(part not in ('', '.', '..') for part in name.split('/')),
                        'INVALID_ARCHIVE_PATH')
                require(not member.pax_headers and (member.type in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE, tarfile.SYMTYPE)) and
                        not member.mode & 0o7000, 'UNSUPPORTED_ARCHIVE_ENTRY')
                seen.add(name)
                require(0 <= member.size <= MAX_FILE and (not member.isdir() or member.size == 0), 'MEMBER_LIMIT')
                total += member.size
                require(total <= MAX_TOTAL, 'CONTENT_LIMIT')
                if member.issym():
                    require(name in required and PERSISTED_LINKS.get(name) == member.linkname and member.size == 0,
                            'UNSUPPORTED_ARCHIVE_ENTRY')
                    links.add(name)
                if member.isfile():
                    require(name not in PERSISTED_LINKS, 'UNSUPPORTED_ARCHIVE_ENTRY')
                    contents = archive.extractfile(member)
                    require(contents is not None and len(contents.read(MAX_FILE + 1)) == member.size, 'TRUNCATED_MEMBER')
                    files.add(name)
            # tarfile can stop at an early end marker and ignore a concatenated
            # second tar. Reject any nonzero bytes after its actual parsed end.
            require(not any(plain[archive.offset:]), 'TRAILING_ARCHIVE_DATA')
        require(required == files | links, 'INCOMPLETE_OWNER_INVENTORY')
    except BackupError:
        raise
    except (OSError, EOFError, tarfile.TarError, ValueError, zlib.error):
        raise BackupError('INVALID_ARCHIVE') from None
    return dict(schema_version=1, status='VERIFIED', files=len(files), links=len(links), bytes=total,
                archive_sha256=expected_hash, completeness='OWNER_INVENTORY_ONLY',
                transaction_consistent=False, restore_supported=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--inventory', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.archive, args.sha256, inventory(args.inventory))
    except (BackupError, OSError) as error:
        reason = str(error) if isinstance(error, BackupError) else 'PRIVATE_INPUT_UNAVAILABLE'
        print(json.dumps(dict(schema_version=1, status=reason)))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
