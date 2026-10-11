"""Host-only private verified-archive vault. Never collects/restores router files."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time
import uuid

from verify import MAX_INVENTORY, BackupError, inventory, private_read, require, verify

ID = re.compile(r'[0-9a-f]{32}')
DIGEST = re.compile(r'[0-9a-f]{64}')
COPY = re.compile(r'([0-9a-f]{32})\.(tar\.gz|inventory\.json)')
MAX_DB = 2 * 1024 * 1024


def directory(path, create=False):
    """Validate each opened ancestor before creating a private child; no chmod."""
    raw = str(path)
    require(raw.startswith('/') and raw not in ('/', '/tmp') and
            re.fullmatch(r'/[A-Za-z0-9_./-]+', raw) is not None and
            all(p not in ('', '.', '..') for p in raw.split('/')[1:]), 'UNSAFE_VAULT_DIRECTORY')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        require(st.st_uid == 0 and not st.st_mode & 0o022, 'UNSAFE_VAULT_DIRECTORY')
        for part in raw.split('/')[1:]:
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            except FileNotFoundError:
                require(create, 'VAULT_MISSING')
                os.mkdir(part, 0o700, dir_fd=fd)
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            st = os.fstat(child)
            try:
                require(st.st_uid in (0, os.geteuid()) and
                        (not st.st_mode & 0o022 or st.st_mode & stat.S_ISVTX), 'UNSAFE_VAULT_DIRECTORY')
            except BaseException:
                os.close(child)
                raise
            os.close(fd)
            fd = child
        st = os.fstat(fd)
        require(st.st_uid == os.geteuid() and stat.S_IMODE(st.st_mode) == 0o700, 'UNSAFE_VAULT_DIRECTORY')
        return fd
    except BaseException:
        os.close(fd)
        raise


class Vault:
    def __init__(self, path, create=False, readonly=False):
        self.path = Path(path)
        self.fd = directory(self.path, create)
        self.lock = self.db = None
        try:
            self.validate_entries()
            self.lock = os.open('vault.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                                0o600, dir_fd=self.fd)
            st = os.fstat(self.lock)
            require(stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid() and
                    stat.S_IMODE(st.st_mode) == 0o600 and st.st_nlink == 1, 'UNSAFE_VAULT_FILE')
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise BackupError('VAULT_BUSY') from None
            existing = (self.path / 'vault.sqlite').exists()
            require(existing or create, 'VAULT_MISSING')
            if not existing:
                with os.scandir(self.fd) as entries:
                    require(all(entry.name == 'vault.lock' for entry in entries), 'CATALOG_MISSING_RECOVERY_REQUIRED')
                file = os.open('vault.sqlite', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                               0o600, dir_fd=self.fd)
                os.close(file)
            # URI mode avoids creating a new catalog during read-only inspection.
            self.db = sqlite3.connect('file:' + str(self.path / 'vault.sqlite') +
                                      ('?mode=ro' if readonly else '?mode=rw'), uri=True, isolation_level=None)
            self.db.execute('PRAGMA trusted_schema=OFF')
            self.db.execute('PRAGMA busy_timeout=0')
            if not readonly:
                self.db.execute('PRAGMA synchronous=FULL')
                require(self.db.execute('PRAGMA journal_mode=DELETE').fetchone()[0] == 'delete', 'INVALID_CATALOG')
            if not existing:
                self.db.executescript('''BEGIN IMMEDIATE;
                CREATE TABLE copies (sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT UNIQUE NOT NULL, digest TEXT NOT NULL, inventory_digest TEXT NOT NULL,
                    created_ns INTEGER NOT NULL);
                CREATE TABLE audit (sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    event TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL, created_ns INTEGER NOT NULL);
                PRAGMA user_version=1;
                COMMIT;''')
                os.fsync(self.fd)
            require(self.db.execute('PRAGMA user_version').fetchone()[0] == 1 and
                    self.db.execute('PRAGMA quick_check').fetchone()[0] == 'ok', 'INVALID_CATALOG')
            schema = self.db.execute("SELECT type,name FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'").fetchall()
            require(set(schema) == {('table', 'copies'), ('table', 'audit')}, 'INVALID_CATALOG')
            self.records()  # Validate before any deletion or retention mutation.
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.db is not None: self.db.close(); self.db = None
        if self.lock is not None: os.close(self.lock); self.lock = None
        if self.fd is not None: os.close(self.fd); self.fd = None

    def __enter__(self): return self
    def __exit__(self, *args): self.close()

    def validate_entries(self):
        with os.scandir(self.fd) as entries:
            count = 0
            for entry in entries:
                count += 1
                require(count <= 1024 and (entry.name in ('vault.lock', 'vault.sqlite', 'vault.sqlite-journal') or
                        COPY.fullmatch(entry.name)), 'UNEXPECTED_VAULT_ENTRY')
                st = entry.stat(follow_symlinks=False)
                require(stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid() and st.st_nlink == 1 and
                        stat.S_IMODE(st.st_mode) == 0o600 and
                        st.st_size <= (8 * 1024 * 1024 if entry.name.endswith('.tar.gz') else MAX_DB),
                        'UNSAFE_VAULT_FILE')

    def records(self):
        records = self.db.execute('SELECT id,digest,inventory_digest,created_ns FROM copies ORDER BY sequence LIMIT 6').fetchall()
        events = self.db.execute('SELECT event,id,digest,created_ns FROM audit ORDER BY sequence LIMIT 201').fetchall()
        require(len(records) <= 5 and len(events) <= 200, 'INVALID_CATALOG')
        for identifier, digest, inv_digest, at in records:
            require(isinstance(identifier, str) and ID.fullmatch(identifier) and
                    isinstance(digest, str) and DIGEST.fullmatch(digest) and
                    isinstance(inv_digest, str) and DIGEST.fullmatch(inv_digest) and
                    isinstance(at, int) and at > 0, 'INVALID_CATALOG')
        for event, identifier, digest, at in events:
            require(event in ('IMPORTED', 'ROTATED', 'RECOVERED') and isinstance(identifier, str) and
                    ID.fullmatch(identifier) and isinstance(digest, str) and DIGEST.fullmatch(digest) and
                    isinstance(at, int) and at > 0, 'INVALID_CATALOG')
        require(len({r[0] for r in records}) == len(records) and bool(records) == bool(events), 'INVALID_CATALOG')
        receipts = {(identifier, digest, at) for event, identifier, digest, at in events if event == 'IMPORTED'}
        retired = {identifier for event, identifier, _, _ in events if event == 'ROTATED'}
        require(all((identifier, digest, at) in receipts and identifier not in retired
                    for identifier, digest, _, at in records), 'INVALID_CATALOG')
        return records

    def verified_records(self):
        records = self.records()
        for identifier, digest, inv_digest, _ in records:
            manifest = self.path / (identifier + '.inventory.json')
            raw = private_read(manifest, MAX_INVENTORY)
            require(hashlib.sha256(raw).hexdigest() == inv_digest, 'INVENTORY_CHECKSUM_MISMATCH')
            verify(self.path / (identifier + '.tar.gz'), digest, inventory(manifest))
        return records

    def write_copy(self, name, data):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=self.fd)
        with os.fdopen(fd, 'wb') as file:
            file.write(data); file.flush(); os.fsync(file.fileno())
        os.fsync(self.fd)

    def commit_copy(self, identifier, digest, inv_digest):
        now = time.time_ns()
        self.db.execute('BEGIN IMMEDIATE')
        try:
            self.db.execute('INSERT INTO copies(id,digest,inventory_digest,created_ns) VALUES(?,?,?,?)',
                            (identifier, digest, inv_digest, now))
            self.db.execute('INSERT INTO audit(event,id,digest,created_ns) VALUES(?,?,?,?)',
                            ('IMPORTED', identifier, digest, now))
            old = self.db.execute('SELECT id,digest FROM copies ORDER BY sequence DESC LIMIT -1 OFFSET 5').fetchall()
            for item_id, item_digest in old:
                self.db.execute('DELETE FROM copies WHERE id=?', (item_id,))
                self.db.execute('INSERT INTO audit(event,id,digest,created_ns) VALUES(?,?,?,?)',
                                ('ROTATED', item_id, item_digest, now))
            self.db.execute('DELETE FROM audit WHERE sequence NOT IN (SELECT sequence FROM audit ORDER BY sequence DESC LIMIT 200)')
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise
        os.fsync(self.fd)

    def garbage_collect(self):
        records = self.verified_records()
        self.validate_entries()  # Reject unsafe candidates before any unlink.
        referenced = {identifier + suffix for identifier, *_ in records for suffix in ('.tar.gz', '.inventory.json')}
        removed = 0
        with os.scandir(self.fd) as entries:
            names = [entry.name for entry in entries if COPY.fullmatch(entry.name) and entry.name not in referenced]
        retired = dict(self.db.execute("SELECT id,digest FROM audit WHERE event='ROTATED' ORDER BY sequence"))
        remove = [name for name in names if COPY.fullmatch(name).group(1) in retired]
        # A lost/rolled-back catalog cannot prove an unknown pair was never
        # committed. Preserve it; only explicit retained retirement receipts
        # authorize deletion. Validate every available retired archive first.
        for name in remove:
            if name.endswith('.tar.gz'):
                identifier = COPY.fullmatch(name).group(1)
                raw = private_read(self.path / name, 8 * 1024 * 1024)
                require(hashlib.sha256(raw).hexdigest() == retired[identifier], 'RETIRED_CHECKSUM_MISMATCH')
        for name in remove:
            os.unlink(name, dir_fd=self.fd); removed += 1
        os.fsync(self.fd)
        return removed

    def import_archive(self, archive, digest, owner_inventory):
        self.verified_records()
        required = inventory(owner_inventory)
        verify(archive, digest, required)
        raw = private_read(archive, 8 * 1024 * 1024)
        require(hashlib.sha256(raw).hexdigest() == digest, 'CHECKSUM_MISMATCH')
        manifest = (json.dumps(sorted(required), separators=(',', ':')) + '\n').encode()
        identifier = uuid.uuid4().hex
        self.write_copy(identifier + '.tar.gz', raw)
        self.write_copy(identifier + '.inventory.json', manifest)
        self.commit_copy(identifier, digest, hashlib.sha256(manifest).hexdigest())
        self.garbage_collect()
        return dict(schema_version=1, status='STORED', copies=len(self.records()),
                    unreferenced_preserved=self.preserved_unknown(),
                    completeness='OWNER_INVENTORY_ONLY', transaction_consistent=False, restore_supported=False)

    def preserved_unknown(self):
        records = self.records()
        known = {identifier for identifier, *_ in records}
        known |= {row[0] for row in self.db.execute("SELECT id FROM audit WHERE event='ROTATED'")}
        with os.scandir(self.fd) as entries:
            return sum(1 for entry in entries if COPY.fullmatch(entry.name) and
                       COPY.fullmatch(entry.name).group(1) not in known)

    def show(self):
        records = self.verified_records()
        unknown = self.preserved_unknown()
        return dict(schema_version=1, status='QUARANTINED' if unknown else 'VERIFIED', copies=len(records),
                    unreferenced_preserved=unknown,
                    audit_events=self.db.execute('SELECT count(*) FROM audit').fetchone()[0],
                    transaction_consistent=False, restore_supported=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('import', 'show', 'recover'))
    parser.add_argument('--vault', type=Path, required=True)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--sha256')
    parser.add_argument('--inventory', type=Path)
    args = parser.parse_args()
    try:
        require(args.operation != 'import' or (args.archive and args.sha256 and args.inventory), 'IMPORT_ARGUMENTS_REQUIRED')
        with Vault(args.vault, create=args.operation == 'import', readonly=args.operation == 'show') as vault:
            if args.operation == 'import':
                result = vault.import_archive(args.archive, args.sha256, args.inventory)
            elif args.operation == 'recover':
                vault.garbage_collect()
                result = vault.show()
                result['status'] = 'QUARANTINED' if result['unreferenced_preserved'] else 'RECOVERED'
            else:
                result = vault.show()
    except (BackupError, OSError, sqlite3.Error, ValueError) as error:
        print(json.dumps(dict(schema_version=1, status=str(error) if isinstance(error, BackupError) else 'VAULT_UNAVAILABLE')))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__': raise SystemExit(main())
