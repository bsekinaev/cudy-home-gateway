"""Host-only private OpenWrt backup validation. Never extracts or contacts a router."""
import argparse
import gzip
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


class BackupError(ValueError):
    """Fixed public reason; never include private names or contents."""


def require(condition, reason):
    if not condition:
        raise BackupError(reason)


def allowed(name):
    if not isinstance(name, str) or len(name) > 240 or not re.fullmatch(r'[A-Za-z0-9_./+-]+', name):
        return False
    if any(part in ('', '.', '..') for part in name.split('/')):
        return False
    return (name.startswith('etc/') or name.startswith('usr/lib/home-gateway/') or
            name in ('usr/bin/gateway', 'usr/bin/asata-udp-direct', 'root/vless-auto.sh'))


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
    try:
        data = json.loads(private_read(path, 65536))
    except (json.JSONDecodeError, UnicodeError):
        raise BackupError('INVALID_INVENTORY') from None
    require(isinstance(data, list) and 0 < len(data) <= MAX_ENTRIES and
            all(allowed(name) for name in data) and len(set(data)) == len(data), 'INVALID_INVENTORY')
    return set(data)


def verify(path, expected_hash, required):
    require(isinstance(expected_hash, str) and re.fullmatch(r'[0-9a-f]{64}', expected_hash), 'INVALID_SHA256')
    require(isinstance(required, set) and required and len(required) <= MAX_ENTRIES and
            all(allowed(name) for name in required), 'INVALID_INVENTORY')
    raw = private_read(path, MAX_ARCHIVE)
    require(hashlib.sha256(raw).hexdigest() == expected_hash, 'CHECKSUM_MISMATCH')
    try:
        # Bound the decompressed stream before tar parsing, including metadata and
        # padding. Compressed archive size alone cannot bound gzip expansion.
        with gzip.GzipFile(fileobj=io.BytesIO(raw)) as stream:
            plain = stream.read(MAX_TOTAL + 1)
        require(len(plain) <= MAX_TOTAL, 'EXPANSION_LIMIT')
        require(len(plain) % 512 == 0 and len(plain) >= 1024 and plain[-1024:] == b'\0' * 1024,
                'INVALID_TAR_END')
        seen, files, total = set(), set(), 0
        with tarfile.open(fileobj=io.BytesIO(plain), mode='r:') as archive:
            for member in archive:
                require(len(seen) < MAX_ENTRIES, 'ENTRY_LIMIT')
                # Standard directory trailing slash may be normalized by tarfile.
                name = member.name.rstrip('/') if member.isdir() else member.name
                require(allowed(name) and name not in seen, 'INVALID_ARCHIVE_PATH')
                require(not member.pax_headers and (member.isfile() or member.isdir()) and
                        not member.mode & 0o7000, 'UNSUPPORTED_ARCHIVE_ENTRY')
                seen.add(name)
                require(0 <= member.size <= MAX_FILE and (not member.isdir() or member.size == 0), 'MEMBER_LIMIT')
                total += member.size
                require(total <= MAX_TOTAL, 'CONTENT_LIMIT')
                if member.isfile():
                    contents = archive.extractfile(member)
                    require(contents is not None and len(contents.read(MAX_FILE + 1)) == member.size, 'TRUNCATED_MEMBER')
                    files.add(name)
            # tarfile can stop at an early end marker and ignore a concatenated
            # second tar. Reject any nonzero bytes after its actual parsed end.
            require(not any(plain[archive.offset:]), 'TRAILING_ARCHIVE_DATA')
        require(required <= files, 'INCOMPLETE_OWNER_INVENTORY')
    except BackupError:
        raise
    except (OSError, EOFError, tarfile.TarError, ValueError, zlib.error):
        raise BackupError('INVALID_ARCHIVE') from None
    return dict(schema_version=1, status='VERIFIED', files=len(files), bytes=total,
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
