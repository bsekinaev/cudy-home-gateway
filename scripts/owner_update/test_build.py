"""Release boundaries for the deliberately non-production update candidate."""
import hashlib
import json
from pathlib import Path
import tempfile
import tarfile
import sys
import unittest
from unittest.mock import patch

from build_kit import BASELINE, DELTA, PATHS, ROOT, build, content, validate_acceptance, git


class OwnerUpdateBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # V1's positive packaging tests retain its historical Telegram-only
        # runtime scope; current backend observations are accepted by V2 tests.
        sys.path.insert(0, str(ROOT / 'scripts/openwrt'))
        import run_vm
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        commit = git(ROOT, 'rev-parse', 'HEAD').decode().strip()
        cls.fixture, _ = run_vm.owner_update_fixture(commit, Path(cls.temporary.name))

    def test_selected_ref_must_match_checkout(self):
        with self.assertRaisesRegex(ValueError, 'SOURCE_CHECKOUT_MISMATCH'):
            content(ROOT, BASELINE)

    def test_oversize_acceptance_is_rejected_before_parsing(self):
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_SIZE'):
            validate_acceptance(b' ' * 262145, 'unused', ROOT)

    def test_exact_limit_acceptance_reaches_semantic_validation(self):
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_CI_REVIEW_SOURCE'):
            validate_acceptance(b'{}' + b' ' * 262142, 'unused', ROOT)

    def test_modified_inventory_dependency_is_rejected(self):
        original = Path.read_bytes
        def changed(path):
            data = original(path)
            return data + b'\n# local edit\n' if path == ROOT / 'scripts/deploy/transport.py' else data
        with patch.object(Path, 'read_bytes', changed):
            with self.assertRaisesRegex(ValueError, 'SOURCE_DEPENDENCY_DRIFT'):
                content(ROOT, 'HEAD')

    def test_exact_inventory_and_single_runtime_delta(self):
        commit, files, manifest = content(self.fixture, 'HEAD')
        self.assertEqual(manifest['changed'], [DELTA])
        self.assertEqual(manifest['baseline_commit'], BASELINE)
        self.assertEqual(manifest['source_commit'], commit)
        for name in ('baseline', 'candidate'):
            self.assertEqual(set(manifest['inventories'][name]), set(PATHS))
            for path in PATHS:
                self.assertEqual(manifest['inventories'][name][path],
                                 hashlib.sha256(files[name + '/' + path][1]).hexdigest())
        self.assertEqual(len(manifest['controls']), 14)

    def test_default_is_vm_and_owner_requires_acceptance(self):
        _, _, manifest = content(self.fixture, 'HEAD')
        self.assertEqual(manifest['profile'], 'VM_ONLY')
        self.assertIs(manifest['production_apply'], False)
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_REQUIRED'):
            content(self.fixture, 'HEAD', 'owner')
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_CI_REVIEW_SOURCE'):
            content(self.fixture, 'HEAD', 'owner', b'{}')

    def test_zero_change_cannot_be_relabelled_update(self):
        commit = git(ROOT, 'rev-parse', 'HEAD').decode().strip()
        with patch('build_kit.BASELINE', commit):
            with self.assertRaisesRegex(ValueError, 'TELEGRAM_ONLY_DELTA_REQUIRED'):
                content(ROOT, 'HEAD')

    def test_owner_acceptance_rejects_incomplete_vm_and_wrong_source(self):
        commit = git(ROOT, 'rev-parse', 'HEAD').decode().strip()
        a = dict(format='HG_OWNER_UPDATE_ACCEPTANCE_V1', commit=commit,
                 ci_head=commit, ci_conclusion='success', review_head=commit, review_blockers=0,
                 ci_url='https://github.com/bsekinaev/cudy-home-gateway/actions/runs/1', report={})
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_VM_INCOMPLETE'):
            validate_acceptance(json.dumps(a).encode(), commit, ROOT)
        a['review_head'] = BASELINE
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_CI_REVIEW_SOURCE'):
            validate_acceptance(json.dumps(a).encode(), commit, ROOT)

    def test_immutable_reproducible_bundle(self):
        with tempfile.TemporaryDirectory() as d:
            a = build(self.fixture, 'HEAD', Path(d) / 'a')
            b = build(self.fixture, 'HEAD', Path(d) / 'b')
            self.assertEqual(a.read_bytes(), b.read_bytes())
            with tarfile.open(a) as archive:
                self.assertTrue(all('\\' not in m.name for m in archive))
            manifest = json.loads((a.parent / 'manifest.json').read_bytes())
            self.assertFalse(manifest['production_apply'])
            with self.assertRaises(FileExistsError):
                build(self.fixture, 'HEAD', a.parent)


if __name__ == '__main__':
    unittest.main()
