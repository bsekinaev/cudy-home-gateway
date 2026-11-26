import json
import subprocess
import unittest
from pathlib import Path

VPN = Path(__file__).resolve().parents[2] / 'src/usr/lib/home-gateway/vpn.sh'


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
                    ['busybox', 'ash', '-c', '. "$1"; hg_main_recovery_review',
                     'recovery-review', str(VPN)],
                    input=json.dumps(sample), text=True, capture_output=True,
                    check=True, timeout=5,
                )
                output = json.loads(result.stdout)
                self.assertEqual(output['decision'], expected)
                self.assertFalse(output['changes_applied'])
