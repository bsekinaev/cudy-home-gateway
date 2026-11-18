"""Build source-bound VM_ONLY series packages; owner release stays closed.

Controller files must exist in the selected committed source. Host fixtures can
exercise this packaging contract, but are not executable lifecycle evidence.
"""
import argparse
import gzip
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile

from archive import read_archive, MAX_ARCHIVE
from parent import ACCEPTED, ORIGINAL, PATHS, CONTROLS, digest, git, strict_json, validate_parent

ROOT = Path(__file__).resolve().parents[2]
HELPERS = {'protocol.uc': 0o600, 'state.uc': 0o600, 'engine.uc': 0o600, 'watch.uc': 0o600,
           'boot.init': 0o755, 'owner.ps1': 0o600}
ALLOWED = {'usr/lib/home-gateway/' + name for name in
           ('telegram-poller.uc', 'dns.sh', 'health.sh', 'redmi.sh', 'status.sh')}
KEYS = {'format', 'profile', 'production_apply', 'source_commit', 'baseline_commit',
        'source_fixture', 'parent', 'bootstrap', 'inventories', 'changed', 'controls', 'files'}


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def _vm_only(profile):
    if profile == 'owner':
        raise ValueError('OWNER_SERIES_ACCEPTANCE_NOT_IMPLEMENTED')
    if profile != 'vm':
        raise ValueError('SERIES_PROFILE')


