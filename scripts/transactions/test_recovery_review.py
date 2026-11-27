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

    def test_lan_review_requires_matching_unconsumed_operation_and_successes(self):
        token = 'a' * 32
        expected = {'token': token, 'phase': 'VERIFYING', 'consumed': False,
                    'boot_id': 'current-boot', 'apply_uptime': 10, 'deadline_uptime': 35}
        checks = [
            {'Target': url, 'HTTP': '204', 'CurlExit': 0, 'Passed': True}
            for url in ('https://www.google.com/generate_204', 'https://cp.cloudflare.com/')
        ]
        receipt = {'schema_version': 1, 'token': token, 'checks': checks}
        sample = {'expected': expected, 'receipt': receipt,
                  'boot_id': 'current-boot', 'received_uptime': 20}
        for override, accepted in (
            ({}, True),
            ({'received_uptime': 36}, False),
            ({'received_uptime': 9}, False),
            ({'boot_id': 'new-boot'}, False),
            ({'expected': {**expected, 'consumed': True}}, False),
            ({'receipt': {**receipt, 'token': 'b' * 32}}, False),
            ({'receipt': {**receipt, 'checks': [checks[0], checks[0]]}}, False),
            ({'receipt': {**receipt, 'checks': [checks[0], {**checks[1], 'HTTP': '500'}]}}, False),
        ):
            with self.subTest(override=override):
                result = subprocess.run(
                    ['ucode', str(INCIDENTS), '/usr/bin/gateway', 'lan-review'],
                    input=json.dumps({**sample, **override}), text=True, capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 0 if accepted else 2, result.stderr)
                self.assertEqual(json.loads(result.stdout)['accepted'], accepted)

    def test_transaction_waits_commits_or_rolls_back_without_overwriting_drift(self):
        token = 'a' * 32
        expected = {'phase': 'VERIFYING', 'token': token, 'consumed': False,
                    'before_sha256': '1' * 64, 'applied_sha256': '2' * 64,
                    'boot_id': 'boot', 'apply_uptime': 10, 'deadline_uptime': 35}
        receipt = {'schema_version': 1, 'token': token, 'checks': [
            {'Target': url, 'HTTP': '204', 'CurlExit': 0, 'Passed': True}
            for url in ('https://www.google.com/generate_204', 'https://cp.cloudflare.com/')
        ]}
        sample = {'expected': expected, 'receipt': receipt, 'socks': 'OK',
                  'boot_id': 'boot', 'received_uptime': 20, 'config_sha256': '2' * 64}
        for override, decision in (
            ({}, 'COMMIT'),
            ({'receipt': None}, 'WAIT_FOR_VERIFICATION'),
            ({'socks': 'FAILED'}, 'ROLLBACK'),
            ({'received_uptime': 36}, 'ROLLBACK'),
            ({'boot_id': 'reboot', 'received_uptime': 0}, 'ROLLBACK'),
            ({'config_sha256': '3' * 64, 'socks': 'FAILED'}, 'STOP_CONFIG_CONFLICT'),
            ({'expected': {**expected, 'consumed': True}}, 'INVALID_STATE'),
        ):
            with self.subTest(decision=decision):
                result = subprocess.run(
                    ['ucode', str(INCIDENTS), '/usr/bin/gateway', 'transaction-review'],
                    input=json.dumps({**sample, **override}), text=True, capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 2 if decision == 'INVALID_STATE' else 0,
                                 result.stderr)
                self.assertEqual(json.loads(result.stdout), {
                    'schema_version': 1, 'decision': decision, 'changes_applied': False,
                })
