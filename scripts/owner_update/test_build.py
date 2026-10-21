"""Release boundaries for the deliberately non-production update candidate."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from build_kit import BASELINE, DELTA, PATHS, ROOT, build, content


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

    def test_no_production_profile(self):
        _, _, manifest = content(ROOT, 'HEAD')
        self.assertEqual(manifest['profile'], 'VM_ONLY')
        self.assertIs(manifest['production_apply'], False)

    def test_zero_change_cannot_be_relabelled_update(self):
        with self.assertRaisesRegex(ValueError, 'TELEGRAM_ONLY_DELTA_REQUIRED'):
            content(ROOT, BASELINE)

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
