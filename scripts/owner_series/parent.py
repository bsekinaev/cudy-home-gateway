"""Authenticate the preserved V1 bootstrap from its closed Git source inventory.

This is the bootstrap boundary only; V2 parent support is added by the series
builder. No installation, extraction or router connection is performed here.
"""
import hashlib
import json
import subprocess

from archive import read_archive

ORIGINAL = '62592457237e7f026786c086d1ca6fdd4b6c095d'
ACCEPTED = 'd2039b6c62da3aa458f720af1c46fb619aee48dd'
OWNER_ARCHIVE = 'a39fb710909661d6c03c4f2f73f3b7645017b14a07999c80666de6735b926eed'
OWNER_MANIFEST = '430383e3b0bfff46fbee688068cfea4e1446ca4491d6ded83d67ef1179e6b0df'
PATHS = ['etc/init.d/home-gateway-telegram', 'usr/bin/gateway', 'usr/bin/home-gateway-ci-smoke'] + [
    'usr/lib/home-gateway/' + name for name in (
        'actions.uc', 'asata.sh', 'common.sh', 'dns.sh', 'doctor.sh', 'health.sh',
        'incidents.uc', 'network.sh', 'notifications.uc', 'redmi.sh', 'selftest.sh',
        'status.sh', 'tailscale.sh', 'telegram-poller.uc', 'telegram.sh', 'torrent.sh', 'vpn.sh')]
CONTROLS = [('engine.sh', 'usr/libexec/home-gateway-deploy/engine.sh'),
            ('wrapper.sh', 'usr/libexec/home-gateway-deploy/wrapper.sh'),
            ('recovery.init', 'etc/init.d/home-gateway-deploy-recover'),
            ('migration-boot.init', 'etc/init.d/home-gateway-migration'),
            ('migration-admission.sh', 'usr/libexec/home-gateway-deploy/migration-admission.sh')] + [
                ('migration-' + name + '.uc', 'usr/libexec/home-gateway-deploy/migration-' + name + '.uc')
                for name in ('state', 'snapshot', 'candidate', 'runtime', 'handoff',
                             'coordinator', 'controls', 'service', 'terminal')]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE)


def _object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError('PARENT_DUPLICATE_JSON_KEY')
        result[name] = value
    return result


def strict_json(raw):
    try:
        return json.loads(raw, object_pairs_hook=_object,
                          parse_constant=lambda value: (_ for _ in ()).throw(ValueError('PARENT_JSON_CONSTANT')))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError('PARENT_JSON') from error


def validate_parent(raw, pin, profile, repo):
    if profile not in ('vm', 'owner'):
        raise ValueError('PARENT_PROFILE')
    if profile == 'owner' and pin != OWNER_ARCHIVE:
        raise ValueError('PARENT_OWNER_PIN')
    files = read_archive(raw, pin)
    if 'manifest.json' not in files or files['manifest.json'][0] != 0o600:
        raise ValueError('PARENT_MANIFEST')
    manifest_raw = files['manifest.json'][1]
    manifest_pin = digest(manifest_raw)
    if profile == 'owner' and manifest_pin != OWNER_MANIFEST:
        raise ValueError('PARENT_OWNER_MANIFEST_PIN')
    m = strict_json(manifest_raw)
    if (not isinstance(m, dict) or m.get('format') != 'HG_OWNER_UPDATE_V1' or
            m.get('source_commit') != ACCEPTED or m.get('baseline_commit') != ORIGINAL):
        raise ValueError('PARENT_SOURCE')
    if (m.get('profile') != ('OWNER_MANUAL' if profile == 'owner' else 'VM_ONLY') or
            m.get('production_apply') is not (profile == 'owner')):
        raise ValueError('PARENT_PROFILE')
    helpers = {'update.sh': 0o700, 'inspect.uc': 0o600, 'owner.ps1': 0o600,
               'boot.init': 0o755, 'watch.uc': 0o600}
    expected = dict(helpers)
    expected.update({'baseline.sha256': 0o600, 'candidate.sha256': 0o600})
    for name in ('baseline', 'candidate'):
        expected.update({name + '/' + path: 0o755 if path in PATHS[:3] else 0o644 for path in PATHS})
    if profile == 'owner':
        expected['acceptance.json'] = 0o600
    inventory = m.get('files')
    if (set(files) != set(expected) | {'manifest.json'} or not isinstance(inventory, list) or
            len(inventory) != len(expected)):
        raise ValueError('PARENT_INVENTORY')
    seen = set()
    for entry in inventory:
        if (not isinstance(entry, dict) or set(entry) != {'path', 'mode', 'sha256', 'size'} or
                not isinstance(entry['path'], str) or entry['path'] not in expected or entry['path'] in seen):
            raise ValueError('PARENT_INVENTORY')
        path = entry['path']
        seen.add(path)
        mode, data = files[path]
        if (type(entry['mode']) is not int or type(entry['size']) is not int or
                entry['mode'] != mode or mode != expected[path] or entry['size'] != len(data) or
                entry['sha256'] != digest(data)):
            raise ValueError('PARENT_FILE_PIN')
    if seen != set(expected):
        raise ValueError('PARENT_INVENTORY')
    for path in helpers:
        if files[path][1] != git(repo, 'show', ACCEPTED + ':scripts/owner_update/' + path):
            raise ValueError('PARENT_HELPER_SOURCE')
    controls = {path: digest(git(repo, 'show', ORIGINAL + ':scripts/deploy/' + source))
                for source, path in CONTROLS}
    if m.get('controls') != controls:
        raise ValueError('PARENT_CONTROLS')
    inventories = {}
    for name, source in (('baseline', ORIGINAL), ('candidate', ACCEPTED)):
        hashes = {}
        for path in PATHS:
            data = git(repo, 'show', source + ':src/' + path)
            if files[name + '/' + path][1] != data:
                raise ValueError('PARENT_RUNTIME_SOURCE')
            hashes[path] = digest(data)
        if files[name + '.sha256'][1] != ''.join(hashes[p] + '  ' + p + '\n' for p in PATHS).encode():
            raise ValueError('PARENT_RUNTIME_MANIFEST')
        inventories[name] = hashes
    if m.get('inventories') != inventories or m.get('changed') != ['usr/lib/home-gateway/telegram-poller.uc']:
        raise ValueError('PARENT_RUNTIME_INVENTORY')
    return {'manifest': m, 'manifest_sha256': manifest_pin, 'archive_sha256': pin, 'files': files}
