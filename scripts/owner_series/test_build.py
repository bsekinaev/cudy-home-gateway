"""Packaging contracts using committed, non-executable host-only fixtures."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_archive import packed
import tarfile

from build_kit import build, content, validate_series

ROOT = Path(__file__).resolve().parents[2]
ACCEPTED = 'd2039b6c62da3aa458f720af1c46fb619aee48dd'


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE)


def repack(files, manifest):
    files = dict(files)
    files['manifest.json'] = (0o600, json.dumps(manifest).encode())
    parents = {str(p) for name in files for p in PurePosixPath(name).parents if str(p) != '.'}
    entries = [(p + '/', b'', tarfile.DIRTYPE, 0o700) for p in sorted(parents)]
    entries += [(p, body, tarfile.REGTYPE, mode) for p, (mode, body) in sorted(files.items())]
    raw = packed(entries)
    return raw, hashlib.sha256(raw).hexdigest()


class BuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.repo = cls.base / 'source'
        subprocess.run(['git', '-c', 'core.autocrlf=false', 'clone', '--quiet', '--shared', str(ROOT), str(cls.repo)],
                       check=True, capture_output=True)
        git(cls.repo, 'config', 'user.name', 'Packaging Fixture')
        git(cls.repo, 'config', 'user.email', 'fixture@example.invalid')
        git(cls.repo, 'config', 'core.autocrlf', 'false')
        # Builder dependencies are source-bound even during pre-commit TDD.
        for name in ('archive.py', 'parent.py', 'build_kit.py'):
            source = ROOT / 'scripts/owner_series' / name
            if source.exists():
                shutil.copyfile(source, cls.repo / 'scripts/owner_series' / name)
        for name in ('protocol.uc', 'state.uc', 'engine.uc', 'watch.uc', 'boot.init', 'owner.ps1'):
            (cls.repo / 'scripts/owner_series' / name).write_bytes(b'HOST PACKAGING FIXTURE ONLY\n')
        (cls.repo / 'scripts/owner_series/boot.init').chmod(0o755)
        git(cls.repo, 'add', 'scripts/owner_series')
        git(cls.repo, 'update-index', '--chmod=+x', 'scripts/owner_series/boot.init')
        git(cls.repo, 'commit', '--quiet', '-m', 'Host-only packaging fixture; never execute')
        cls.source = git(cls.repo, 'rev-parse', 'HEAD').decode().strip()
        bootstrap_source = cls.base / 'bootstrap-source'
        subprocess.run(['git', 'clone', '--quiet', '--shared', '--no-checkout', str(ROOT), str(bootstrap_source)],
                       check=True, capture_output=True)
        git(bootstrap_source, 'checkout', '--quiet', '--detach', ACCEPTED)
        output = cls.base / 'bootstrap-kit'
        subprocess.run([sys.executable, str(bootstrap_source / 'scripts/owner_update/build_kit.py'),
                        '--ref', ACCEPTED, '--output', str(output)], check=True, capture_output=True)
        cls.bootstrap = next(output.glob('*.tar.gz')).read_bytes()
        cls.pin = hashlib.sha256(cls.bootstrap).hexdigest()

    def candidate(self, **kwargs):
        return content(self.repo, self.source, self.bootstrap, self.pin, source_fixture=True, **kwargs)

    def variant(self, edit):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        repo = Path(temporary.name) / 'source'
        subprocess.run(['git', '-c', 'core.autocrlf=false', 'clone', '--quiet', '--shared',
                        str(self.repo), str(repo)], check=True, capture_output=True)
        git(repo, 'config', 'user.name', 'Packaging Fixture')
        git(repo, 'config', 'user.email', 'fixture@example.invalid')
        edit(repo)
        git(repo, 'add', '--all')
        git(repo, 'commit', '--quiet', '-m', 'Host-only adversarial packaging fixture')
        return repo

    def test_candidate_binds_all_runtime_and_parent_identity(self):
        source, files, manifest = self.candidate()
        self.assertEqual(source, self.source)
        self.assertEqual(manifest['format'], 'HG_OWNER_UPDATE_V2')
        self.assertEqual(manifest['baseline_commit'], ACCEPTED)
        self.assertEqual(manifest['changed'], ['usr/lib/home-gateway/telegram-poller.uc'])
        self.assertEqual(len(manifest['inventories']['candidate']), 20)
        self.assertEqual(len(manifest['controls']), 14)
        self.assertEqual(manifest['parent']['archive_sha256'], self.pin)
        self.assertEqual(files['bootstrap.tar.gz'][1], self.bootstrap)
        self.assertEqual(manifest['profile'], 'VM_ONLY')
        self.assertIs(manifest['production_apply'], False)
        self.assertIs(manifest['source_fixture'], True)

    def test_owner_output_stays_closed_until_native_acceptance_exists(self):
        with self.assertRaisesRegex(ValueError, 'OWNER_SOURCE_FIXTURE'):
            self.candidate(profile='owner')

    def test_owner_requires_acceptance_and_exact_owner_bootstrap(self):
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_REQUIRED'):
            content(self.repo, self.source, self.bootstrap, self.pin, profile='owner')
        with self.assertRaisesRegex(ValueError, 'PARENT_OWNER_PIN'):
            content(self.repo, self.source, self.bootstrap, self.pin, profile='owner', acceptance=b'{}')

    def test_owner_inventory_roundtrip_and_profile_separation_in_memory(self):
        # Isolate V2 packaging from the independently tested immutable V1 gate.
        import build_kit
        from parent import validate_parent
        bootstrap = validate_parent(self.bootstrap, self.pin, 'vm', self.repo)
        with patch.object(build_kit, 'validate_parent', return_value=bootstrap), patch.object(
                build_kit, 'validate_acceptance', return_value={}):
            _, files, manifest = content(self.repo, self.source, self.bootstrap, self.pin,
                                         profile='owner', acceptance=b'{"test_fixture":true}')
            self.assertEqual(manifest['profile'], 'OWNER_MANUAL')
            self.assertIs(manifest['production_apply'], True)
            self.assertIs(manifest['source_fixture'], False)
            self.assertEqual(files['acceptance.json'][0], 0o600)
            raw, pin = repack(files, manifest)
            self.assertEqual(validate_series(raw, pin, 'owner', self.repo)['manifest'], manifest)
            with self.assertRaisesRegex(ValueError, 'SERIES_MANIFEST'):
                validate_series(raw, pin, 'vm', self.repo)
            fixture_manifest = json.loads(json.dumps(manifest))
            fixture_manifest['source_fixture'] = True
            fixture_raw, fixture_pin = repack(files, fixture_manifest)
            with self.assertRaisesRegex(ValueError, 'SERIES_MANIFEST'):
                content(self.repo, self.source, fixture_raw, fixture_pin,
                        profile='owner', acceptance=b'{"test_fixture":true}')
            manifest['source_fixture'] = True
            raw, pin = repack(files, manifest)
            with self.assertRaisesRegex(ValueError, 'SERIES_MANIFEST'):
                validate_series(raw, pin, 'owner', self.repo)

    def test_wrong_ref_and_dirty_source_refused(self):
        with self.assertRaisesRegex(ValueError, 'SOURCE_CHECKOUT_MISMATCH'):
            content(self.repo, ACCEPTED, self.bootstrap, self.pin)
        path = self.repo / 'src/usr/lib/home-gateway/status.sh'
        original = path.read_bytes()
        try:
            path.write_bytes(original + b'\n# uncommitted\n')
            with self.assertRaisesRegex(ValueError, 'SOURCE_DIRTY'):
                self.candidate()
        finally:
            path.write_bytes(original)

    def test_reproducible_closed_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            a = build(self.repo, self.source, self.bootstrap, self.pin, Path(temporary) / 'a', source_fixture=True)
            b = build(self.repo, self.source, self.bootstrap, self.pin, Path(temporary) / 'b', source_fixture=True)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            p = validate_series(a.read_bytes(), hashlib.sha256(a.read_bytes()).hexdigest(), 'vm', self.repo)
            self.assertEqual(p['manifest']['source_commit'], self.source)

    def test_next_generation_carries_bootstrap_once_and_inherits_fixture_label(self):
        first = build(self.repo, self.source, self.bootstrap, self.pin, self.base / 'first', source_fixture=True)
        raw = first.read_bytes()
        path = self.repo / 'src/usr/lib/home-gateway/status.sh'
        original = path.read_bytes()
        try:
            path.write_bytes(original + b'\n# second host packaging fixture\n')
            git(self.repo, 'add', 'src/usr/lib/home-gateway/status.sh')
            git(self.repo, 'commit', '--quiet', '-m', 'Second host-only observer fixture')
            second = git(self.repo, 'rev-parse', 'HEAD').decode().strip()
            second_package = build(self.repo, second, raw, hashlib.sha256(raw).hexdigest(), self.base / 'second')
            second_raw = second_package.read_bytes()
            checked = validate_series(second_raw, hashlib.sha256(second_raw).hexdigest(), 'vm', self.repo)
            files, manifest = checked['files'], checked['manifest']
            self.assertEqual(files['bootstrap.tar.gz'][1], self.bootstrap)
            self.assertEqual(manifest['baseline_commit'], self.source)
            self.assertEqual(manifest['changed'], ['usr/lib/home-gateway/status.sh'])
            self.assertIs(manifest['source_fixture'], True)
            self.assertNotIn('parent.tar.gz', files)
            previous = json.loads(files['parent.json'][1])
            previous['files'] = []
            data = json.dumps(previous).encode()
            files['parent.json'] = (0o600, data)
            manifest['parent']['manifest_sha256'] = hashlib.sha256(data).hexdigest()
            for entry in manifest['files']:
                if entry['path'] == 'parent.json':
                    entry.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
            forged_raw, forged_pin = repack(files, manifest)
            with self.assertRaisesRegex(ValueError, 'SERIES_PRIOR_INVENTORY'):
                validate_series(forged_raw, forged_pin, 'vm', self.repo)
        finally:
            git(self.repo, 'reset', '--hard', self.source)

    def test_rehashed_forged_parent_link_is_rejected(self):
        _, files, manifest = self.candidate()
        manifest['parent']['source_commit'] = '0' * 40
        raw, pin = repack(files, manifest)
        with self.assertRaisesRegex(ValueError, 'SERIES_PARENT_LINK'):
            validate_series(raw, pin, 'vm', self.repo)

    def test_wrong_nested_parent_shape_is_a_validation_refusal(self):
        _, files, manifest = self.candidate()
        previous = json.loads(files['parent.json'][1])
        previous['inventories'] = []
        data = json.dumps(previous).encode()
        files['parent.json'] = (0o600, data)
        manifest['parent']['manifest_sha256'] = hashlib.sha256(data).hexdigest()
        for entry in manifest['files']:
            if entry['path'] == 'parent.json':
                entry.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        raw, pin = repack(files, manifest)
        with self.assertRaisesRegex(ValueError, 'SERIES_PARENT_LINK'):
            validate_series(raw, pin, 'vm', self.repo)

    def test_non_observer_change_and_unknown_runtime_file_refused(self):
        for name in ('src/usr/bin/gateway', 'src/usr/lib/home-gateway/unexpected.sh'):
            def edit(repo):
                path = repo / name
                path.write_bytes((path.read_bytes() if path.exists() else b'') + b'\n# fixture\n')
            repo = self.variant(edit)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'SERIES_(OBSERVER_DELTA_REQUIRED|RUNTIME_INVENTORY)'):
                content(repo, 'HEAD', self.bootstrap, self.pin, source_fixture=True)

    def test_control_changes_refused(self):
        def edit(repo):
            path = repo / 'scripts/deploy/migration-state.uc'
            path.write_bytes(path.read_bytes() + b'\n// fixture\n')
        repo = self.variant(edit)
        with self.assertRaisesRegex(ValueError, 'SERIES_CONTROLS'):
            content(repo, 'HEAD', self.bootstrap, self.pin, source_fixture=True)

    def test_modified_builder_dependency_refused(self):
        def edit(repo):
            path = repo / 'scripts/owner_series/archive.py'
            path.write_bytes(path.read_bytes() + b'\n# fixture\n')
        repo = self.variant(edit)
        with self.assertRaisesRegex(ValueError, 'SOURCE_DEPENDENCY_DRIFT'):
            content(repo, 'HEAD', self.bootstrap, self.pin, source_fixture=True)

    def test_controller_mode_and_size_are_validated_before_packaging(self):
        for mode in ('mode', 'size'):
            def edit(repo):
                path = repo / 'scripts/owner_series/engine.uc'
                if mode == 'mode':
                    path.chmod(0o755)
                    git(repo, 'update-index', '--chmod=+x', 'scripts/owner_series/engine.uc')
                else:
                    path.write_bytes(b'x' * 262145)
            repo = self.variant(edit)
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, 'SERIES_CONTROLLER_(MODE|TEXT)'):
                content(repo, 'HEAD', self.bootstrap, self.pin, source_fixture=True)

    def test_zero_runtime_delta_refused_even_for_new_source_commit(self):
        first = build(self.repo, self.source, self.bootstrap, self.pin, self.base / 'zero-parent', source_fixture=True)
        raw = first.read_bytes()
        repo = self.variant(lambda repo: (repo / 'HOST-FIXTURE.txt').write_text('No runtime changes\n'))
        with self.assertRaisesRegex(ValueError, 'SERIES_OBSERVER_DELTA_REQUIRED'):
            content(repo, 'HEAD', raw, hashlib.sha256(raw).hexdigest(), source_fixture=True)

    def test_occupied_checksum_output_is_never_overwritten(self):
        for kind in ('ordinary', 'symlink'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                sentinel = directory / 'sentinel'
                sentinel.write_bytes(b'KEEP THIS FILE\n')
                output = directory / 'output'
                output.mkdir()
                archive = output / ('hg-owner-series-vm-' + self.source + '.tar.gz')
                checksum = archive.with_suffix('.gz.sha256')
                if kind == 'symlink':
                    try:
                        checksum.symlink_to(sentinel)
                    except OSError:
                        self.skipTest('symlink creation unavailable; exercised in Linux CI')
                else:
                    checksum.write_bytes(b'EXISTING CHECKSUM\n')
                with self.assertRaises(FileExistsError):
                    build(self.repo, self.source, self.bootstrap, self.pin, output, source_fixture=True)
                self.assertEqual(sentinel.read_bytes(), b'KEEP THIS FILE\n')
                self.assertEqual(checksum.read_bytes(), b'KEEP THIS FILE\n' if kind == 'symlink' else b'EXISTING CHECKSUM\n')
                self.assertFalse(archive.exists())

    def test_fabricated_v2_parent_witness_is_rejected(self):
        _, files, manifest = self.candidate()
        previous = json.loads(json.dumps(manifest))
        previous.update(source_commit=ACCEPTED, baseline_commit='0' * 40, changed=[], files=[])
        previous['inventories']['candidate'] = manifest['inventories']['baseline']
        data = json.dumps(previous).encode()
        files['parent.json'] = (0o600, data)
        manifest['parent'].update(format='HG_OWNER_UPDATE_V2', archive_sha256='0' * 64,
                                  manifest_sha256=hashlib.sha256(data).hexdigest())
        for entry in manifest['files']:
            if entry['path'] == 'parent.json':
                entry.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        raw, pin = repack(files, manifest)
        with self.assertRaisesRegex(ValueError, 'SERIES_'):
            validate_series(raw, pin, 'vm', self.repo)


if __name__ == '__main__':
    unittest.main()
