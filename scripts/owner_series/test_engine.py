"""Native intent and immutable receipt contracts; lifecycle is tested in QEMU."""
import json
from pathlib import Path
import shutil
import subprocess
import unittest

MODULE = Path(__file__).with_name('engine.uc')


@unittest.skipUnless(shutil.which('ucode'), 'native ucode required')
class EngineTests(unittest.TestCase):
    def describe(self, kind, manifest, selected, operation='tx.' + 'a' * 32):
        self.assertTrue(MODULE.exists(), 'transactional engine missing')
        code = ('import { describe_operation } from ' + json.dumps(str(MODULE.with_name('state.uc'))) + ';'
                'let d=json(ARGV[0]);print(sprintf("%J\\n",describe_operation(d.kind,d.id,d.manifest,d.selected,d.pin)));')
        return subprocess.run(['ucode', '-e', code, '--', json.dumps(dict(kind=kind, id=operation,
            manifest=manifest, selected=selected, pin='f' * 64))], capture_output=True, text=True, timeout=10)

    def test_first_apply_and_rollback_describe_distinct_immutable_operations(self):
        manifest = dict(source_commit='1' * 40, baseline_commit='d2039b6c62da3aa458f720af1c46fb619aee48dd')
        old = dict(generation='V1', transaction='tx.ud2039b6c62da3aa458f720af', source=manifest['baseline_commit'])
        result = self.describe('APPLY', manifest, old)
        self.assertEqual(result.returncode, 0, result.stderr)
        intent = json.loads(result.stdout)
        self.assertEqual(intent['after_generation'], 'tx.' + 'a' * 32)
        self.assertEqual(intent['before_generation'], 'V1')
        self.assertEqual(intent['after_source'], '1' * 40)
        selected = dict(generation=intent['id'], transaction=intent['id'], source='1' * 40,
                        parent_generation='V1', parent_transaction=old['transaction'])
        rolled = self.describe('ROLLBACK', manifest, selected, 'tx.' + 'b' * 32)
        self.assertEqual(rolled.returncode, 0, rolled.stderr)
        rollback = json.loads(rolled.stdout)
        self.assertEqual(rollback['before_generation'], intent['id'])
        self.assertEqual(rollback['after_generation'], 'V1')
        self.assertEqual(rollback['after_transaction'], old['transaction'])
        self.assertEqual(rollback['id'], 'tx.' + 'b' * 32)

    def test_wrong_baseline_or_invalid_identity_never_adopts_current_runtime(self):
        manifest = dict(source_commit='1' * 40, baseline_commit='2' * 40)
        selected = dict(generation='V1', transaction='tx.u' + 'd' * 24, source='3' * 40)
        for operation in ('tx.' + 'a' * 32, '../escape'):
            result = self.describe('APPLY', manifest, selected, operation)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('OWNER_SERIES_', result.stderr)

    def test_well_formed_but_wrong_after_identity_is_refused(self):
        manifest = dict(source_commit='1' * 40, baseline_commit='d2039b6c62da3aa458f720af1c46fb619aee48dd')
        old = dict(generation='V1', transaction='tx.ud2039b6c62da3aa458f720af', source=manifest['baseline_commit'])
        result = self.describe('APPLY', manifest, old)
        self.assertEqual(result.returncode, 0, result.stderr)
        intent = json.loads(result.stdout)
        intent['before_latest'] = 'V1'
        intent['after_source'] = '0' * 40
        code = ('import { validate_operation_intent } from ' + json.dumps(str(MODULE.with_name('state.uc'))) + ';'
                'let d=json(ARGV[0]);validate_operation_intent(d.intent,d.manifest,d.pin);')
        result = subprocess.run(['ucode', '-e', code, '--', json.dumps(dict(intent=intent, manifest=manifest, pin='f' * 64))],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('OWNER_SERIES_STATE_', result.stderr)


if __name__ == '__main__':
    unittest.main()
