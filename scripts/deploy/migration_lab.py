"""HGDEPLOY1 (18 files) to HGDEPLOY2 rehearsal on a disposable filesystem only.

No SSH, service commands, archive extraction or production entrypoint. The live
migration remains blocked until an OpenWrt service/admission coordinator exists.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

from transport import PATHS

NEW = tuple(PATHS)
ADDED = ('usr/lib/home-gateway/actions.uc', 'usr/lib/home-gateway/notifications.uc')
OLD = tuple(p for p in NEW if p not in ADDED)
RECEIVERS = ('usr/libexec/home-gateway-deploy/engine.sh',
             'usr/libexec/home-gateway-deploy/wrapper.sh',
             'etc/init.d/home-gateway-deploy-recover')
ALL = NEW + RECEIVERS
MAX_FILE = 262144


class Refused(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise Refused(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def mode(path):
    if path in RECEIVERS[:2]:
        return 0o700
    return 0o755 if path in NEW[:3] or path == RECEIVERS[2] else 0o644


def checked(path, directory=False, expected_mode=None):
    # All filesystem reads are bounded and reject symlinks, including ancestors.
    for part in (path, *path.parents):
        st = part.lstat()
        require(not stat.S_ISLNK(st.st_mode), 'SYMLINK')
        require(st.st_uid == os.geteuid() if part == path else st.st_uid in (0, os.geteuid()), 'OWNER')
        if part != path:
            require(stat.S_ISDIR(st.st_mode), 'PARENT_TYPE')
            require(not st.st_mode & 0o022 or st.st_mode & stat.S_ISVTX, 'WRITABLE_PARENT')
    st = path.lstat()
    require(stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode), 'FILE_TYPE')
    if not directory:
        require(st.st_nlink == 1 and st.st_size <= MAX_FILE, 'FILE_METADATA')
    if expected_mode is not None:
        require(stat.S_IMODE(st.st_mode) == expected_mode, 'MODE')
    return st


def read(path, expected_mode=None):
    checked(path, expected_mode=expected_mode)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        data = os.read(fd, MAX_FILE + 1)
        after = os.fstat(fd)
        require(len(data) <= MAX_FILE and len(data) == before.st_size and
                (before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_ino, after.st_size, after.st_mtime_ns), 'FILE_CHANGED')
        return data
    finally:
        os.close(fd)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def mkdir(path):
    if path.exists() or path.is_symlink():
        checked(path, directory=True)
        return
    mkdir(path.parent)
    path.mkdir(mode=0o700)
    sync_dir(path.parent)


def write(path, data, permissions):
    checked(path.parent, directory=True)
    if path.exists() or path.is_symlink():
        checked(path)
    tmp = path.with_name(path.name + '.migration-new')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, permissions)
    try:
        os.fchmod(fd, permissions)
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        sync_dir(path.parent)
    except BaseException:
        if tmp.exists() and not tmp.is_symlink():
            tmp.unlink()
        raise


def parse_manifest(raw, inventory):
    try:
        text = raw.decode('ascii')
    except UnicodeError:
        raise Refused('MANIFEST_ENCODING') from None
    rows = text.splitlines()
    require(len(rows) == len(inventory), 'INVENTORY_COUNT')
    result = {}
    for row in rows:
        require(re.fullmatch(r'[0-9a-f]{64}  [a-zA-Z0-9/_.-]+', row), 'MANIFEST_FORMAT')
        sha, rel = row.split('  ')
        require(rel in inventory and rel not in result, 'INVENTORY_PATH')
        result[rel] = sha
    require(set(result) == set(inventory), 'INVENTORY_EXACT')
    return result


def verify_files(base, records):
    for rel, sha in records.items():
        require(digest(read(base / rel, mode(rel))) == sha, 'FILE_DRIFT')


class Migration:
    def __init__(self, root):
        self.root = Path(root).absolute()
        require(self.root != Path('/') and self.root != Path('/etc'), 'LAB_ROOT_ONLY')
        require(read(self.root / '.hg-migration-lab') == b'DISPOSABLE_HG_MIGRATION_LAB\n', 'LAB_ROOT_ONLY')
        self.base = self.root / 'etc/home-gateway-deploy'
        checked(self.base, True, 0o700)
        self.state = self.root / 'etc/home-gateway-migration-lab'
        if self.state.exists() or self.state.is_symlink():
            checked(self.state, True, 0o700)
        else:
            self.state.mkdir(mode=0o700)
            sync_dir(self.state.parent)
        lock = self.state / 'lock'
        if lock.exists() or lock.is_symlink():
            checked(lock, expected_mode=0o600)
        self.lockfd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        require(stat.S_ISREG(os.fstat(self.lockfd).st_mode), 'LOCK_TYPE')
        try:
            fcntl.flock(self.lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.lockfd)
            raise Refused('MIGRATION_BUSY') from None

    def close(self):
        if self.lockfd is not None:
            os.close(self.lockfd)
            self.lockfd = None

    def legacy(self):
        require(not (self.base / 'active').exists() and not (self.base / 'active').is_symlink(), 'LEGACY_ACTIVE')
        latest = read(self.base / 'latest', 0o600)
        require(re.fullmatch(rb'tx\.[a-zA-Z0-9]{1,32}\n', latest), 'TX_ID')
        tx = self.base / latest.decode().strip()
        checked(tx, True, 0o700)
        require(read(tx / 'phase', 0o600) == b'COMMITTED\n', 'LEGACY_PHASE')
        require(not (tx / 'inventory-version').exists() and not (tx / 'inventory-version').is_symlink(), 'MIXED_FORMAT')
        require(read(tx / 'was-running', 0o600) in (b'0\n', b'1\n'), 'WAS_RUNNING')
        require(re.fullmatch(rb'[0-9a-f]{40}\n', read(tx / 'commit', 0o600)), 'COMMIT')
        raw_backup = read(tx / 'backup.sha256', 0o600)
        raw_new = read(tx / 'new.sha256', 0o600)
        backup = parse_manifest(raw_backup, OLD)
        live = parse_manifest(raw_new, OLD)
        verify_files(tx / 'backup', backup)
        verify_files(self.root, live)
        for rel in ADDED:
            require(not (self.root / rel).exists() and not (self.root / rel).is_symlink(), 'ADDED_ALREADY_EXISTS')
        previous = {rel: read(self.root / rel, mode(rel)) for rel in OLD + RECEIVERS}
        receipt = dict(latest=latest.decode(), backup_sha=digest(raw_backup), new_sha=digest(raw_new),
                       old={p: digest(b) for p, b in previous.items()})
        return receipt, previous

    def load(self):
        try:
            receipt = json.loads(read(self.state / 'receipt.json', 0o600))
        except (ValueError, UnicodeError, RecursionError):
            raise Refused('RECEIPT_FORMAT') from None
        require(isinstance(receipt, dict) and set(receipt) == {'latest', 'backup_sha', 'new_sha', 'old', 'new'}, 'RECEIPT_FORMAT')
        require(isinstance(receipt['latest'], str) and re.fullmatch(r'tx\.[a-zA-Z0-9]{1,32}\n', receipt['latest']), 'TX_ID')
        require(all(isinstance(receipt[k], str) and re.fullmatch('[0-9a-f]{64}', receipt[k]) for k in ('backup_sha', 'new_sha')), 'RECEIPT_DIGEST')
        for key, inventory in (('old', OLD + RECEIVERS), ('new', ALL)):
            records = receipt[key]
            require(isinstance(records, dict) and set(records) == set(inventory), 'RECEIPT_INVENTORY')
            require(all(isinstance(s, str) and re.fullmatch('[0-9a-f]{64}', s) for s in records.values()), 'RECEIPT_DIGEST')
            verify_files(self.state / key, records)
        tx = self.base / receipt['latest'].strip()
        checked(tx, True, 0o700)
        require(read(tx / 'phase', 0o600) == b'COMMITTED\n', 'LEGACY_CHANGED')
        for name, key in (('backup.sha256', 'backup_sha'), ('new.sha256', 'new_sha')):
            require(digest(read(tx / name, 0o600)) == receipt[key], 'LEGACY_CHANGED')
        verify_files(tx / 'backup', parse_manifest(read(tx / 'backup.sha256', 0o600), OLD))
        require(not (self.base / 'active').exists() and not (self.base / 'active').is_symlink(), 'NEW_TRANSACTION_ACTIVE')
        return receipt

    def phase(self, value):
        write(self.state / 'phase', (value + '\n').encode(), 0o600)

    def prepare(self, candidate, sha256):
        require(not (self.state / 'receipt.json').exists(), 'ALREADY_PREPARED')
        require(not (self.state / 'phase').exists(), 'INCOMPLETE_PREPARATION')
        receipt, previous = self.legacy()
        for path in [self.root / p for p in ALL] + [self.base / 'latest', self.state / 'phase']:
            tmp = path.with_name(path.name + '.migration-new')
            require(not tmp.exists() and not tmp.is_symlink(), 'TEMPORARY_PREEXISTS')
        candidate = Path(candidate).absolute()
        manifest = read(candidate / 'migration.sha256', 0o600)
        require(re.fullmatch('[0-9a-f]{64}', sha256) and digest(manifest) == sha256, 'CANDIDATE_SHA256')
        records = parse_manifest(manifest, ALL)
        verify_files(candidate, records)
        self.phase('PREPARING')
        for area, paths, source in (('old', OLD + RECEIVERS, previous), ('new', ALL, candidate)):
            for rel in paths:
                dst = self.state / area / rel
                mkdir(dst.parent)
                data = source[rel] if area == 'old' else read(source / rel, mode(rel))
                write(dst, data, mode(rel))
        receipt['new'] = records
        write(self.state / 'receipt.json', json.dumps(receipt, sort_keys=True).encode(), 0o600)
        self.load()
        self.phase('PREPARED')
        return 'PREPARED'

    def clean_temporaries(self, r):
        # Only fixed reserved names that were absent at prepare; accept partial
        # writes only when they are exact prefixes of this receipt's own bytes.
        expected = []
        for rel in ALL:
            data = [read(self.state / 'new' / rel, mode(rel))]
            if rel in r['old']:
                data.append(read(self.state / 'old' / rel, mode(rel)))
            expected.append((self.root / rel, mode(rel), data))
        expected.append((self.base / 'latest', 0o600, [r['latest'].encode()]))
        phases = ['PREPARING', 'PREPARED', 'APPLYING', 'COMMITTED', 'RESTORING', 'ROLLED_BACK']
        expected.append((self.state / 'phase', 0o600, [(p + '\n').encode() for p in phases]))
        remove = []
        for path, permissions, values in expected:
            tmp = path.with_name(path.name + '.migration-new')
            if tmp.exists() or tmp.is_symlink():
                data = read(tmp, permissions)
                require(any(value.startswith(data) for value in values), 'TEMPORARY_DRIFT')
                remove.append(tmp)
        # Validate the entire list before deleting anything.
        for tmp in remove:
            tmp.unlink()
            sync_dir(tmp.parent)

    def fence(self):
        lock = self.root / 'tmp/home-gateway-deploy.lock'
        if lock.exists() or lock.is_symlink():
            checked(lock, True, 0o700)
            require(set(p.name for p in lock.iterdir()) == {'migration-lab-fence'}, 'DEPLOYMENT_BUSY')
            require(read(lock / 'migration-lab-fence', 0o600) == digest(read(self.state / 'receipt.json', 0o600)).encode(), 'FENCE_CHANGED')
        else:
            checked(lock.parent, True)
            lock.mkdir(mode=0o700)
            sync_dir(lock.parent)
            write(lock / 'migration-lab-fence', digest(read(self.state / 'receipt.json', 0o600)).encode(), 0o600)
        # Deliberately no pid: both old/new receivers refuse even stale recover.
        return lock

    def unfence(self, lock):
        (lock / 'migration-lab-fence').unlink()
        lock.rmdir()
        sync_dir(lock.parent)

    def apply(self):
        r = self.load()
        phase = read(self.state / 'phase', 0o600).decode().strip()
        require(phase in ('PREPARED', 'COMMITTED'), 'RECOVERY_REQUIRED')
        if phase == 'COMMITTED':
            self.check_new(r)
            lock = self.fence()
            self.clean_temporaries(r)
            self.unfence(lock)
            return 'ALREADY_COMMITTED'
        # Freeze old state again immediately before the first live write.
        fresh, _ = self.legacy()
        require(all(fresh[k] == r[k] for k in fresh), 'LEGACY_CHANGED')
        lock = self.fence()
        self.clean_temporaries(r)
        self.phase('APPLYING')
        for rel in ALL:
            write(self.root / rel, read(self.state / 'new' / rel, mode(rel)), mode(rel))
        # Do not relabel the legacy transaction. New receiver starts with no latest.
        (self.base / 'latest').unlink()
        sync_dir(self.base)
        self.check_new(r)
        self.phase('COMMITTED')
        self.unfence(lock)
        return 'COMMITTED'

    def check_new(self, r):
        require(not (self.base / 'latest').exists() and not (self.base / 'latest').is_symlink(), 'NEW_DEPLOYMENT_EXISTS')
        verify_files(self.root, r['new'])

    def rollback(self):
        r = self.load()
        phase = read(self.state / 'phase', 0o600).decode().strip()
        require(phase in ('PREPARED', 'APPLYING', 'COMMITTED', 'RESTORING', 'ROLLED_BACK'), 'PHASE')
        latest = self.base / 'latest'
        if latest.exists() or latest.is_symlink():
            require(read(latest, 0o600).decode() == r['latest'], 'NEW_DEPLOYMENT_EXISTS')
        # Interrupted apply can contain only old/new bytes at each known path.
        for rel in ALL:
            dst = self.root / rel
            if not dst.exists() and not dst.is_symlink():
                require(rel in ADDED, 'MISSING_RUNTIME')
                continue
            require(digest(read(dst, mode(rel))) in {r['new'][rel], r['old'].get(rel)}, 'FILE_DRIFT')
        lock = self.fence()
        self.clean_temporaries(r)
        self.phase('RESTORING')
        for rel in OLD + RECEIVERS:
            write(self.root / rel, read(self.state / 'old' / rel, mode(rel)), mode(rel))
        for rel in ADDED:
            dst = self.root / rel
            if dst.exists():
                dst.unlink()
                sync_dir(dst.parent)
        write(latest, r['latest'].encode(), 0o600)
        self.legacy()
        self.phase('ROLLED_BACK')
        self.unfence(lock)
        return 'ROLLED_BACK'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'apply', 'rollback', 'status'))
    parser.add_argument('--lab-root', required=True)
    parser.add_argument('--candidate')
    parser.add_argument('--sha256')
    args = parser.parse_args()
    migration = None
    try:
        migration = Migration(args.lab_root)
        if args.operation == 'prepare':
            require(args.candidate is not None and args.sha256 is not None, 'CANDIDATE_REQUIRED')
            result = migration.prepare(args.candidate, args.sha256)
        elif args.operation == 'status':
            receipt = migration.load()
            result = read(migration.state / 'phase', 0o600).decode().strip()
            require(result in ('PREPARED', 'APPLYING', 'COMMITTED', 'RESTORING', 'ROLLED_BACK'), 'PHASE')
            if result == 'COMMITTED':
                migration.check_new(receipt)
            elif result == 'ROLLED_BACK':
                verify_files(migration.root, receipt['old'])
                migration.legacy()
        else:
            result = getattr(migration, args.operation)()
        print('MIGRATION_LAB=' + result + ' PRODUCTION_SUPPORTED=false')
        return 0
    except (OSError, ValueError, TypeError, KeyError) as error:
        print('MIGRATION_LAB=REFUSED REASON=' + (str(error) if isinstance(error, Refused) else 'STATE_INVALID'), file=sys.stderr)
        return 70
    finally:
        if migration is not None:
            migration.close()


if __name__ == '__main__':
    raise SystemExit(main())
