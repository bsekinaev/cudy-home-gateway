import json
import subprocess
import unittest
from pathlib import Path

INCIDENTS = Path(__file__).resolve().parents[2] / 'src/usr/lib/home-gateway/incidents.uc'


class RecoveryReviewTests(unittest.TestCase):
    def test_decision_requires_valid_independent_live_checks(self):
        snapshot = {
            'observation': {'valid': True},
            'components': {'wan': {'state': 'OK'}, 'main': {'state': 'DEGRADED'}},
            'external_evidence': {
                'direct_egress': {'state': 'OK', 'freshness': 'live'},
                'main_egress': {'state': 'UNKNOWN', 'freshness': 'live',
                                'secondary_attempted': True},
            },
        }
        main = snapshot['external_evidence']['main_egress']
        cases = [
            ({}, {}, True, 'REVIEW_CANDIDATES'),
            ({'freshness': 'cached'}, {}, True, 'INSUFFICIENT_EVIDENCE'),
            ({'secondary_attempted': False}, {}, True, 'INSUFFICIENT_EVIDENCE'),
            ({}, {'state': 'DOWN'}, True, 'WAIT_FOR_WAN'),
            ({}, {}, False, 'INSUFFICIENT_EVIDENCE'),
        ]
        for evidence, wan, valid, expected in cases:
            with self.subTest(expected=expected):
                sample = {
                    **snapshot,
                    'observation': {'valid': valid},
                    'components': {**snapshot['components'], 'wan': {'state': 'OK', **wan}},
                    'external_evidence': {**snapshot['external_evidence'],
                                          'main_egress': {**main, **evidence}},
                }
                result = subprocess.run(
                    ['ucode', str(INCIDENTS), '/usr/bin/gateway', 'recovery-review'],
                    input=json.dumps(sample), text=True, capture_output=True,
                    check=True, timeout=5,
                )
                output = json.loads(result.stdout)
                self.assertEqual(output['decision'], expected)
                self.assertFalse(output['changes_applied'])

    def test_order_accepts_only_fresh_matching_reports_and_allowed_nodes(self):
        import time

        context = 'b' * 64
        finished = int(time.time()) - 1
        expected_receipt = {
            'provider_sha256': 'd' * 64,
            'summary_sha256': 'e' * 64,
            'boot_id': 'a555b4ed-9243-42a1-bf90-ae17f7f94f39',
        }
        receipt = {
            **expected_receipt, 'schema_version': 1, 'exit_code': 0,
            'run_id': '20261127-010059', 'started_at': finished - 10,
            'finished_at': finished, 'context_before': context, 'context_after': context,
        }
        report = {
            'schema_version': 1,
            'complete': True,
            'context': context,
            'generated_at': finished,
            'receipt': receipt,
            'ranked': [
                {'id': 'outside', 'eligible': True},
                {'id': 'second', 'eligible': True},
                {'id': 'first', 'eligible': False},
            ],
        }
        for override, expected, source in (
            ({}, ['second', 'first'], 'vtest'),
            ({'generated_at': 1}, ['first', 'second'], 'configured'),
            ({'context': 'c' * 64}, ['first', 'second'], 'configured'),
            ({'complete': False}, ['first', 'second'], 'configured'),
            ({'receipt': None}, ['first', 'second'], 'configured'),
            ({'receipt': {**receipt, 'context_after': 'f' * 64}}, ['first', 'second'], 'configured'),
            ({'receipt': {**receipt, 'provider_sha256': 'f' * 64}}, ['first', 'second'], 'configured'),
            ({'receipt': {**receipt, 'summary_sha256': 'f' * 64}}, ['first', 'second'], 'configured'),
            ({'receipt': {**receipt, 'exit_code': 1}}, ['first', 'second'], 'configured'),
            ({'ranked': report['ranked'] * 2}, ['first', 'second'], 'configured'),
        ):
            with self.subTest(override=override):
                sample = {'schema_version': 1, 'context': context, 'expected': expected_receipt,
                          'allowed': ['first', 'second'], 'report': {**report, **override}}
                result = subprocess.run(
                    ['ucode', str(INCIDENTS), '/usr/bin/gateway', 'recovery-order'],
                    input=json.dumps(sample), text=True, capture_output=True,
                    timeout=5, check=True,
                )
                data = json.loads(result.stdout)
                self.assertEqual(data['order'], expected)
                self.assertEqual(data['source'], source)
