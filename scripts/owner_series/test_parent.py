"""Validate a real V1 bootstrap package built from the accepted Git source."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tempfile
import unittest

from test_archive import packed
import tarfile

from parent import validate_parent

ROOT = Path(__file__).resolve().parents[2]
ACCEPTED = 'd2039b6c62da3aa458f720af1c46fb619aee48dd'


class ParentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        checkout = Path(cls.temp.name) / 'source'
        subprocess.run(['git', 'clone', '--quiet', '--shared', '--no-checkout',
                        str(ROOT), str(checkout)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(checkout), 'checkout', '--quiet', '--detach', ACCEPTED],
                       check=True, capture_output=True)
        output = Path(cls.temp.name) / 'kit'
        subprocess.run([sys.executable, str(checkout / 'scripts/owner_update/build_kit.py'),
                        '--ref', ACCEPTED, '--output', str(output)], check=True, capture_output=True)
        cls.raw = next(output.glob('*.tar.gz')).read_bytes()
        cls.pin = hashlib.sha256(cls.raw).hexdigest()

    def test_accepts_exact_vm_bootstrap_and_exposes_parent_identity(self):
        parent = validate_parent(self.raw, self.pin, 'vm', ROOT)
        self.assertEqual(parent['manifest']['source_commit'], ACCEPTED)
        self.assertEqual(len(parent['manifest']['inventories']['candidate']), 20)
        self.assertEqual(len(parent['manifest']['controls']), 14)
        self.assertEqual(parent['manifest_sha256'], hashlib.sha256(parent['files']['manifest.json'][1]).hexdigest())

    def test_vm_bootstrap_cannot_be_used_for_owner(self):
        with self.assertRaisesRegex(ValueError, 'PARENT_OWNER_PIN'):
            validate_parent(self.raw, self.pin, 'owner', ROOT)

    def test_archive_digest_is_mandatory(self):
        with self.assertRaisesRegex(ValueError, 'ARCHIVE_DIGEST'):
            validate_parent(self.raw, '0' * 64, 'vm', ROOT)

    def changed(self, mutate):
        from archive import read_archive
        files = read_archive(self.raw, self.pin)
        manifest = json.loads(files['manifest.json'][1])
        mutate(files, manifest)
        files['manifest.json'] = (0o600, json.dumps(manifest).encode())
        directories = {str(p) for path in files for p in PurePosixPath(path).parents if str(p) != '.'}
        entries = [(p + '/', b'', tarfile.DIRTYPE, 0o700) for p in sorted(directories)]
        entries += [(p, data, tarfile.REGTYPE, mode) for p, (mode, data) in sorted(files.items())]
        raw = packed(entries)
        return raw, hashlib.sha256(raw).hexdigest()

    def test_unknown_and_missing_files_rejected(self):
        for mutate in (lambda f, m: f.update({'unexpected': (0o600, b'x')}),
                       lambda f, m: f.pop('watch.uc')):
            raw, pin = self.changed(mutate)
            with self.assertRaisesRegex(ValueError, 'PARENT_INVENTORY'):
                validate_parent(raw, pin, 'vm', ROOT)

    def test_file_tampering_rejected_even_with_valid_archive_pin(self):
        raw, pin = self.changed(lambda f, m: f.update({'watch.uc': (0o600, b'tampered')}))
        with self.assertRaisesRegex(ValueError, 'PARENT_FILE_PIN'):
            validate_parent(raw, pin, 'vm', ROOT)

    def test_forged_source_runtime_and_control_claims_rejected(self):
        mutations = [lambda f, m: m.update(source_commit='0' * 40),
                     lambda f, m: m['controls'].update({'etc/init.d/home-gateway-migration': '0' * 64}),
                     lambda f, m: m['inventories']['candidate'].update({'usr/bin/gateway': '0' * 64})]
        for mutate in mutations:
            raw, pin = self.changed(mutate)
            with self.assertRaisesRegex(ValueError, 'PARENT_(SOURCE|CONTROLS|RUNTIME)'):
                validate_parent(raw, pin, 'vm', ROOT)

    def test_manifest_inventory_duplicates_and_boolean_size_rejected(self):
        for mutate in (lambda f, m: m['files'].append(m['files'][0]),
                       lambda f, m: m['files'][0].update(size=True)):
            raw, pin = self.changed(mutate)
            with self.assertRaisesRegex(ValueError, 'PARENT_(INVENTORY|FILE_PIN)'):
                validate_parent(raw, pin, 'vm', ROOT)

    def test_rehashed_helper_still_must_match_accepted_source(self):
        def forge(files, manifest):
            files['watch.uc'] = (0o600, b'tampered')
            for entry in manifest['files']:
                if entry['path'] == 'watch.uc':
                    entry.update(size=8, sha256=hashlib.sha256(b'tampered').hexdigest())
        raw, pin = self.changed(forge)
        with self.assertRaisesRegex(ValueError, 'PARENT_HELPER_SOURCE'):
            validate_parent(raw, pin, 'vm', ROOT)

    def test_duplicate_json_keys_and_nonstandard_constants_rejected(self):
        from parent import strict_json
        for raw in (b'{"files":[],"files":[]}', b'{"a":NaN}', b'{"a":Infinity}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                strict_json(raw)


if __name__ == '__main__':
    unittest.main()
