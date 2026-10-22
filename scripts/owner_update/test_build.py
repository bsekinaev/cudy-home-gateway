"""Release boundaries for the deliberately non-production update candidate."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from build_kit import BASELINE, DELTA, PATHS, ROOT, build, content, validate_acceptance, git


class OwnerUpdateBuildTests(unittest.TestCase):
    def test_exact_inventory_and_single_runtime_delta(self):
        commit, files, manifest = content(ROOT, 'HEAD')
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
        _, _, manifest = content(ROOT, 'HEAD')
        self.assertEqual(manifest['profile'], 'VM_ONLY')
        self.assertIs(manifest['production_apply'], False)
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_REQUIRED'):
            content(ROOT, 'HEAD', 'owner')
        with self.assertRaisesRegex(ValueError, 'OWNER_ACCEPTANCE_CI_REVIEW_SOURCE'):
            content(ROOT, 'HEAD', 'owner', b'{}')

    def test_zero_change_cannot_be_relabelled_update(self):
        with self.assertRaisesRegex(ValueError, 'TELEGRAM_ONLY_DELTA_REQUIRED'):
            content(ROOT, BASELINE)

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
            a = build(ROOT, 'HEAD', Path(d) / 'a')
            b = build(ROOT, 'HEAD', Path(d) / 'b')
            self.assertEqual(a.read_bytes(), b.read_bytes())
            manifest = json.loads((a.parent / 'manifest.json').read_bytes())
            self.assertFalse(manifest['production_apply'])
            with self.assertRaises(FileExistsError):
                build(ROOT, 'HEAD', a.parent)


if __name__ == '__main__':
    unittest.main()
