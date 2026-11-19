"""Release evidence validation; synthetic documents never authorize a release."""
import copy
import json
import unittest
from unittest.mock import patch

import build_kit as builder


class AcceptanceTests(unittest.TestCase):
    def evidence(self):
        source = 'a' * 40
        report = dict(commit=source, scenario='owner-series', status='PASS', failed=0,
                      total=1, checks={'native_check': 'PASS'}, scope='ISOLATED_X86_NOT_CUDY',
                      production_supported=False, kernel_sha256='kernel', rootfs_sha256='rootfs',
                      package_sha256={'package': 'pin'}, network_devices=0, host_shared_directories=0,
                      reboot_mechanism='GUEST_REBOOT_SUPERVISED_COLD_BOOT', real_candidate_commit=source,
                      fixture_commit='b' * 40, fixture_scope='VM_ONLY_OBSERVER_COMMENT')
        return dict(format='HG_OWNER_SERIES_ACCEPTANCE_V1', commit=source, ci_head=source,
                    ci_conclusion='success', review_head=source, review_blockers=0,
                    ci_url='https://github.com/bsekinaev/cudy-home-gateway/actions/runs/123', report=report)

    def validate(self, value):
        def source(repo, operation, ref):
            if ref.endswith('guest-owner-series.sh'):
                return b'check native_check true\n'
            return b"KERNEL_SHA = 'kernel'\nROOTFS_SHA = 'rootfs'\nPACKAGE_SHA = {'package': 'pin'}\n"
        with patch.object(builder, 'git', side_effect=source):
            return builder.validate_acceptance(json.dumps(value).encode(), 'a' * 40, '.')

    def test_exact_complete_evidence(self):
        self.assertEqual(self.validate(self.evidence()), self.evidence())

    def test_incomplete_or_unbound_evidence_refused(self):
        original = self.evidence()
        mutations = [(key, value) for key, value in (
            ('commit', 'b' * 40), ('ci_head', 'b' * 40), ('ci_conclusion', 'failure'),
            ('review_head', 'b' * 40), ('review_blockers', False), ('ci_url', 'https://example.com/123'))]
        for key, value in mutations:
            bad = copy.deepcopy(original); bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.validate(bad)
        for key, value in [('failed', False), ('total', True), ('checks', {}), ('checks', {'native_check': 'FAIL'}),
                           ('production_supported', True), ('network_devices', False), ('host_shared_directories', 1),
                           ('kernel_sha256', 'other'), ('package_sha256', {}), ('fixture_commit', 'a' * 40),
                           ('real_candidate_commit', 'b' * 40), ('fixture_scope', 'OWNER'), ('reboot_mechanism', 'fake')]:
            bad = copy.deepcopy(original); bad['report'][key] = value
            with self.subTest(report=key), self.assertRaises(ValueError): self.validate(bad)

    def test_non_object_and_duplicate_json_refused(self):
        for raw in (None, '', b'', b'x' * 262145, b'[]', b'{"format":1,"format":2}'):
            with self.assertRaises(ValueError): builder.validate_acceptance(raw, 'a' * 40, '.')