def _commit(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{40}', value)


def _runtime(repo, source):
    if not _commit(source):
        raise ValueError('SERIES_SOURCE')
    try:
        entries = git(repo, 'ls-tree', '-rz', source, '--', 'src/').split(b'\0')
        files = {}
        for entry in filter(None, entries):
            header, name = entry.split(b'\t', 1)
            mode, kind, oid = header.decode().split()
            path = name.decode().removeprefix('src/')
            expected = '100755' if path in PATHS[:3] else '100644'
            if path not in PATHS or mode != expected or kind != 'blob':
                raise ValueError('SERIES_RUNTIME_INVENTORY')
            data = git(repo, 'cat-file', 'blob', oid)
            if not data or len(data) > 262144 or b'\r' in data or b'\0' in data:
                raise ValueError('SERIES_RUNTIME_TEXT')
            files[path] = (int(mode[-3:], 8), data)
    except subprocess.CalledProcessError as error:
        raise ValueError('SERIES_SOURCE_MISSING') from error
    if set(files) != set(PATHS):
        raise ValueError('SERIES_RUNTIME_INVENTORY')
    return files


def _controls(repo, source):
    try:
        return {path: digest(git(repo, 'show', source + ':scripts/deploy/' + name))
                for name, path in CONTROLS}
    except subprocess.CalledProcessError as error:
        raise ValueError('SERIES_CONTROL_SOURCE') from error


def _inventory(files):
    return {path: digest(files[path][1]) for path in PATHS}


def _sums(inventory):
    return ''.join(inventory[path] + '  ' + path + '\n' for path in PATHS).encode()


def _record(files):
    return [{'path': path, 'mode': mode, 'size': len(data), 'sha256': digest(data)}
            for path, (mode, data) in sorted(files.items())]


def _helper(repo, source, name):
    path = 'scripts/owner_series/' + name
    try:
        entry = git(repo, 'ls-tree', '-z', source, '--', path)
        header, found = entry.rstrip(b'\0').split(b'\t', 1)
        mode, kind, oid = header.decode().split()
        expected_mode = '100755' if name == 'boot.init' else '100644'
        if mode != expected_mode or kind != 'blob' or found.decode() != path:
            raise ValueError('SERIES_CONTROLLER_MODE')
        data = git(repo, 'cat-file', 'blob', oid)
    except (subprocess.CalledProcessError, UnicodeDecodeError) as error:
        raise ValueError('SERIES_CONTROLLER_MISSING') from error
    except ValueError as error:
        if str(error) == 'SERIES_CONTROLLER_MODE':
            raise
        raise ValueError('SERIES_CONTROLLER_MISSING') from error
    if not data or len(data) > 262144 or b'\r' in data or b'\0' in data:
        raise ValueError('SERIES_CONTROLLER_TEXT')
    return data


def _identity(parent):
    return {'format': parent['manifest']['format'],
            'source_commit': parent['manifest']['source_commit'],
            'manifest_sha256': parent['manifest_sha256'],
            'archive_sha256': parent['archive_sha256']}


def _parent(raw, pin, profile, repo):
    files = read_archive(raw, pin)
    if 'manifest.json' not in files:
        raise ValueError('SERIES_PARENT_MANIFEST')
    m = strict_json(files['manifest.json'][1])
    if not isinstance(m, dict):
        raise ValueError('SERIES_PARENT_MANIFEST')
    if m.get('format') == 'HG_OWNER_UPDATE_V1':
        return validate_parent(raw, pin, profile, repo)
    return validate_series(raw, pin, profile, repo)


def _core(m):
    if (not isinstance(m, dict) or set(m) != KEYS or m['format'] != 'HG_OWNER_UPDATE_V2' or
            m['profile'] != 'VM_ONLY' or m['production_apply'] is not False or
            type(m['source_fixture']) is not bool or not _commit(m['source_commit']) or
            not _commit(m['baseline_commit'])):
        raise ValueError('SERIES_MANIFEST')


def _prior_manifest(m, repo, bootstrap):
    """Check all flat prior metadata derivable from Git and the fixed anchor.

    Its own parent.json bytes are deliberately not recursively embedded. That
    record remains a bounded digest to be matched against durable target history.
    """
    _core(m)
    known = {}
    inventories = {}
    for name, source in (('baseline', m['baseline_commit']), ('candidate', m['source_commit'])):
        runtime = _runtime(repo, source)
        inventories[name] = _inventory(runtime)
        known.update({name + '/' + p: value for p, value in runtime.items()})
        known[name + '.sha256'] = (0o600, _sums(inventories[name]))
    changed = [p for p in PATHS if inventories['baseline'][p] != inventories['candidate'][p]]
    controls = _controls(repo, ORIGINAL)
    anchor = {'archive_sha256': bootstrap['archive_sha256'], 'manifest_sha256': bootstrap['manifest_sha256']}
    if (m['inventories'] != inventories or not changed or not set(changed) <= ALLOWED or
            m['changed'] != changed or m['controls'] != controls or
            _controls(repo, m['source_commit']) != controls or m['bootstrap'] != anchor):
        raise ValueError('SERIES_PRIOR_METADATA')
    for ancestor, child in ((ACCEPTED, m['baseline_commit']),
                            (m['baseline_commit'], m['source_commit'])):
        if subprocess.run(['git', '-C', str(repo), 'merge-base', '--is-ancestor', ancestor, child],
                          capture_output=True).returncode:
            raise ValueError('SERIES_PRIOR_LINEAGE')
    for name, mode in HELPERS.items():
        known[name] = (mode, _helper(repo, m['source_commit'], name))
    # Keep the identical raw bootstrap, not a newly serialized equivalent.
    expected = {entry['path']: entry for entry in _record(known)}
    bootstrap_size = bootstrap['raw_size']
    expected['bootstrap.tar.gz'] = dict(path='bootstrap.tar.gz', mode=0o600,
                                      size=bootstrap_size, sha256=bootstrap['archive_sha256'])
    if not isinstance(m['files'], list) or len(m['files']) != len(expected) + 1:
        raise ValueError('SERIES_PRIOR_INVENTORY')
    seen = set()
    for entry in m['files']:
        if (not isinstance(entry, dict) or set(entry) != {'path', 'mode', 'size', 'sha256'} or
                not isinstance(entry['path'], str) or entry['path'] in seen or
                type(entry['mode']) is not int or type(entry['size']) is not int):
            raise ValueError('SERIES_PRIOR_INVENTORY')
        path = entry['path']
        seen.add(path)
        if path == 'parent.json':
            if (entry['mode'] != 0o600 or not 0 < entry['size'] <= 65536 or
                    not isinstance(entry['sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', entry['sha256'])):
                raise ValueError('SERIES_PRIOR_INVENTORY')
        elif path not in expected or entry != expected[path]:
            raise ValueError('SERIES_PRIOR_INVENTORY')
    if seen != set(expected) | {'parent.json'}:
        raise ValueError('SERIES_PRIOR_INVENTORY')
    link = m['parent']
    if (not isinstance(link, dict) or
            set(link) != {'format', 'source_commit', 'manifest_sha256', 'archive_sha256'} or
            link['format'] not in ('HG_OWNER_UPDATE_V1', 'HG_OWNER_UPDATE_V2') or
            link['source_commit'] != m['baseline_commit'] or
            any(not isinstance(link[p], str) or not re.fullmatch(r'[0-9a-f]{64}', link[p])
                for p in ('manifest_sha256', 'archive_sha256'))):
        raise ValueError('SERIES_PRIOR_PARENT')
    if link['format'] == 'HG_OWNER_UPDATE_V1' and link != _identity(bootstrap):
        raise ValueError('SERIES_PRIOR_PARENT')


def validate_series(raw, pin, profile, repo):
    """Verify one supplied parent package and its flat bootstrap/parent witness.

    The explicit archive pin is the caller's approved parent identity. Historical
    target receipts are not inferred from this host-only check.
    """
    _vm_only(profile)
    files = read_archive(raw, pin)
    if 'manifest.json' not in files or files['manifest.json'][0] != 0o600:
        raise ValueError('SERIES_MANIFEST')
    m = strict_json(files['manifest.json'][1])
    _core(m)
    expected = dict(HELPERS)
    expected.update({p: 0o600 for p in ('baseline.sha256', 'candidate.sha256', 'bootstrap.tar.gz', 'parent.json')})
    for name in ('baseline', 'candidate'):
        expected.update({name + '/' + p: 0o755 if p in PATHS[:3] else 0o644 for p in PATHS})
    if (set(files) != set(expected) | {'manifest.json'} or not isinstance(m['files'], list) or
            len(m['files']) != len(expected)):
        raise ValueError('SERIES_INVENTORY')
    seen = set()
    for entry in m['files']:
        if (not isinstance(entry, dict) or set(entry) != {'path', 'mode', 'size', 'sha256'} or
                not isinstance(entry['path'], str) or entry['path'] not in expected or entry['path'] in seen):
            raise ValueError('SERIES_INVENTORY')
        path = entry['path']
        seen.add(path)
        mode, data = files[path]
        if (type(entry['mode']) is not int or type(entry['size']) is not int or
                entry['mode'] != mode or mode != expected[path] or entry['size'] != len(data) or
                entry['sha256'] != digest(data)):
            raise ValueError('SERIES_FILE_PIN')
    inventories = {}
    for name, source in (('baseline', m['baseline_commit']), ('candidate', m['source_commit'])):
        runtime = _runtime(repo, source)
        inventories[name] = _inventory(runtime)
        if any(files[name + '/' + p] != runtime[p] for p in PATHS):
            raise ValueError('SERIES_RUNTIME_SOURCE')
        if files[name + '.sha256'][1] != _sums(inventories[name]):
            raise ValueError('SERIES_RUNTIME_MANIFEST')
    changed = [p for p in PATHS if inventories['baseline'][p] != inventories['candidate'][p]]
    if not changed or not set(changed) <= ALLOWED or m['changed'] != changed or m['inventories'] != inventories:
        raise ValueError('SERIES_DELTA')
    controls = _controls(repo, ORIGINAL)
    if m['controls'] != controls or _controls(repo, m['source_commit']) != controls:
        raise ValueError('SERIES_CONTROLS')
    for path in HELPERS:
        if files[path][1] != _helper(repo, m['source_commit'], path):
            raise ValueError('SERIES_HELPER_SOURCE')
    bootstrap_raw = files['bootstrap.tar.gz'][1]
    bootstrap = validate_parent(bootstrap_raw, digest(bootstrap_raw), profile, repo)
    bootstrap['raw_size'] = len(bootstrap_raw)
    anchor = {'archive_sha256': bootstrap['archive_sha256'], 'manifest_sha256': bootstrap['manifest_sha256']}
    if m['bootstrap'] != anchor:
        raise ValueError('SERIES_BOOTSTRAP')
    previous_raw = files['parent.json'][1]
    if len(previous_raw) > 65536:
        raise ValueError('SERIES_PARENT_MANIFEST_SIZE')
    previous = strict_json(previous_raw)
    link = m['parent']
    if (not isinstance(previous, dict) or not isinstance(link, dict) or
            set(link) != {'format', 'source_commit', 'manifest_sha256', 'archive_sha256'} or
            link.get('manifest_sha256') != digest(previous_raw) or
            not isinstance(link.get('archive_sha256'), str) or
            not re.fullmatch(r'[0-9a-f]{64}', link['archive_sha256']) or
            link.get('source_commit') != m['baseline_commit'] or
            previous.get('source_commit') != m['baseline_commit'] or
            link.get('format') != previous.get('format') or
            not isinstance(previous.get('inventories'), dict) or
            previous['inventories'].get('candidate') != inventories['baseline'] or
            previous.get('controls') != controls):
        raise ValueError('SERIES_PARENT_LINK')
    if previous['format'] == 'HG_OWNER_UPDATE_V1':
        if (previous_raw != bootstrap['files']['manifest.json'][1] or
                link != _identity(bootstrap) or m['baseline_commit'] != ACCEPTED):
            raise ValueError('SERIES_PARENT_LINK')
    else:
        _prior_manifest(previous, repo, bootstrap)
        if (previous['bootstrap'] != anchor or
                previous['source_fixture'] and not m['source_fixture']):
            raise ValueError('SERIES_PARENT_LINK')
    if subprocess.run(['git', '-C', str(repo), 'merge-base', '--is-ancestor',
                       m['baseline_commit'], m['source_commit']], capture_output=True).returncode:
        raise ValueError('SERIES_SOURCE_LINEAGE')
    return {'manifest': m, 'manifest_sha256': digest(files['manifest.json'][1]),
            'archive_sha256': pin, 'files': files}


def content(repo, ref, parent_raw, parent_pin, profile='vm', source_fixture=False):
    _vm_only(profile)
    if type(source_fixture) is not bool:
        raise ValueError('SERIES_FIXTURE_FLAG')
    source = git(repo, 'rev-parse', '--verify', '--end-of-options', ref + '^{commit}').decode().strip()
    if git(repo, 'rev-parse', 'HEAD').decode().strip() != source:
        raise ValueError('SOURCE_CHECKOUT_MISMATCH')
    if git(repo, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('SOURCE_DIRTY')
    for name in ('archive.py', 'parent.py', 'build_kit.py'):
        expected = git(repo, 'show', source + ':scripts/owner_series/' + name)
        if (Path(__file__).parent / name).read_bytes().replace(b'\r\n', b'\n') != expected:
            raise ValueError('SOURCE_DEPENDENCY_DRIFT')
    parent = _parent(parent_raw, parent_pin, profile, repo)
    baseline = parent['manifest']['source_commit']
    runtime = {'baseline': _runtime(repo, baseline), 'candidate': _runtime(repo, source)}
    inventories = {name: _inventory(value) for name, value in runtime.items()}
    changed = [p for p in PATHS if inventories['baseline'][p] != inventories['candidate'][p]]
    if not changed or not set(changed) <= ALLOWED:
        raise ValueError('SERIES_OBSERVER_DELTA_REQUIRED')
    controls = _controls(repo, ORIGINAL)
    if _controls(repo, source) != controls or parent['manifest']['controls'] != controls:
        raise ValueError('SERIES_CONTROLS')
    if subprocess.run(['git', '-C', str(repo), 'merge-base', '--is-ancestor', baseline, source],
                      capture_output=True).returncode:
        raise ValueError('SERIES_SOURCE_LINEAGE')
    files = {}
    for name, paths in runtime.items():
        files.update({name + '/' + p: value for p, value in paths.items()})
        files[name + '.sha256'] = (0o600, _sums(inventories[name]))
    for name, mode in HELPERS.items():
        files[name] = (mode, _helper(repo, source, name))
    if parent['manifest']['format'] == 'HG_OWNER_UPDATE_V1':
        bootstrap_raw = parent_raw
        bootstrap_pin = {'archive_sha256': parent_pin, 'manifest_sha256': parent['manifest_sha256']}
    else:
        bootstrap_raw = parent['files']['bootstrap.tar.gz'][1]
        bootstrap_pin = parent['manifest']['bootstrap']
        source_fixture = source_fixture or parent['manifest']['source_fixture']
    files['bootstrap.tar.gz'] = (0o600, bootstrap_raw)
    files['parent.json'] = (0o600, parent['files']['manifest.json'][1])
    manifest = dict(format='HG_OWNER_UPDATE_V2', profile='VM_ONLY', production_apply=False,
                    source_commit=source, baseline_commit=baseline, source_fixture=source_fixture,
                    parent=_identity(parent), bootstrap=bootstrap_pin, inventories=inventories,
                    changed=changed, controls=controls, files=_record(files))
    files['manifest.json'] = (0o600, encoded(manifest))
    return source, files, manifest


def build(repo, ref, parent_raw, parent_pin, output, profile='vm', source_fixture=False):
    source, files, _ = content(repo, ref, parent_raw, parent_pin, profile, source_fixture)
    timestamp = int(git(repo, 'show', '-s', '--format=%ct', source))
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode='wb', filename='', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.USTAR_FORMAT) as tar:
            directories = {str(p) for name in files for p in PurePosixPath(name).parents if str(p) != '.'}
            for path in sorted(directories):
                entry = tarfile.TarInfo(path + '/')
                entry.type, entry.mode, entry.mtime = tarfile.DIRTYPE, 0o700, timestamp
                tar.addfile(entry)
            for path, (mode, data) in sorted(files.items()):
                entry = tarfile.TarInfo(path)
                entry.mode, entry.size, entry.mtime = mode, len(data), timestamp
                tar.addfile(entry, io.BytesIO(data))
    raw = buffer.getvalue()
    # Validate bounds and the entire resulting contract before creating output.
    validate_series(raw, digest(raw), profile, repo)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    path = output / ('hg-owner-series-' + profile + '-' + source + '.tar.gz')
    checksum = path.with_suffix('.gz.sha256')
    for destination in (path, checksum):
        try:
            destination.lstat()
        except FileNotFoundError:
            continue
        raise FileExistsError('SERIES_OUTPUT_EXISTS: ' + str(destination))
    with path.open('xb') as target:
        target.write(raw)
    with checksum.open('x', encoding='ascii', newline='\n') as target:
        target.write(digest(raw) + '  ' + path.name + '\n')
    return path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', default='HEAD')
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--parent-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', choices=['vm', 'owner'], default='vm')
    parser.add_argument('--source-fixture', action='store_true')
    args = parser.parse_args()
    with args.parent.open('rb') as source_file:
        parent_raw = source_file.read(MAX_ARCHIVE + 1)
    print(build(ROOT, args.ref, parent_raw, args.parent_sha256, args.output, args.profile, args.source_fixture))
