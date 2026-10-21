"""Build a pinned, deliberately VM-only HGDEPLOY2 owner update candidate.

No owner profile exists until the new update/recovery acceptance is complete.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/deploy'))
from transport import PATHS

BASELINE = '62592457237e7f026786c086d1ca6fdd4b6c095d'
DELTA = 'usr/lib/home-gateway/telegram-poller.uc'


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE)


def content(repo, ref):
    commit = git(repo, 'rev-parse', '--verify', '--end-of-options', ref + '^{commit}').decode().strip()
    files = {}
    inventories = {}
    for name, sha in [('baseline', BASELINE), ('candidate', commit)]:
        entries = git(repo, 'ls-tree', '-rz', sha, '--', 'src/').split(b'\0')
        inventory = {}
        for entry in filter(None, entries):
            header, raw_path = entry.split(b'\t', 1)
            mode, kind, oid = header.decode().split()
            path = raw_path.decode().removeprefix('src/')
            expected = '100755' if path in PATHS[:3] else '100644'
            if path not in PATHS or mode != expected or kind != 'blob':
                raise ValueError('RUNTIME_INVENTORY')
            data = git(repo, 'cat-file', 'blob', oid)
            if b'\r' in data or b'\0' in data or len(data) > 262144:
                raise ValueError('RUNTIME_TEXT')
            files[name + '/' + path] = (int(mode[-3:], 8), data)
            inventory[path] = hashlib.sha256(data).hexdigest()
        if set(inventory) != set(PATHS):
            raise ValueError('RUNTIME_INVENTORY')
        inventories[name] = inventory
        files[name + '.sha256'] = (0o600, ''.join(inventory[p] + '  ' + p + '\n' for p in PATHS).encode())
    changed = [p for p in PATHS if inventories['baseline'][p] != inventories['candidate'][p]]
    if changed != [DELTA]:
        raise ValueError('TELEGRAM_ONLY_DELTA_REQUIRED')
    for name in ('update.sh', 'inspect.uc', 'owner.ps1'):
        files[name] = (0o700 if name.endswith('.sh') else 0o600,
                       git(repo, 'show', commit + ':scripts/owner_update/' + name))
    controls = {}
    for source, path in [('engine.sh', 'usr/libexec/home-gateway-deploy/engine.sh'),
                         ('wrapper.sh', 'usr/libexec/home-gateway-deploy/wrapper.sh'),
                         ('recovery.init', 'etc/init.d/home-gateway-deploy-recover'),
                         ('migration-boot.init', 'etc/init.d/home-gateway-migration'),
                         ('migration-admission.sh', 'usr/libexec/home-gateway-deploy/migration-admission.sh')] + [
                             ('migration-' + n + '.uc', 'usr/libexec/home-gateway-deploy/migration-' + n + '.uc')
                             for n in ('state', 'snapshot', 'candidate', 'runtime', 'handoff', 'coordinator', 'controls', 'service', 'terminal')]:
        data = git(repo, 'show', BASELINE + ':scripts/deploy/' + source)
        controls[path] = hashlib.sha256(data).hexdigest()
    manifest = dict(format='HG_OWNER_UPDATE_V1', profile='VM_ONLY', production_apply=False,
                    source_commit=commit, baseline_commit=BASELINE, changed=changed,
                    inventories=inventories,
                    controls=controls,
                    files=[dict(path=p, mode=m, sha256=hashlib.sha256(d).hexdigest(), size=len(d))
                           for p, (m, d) in sorted(files.items())])
    files['manifest.json'] = (0o600, (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode())
    return commit, files, manifest


def build(repo, ref, output):
    commit, files, manifest = content(repo, ref)
    timestamp = int(git(repo, 'show', '-s', '--format=%ct', commit))
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode='wb', filename='', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.USTAR_FORMAT) as tar:
            parents = {str(d) for p in files for d in Path(p).parents if str(d) != '.'}
            for p in sorted(parents):
                entry = tarfile.TarInfo(p + '/'); entry.type = tarfile.DIRTYPE
                entry.mode = 0o700; entry.mtime = timestamp; tar.addfile(entry)
            for p, (mode, data) in sorted(files.items()):
                entry = tarfile.TarInfo(p); entry.mode = mode; entry.size = len(data)
                entry.mtime = timestamp; tar.addfile(entry, io.BytesIO(data))
    output = Path(output); output.mkdir(parents=True, exist_ok=True)
    path = output / ('hg-owner-update-vm-' + commit + '.tar.gz')
    with path.open('xb') as f:
        f.write(buffer.getvalue())
    digest = hashlib.sha256(buffer.getvalue()).hexdigest()
    path.with_suffix('.gz.sha256').write_text(digest + '  ' + path.name + '\n', encoding='ascii')
    (output / 'manifest.json').write_bytes(files['manifest.json'][1])
    (output / 'owner.ps1').write_bytes(files['owner.ps1'][1])
    return path


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ref', default='HEAD'); p.add_argument('--output', type=Path, required=True)
    a = p.parse_args(); print(build(ROOT, a.ref, a.output))
