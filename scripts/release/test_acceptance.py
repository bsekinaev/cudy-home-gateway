"""Stable acceptance gates use immutable Git evidence, never working-tree claims."""
import copy
import json
import unittest

from acceptance import GATES, validate
import test_build
from build import build


class AcceptanceTests(unittest.TestCase):
    git = test_build.BundleTests.git

    def setUp(self):
        test_build.BundleTests.setUp(self)
        for name in self.runtime[:3]:
            (self.repo / 'src' / name).chmod(0o755)

    def stable(self):
        (self.repo / 'src/usr/lib/home-gateway/common.sh').write_text("HG_VERSION='1.0.0'\n")
        self.git('add', 'src'); self.git('commit', '-qm', 'synthetic stable runtime')

    def record(self):
        return dict(schema_version=1, version='1.0.0',
                    runtime_tree=self.git('rev-parse', 'HEAD:src').decode().strip(),
                    gates={name: dict(status='PASS', scope=scope,
                         reference='https://github.com/bsekinaev/cudy-home-gateway/issues/7#issuecomment-1')
                         for name, scope in GATES.items()})

    def save(self, record):
        path = self.repo / 'docs/release-acceptance.json'
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(record))
        self.git('add', 'docs'); self.git('commit', '-qm', 'synthetic acceptance evidence')

    def test_stable_without_evidence_fails_before_artifact_creation(self):
        self.stable()
        with self.assertRaisesRegex(ValueError, 'STABLE_ACCEPTANCE_MISSING'):
            build(self.repo, 'HEAD', self.root / 'out')
        self.assertFalse((self.root / 'out').exists())

    def test_dev_runtime_under_stable_tag_is_rejected(self):
        self.git('tag', 'v1.0.0')
        with self.assertRaisesRegex(ValueError, 'STABLE_TAG_RUNTIME_VERSION_MISMATCH'):
            build(self.repo, 'v1.0.0', self.root / 'out')

    def test_head_and_sha_cannot_bypass_stable_tag_version_mismatch(self):
        self.stable(); self.save(self.record())
        self.git('tag', '-a', 'v1.0.1', '-m', 'synthetic mismatched stable tag')
        for ref in ('HEAD', self.git('rev-parse', 'HEAD').decode().strip()):
            with self.subTest(ref=ref), self.assertRaisesRegex(ValueError, 'STABLE_TAG_RUNTIME_VERSION_MISMATCH'):
                build(self.repo, ref, self.root / 'out')
        self.assertFalse((self.root / 'out').exists())

    def test_every_critical_gate_must_pass_in_required_scope(self):
        self.stable(); record = self.record()
        for gate in GATES:
            for field, bad in (('status', 'BLOCKED'), ('scope', 'HOST_TEST'), ('reference', '')):
                mutated = copy.deepcopy(record); mutated['gates'][gate][field] = bad
                with self.subTest(gate=gate, field=field), self.assertRaises(ValueError):
                    validate(mutated, '1.0.0', record['runtime_tree'])

    def test_bound_runtime_drift_is_rejected(self):
        self.stable(); self.save(self.record())
        (self.repo / 'src/usr/bin/gateway').write_text('#!/bin/sh\nexit 1\n')
        self.git('add', 'src'); self.git('commit', '-qm', 'changed runtime')
        with self.assertRaisesRegex(ValueError, 'STABLE_ACCEPTANCE_RUNTIME_IDENTITY'):
            build(self.repo, 'HEAD', self.root / 'out')

    def test_uncommitted_evidence_cannot_enable_stable(self):
        self.stable()
        path = self.repo / 'docs/release-acceptance.json'; path.parent.mkdir()
        path.write_text(json.dumps(self.record()))
        with self.assertRaisesRegex(ValueError, 'STABLE_ACCEPTANCE_MISSING'):
            build(self.repo, 'HEAD', self.root / 'out')

    def test_synthetic_complete_evidence_allows_exact_runtime_only(self):
        self.stable(); self.save(self.record())
        self.assertTrue(build(self.repo, 'HEAD', self.root / 'out').is_file())

    def test_missing_extra_and_duplicate_gate_keys_fail(self):
        self.stable(); record = self.record()
        del record['gates']['soak']; self.save(record)
        with self.assertRaisesRegex(ValueError, 'STABLE_ACCEPTANCE_INCOMPLETE'):
            build(self.repo, 'HEAD', self.root / 'out')
        raw = json.dumps(self.record()).replace('"status": "PASS"', '"status": "BLOCKED", "status": "PASS"', 1)
        path = self.repo / 'docs/release-acceptance.json'; path.write_text(raw)
        self.git('add', 'docs'); self.git('commit', '-qm', 'duplicate evidence key')
        with self.assertRaisesRegex(ValueError, 'STABLE_ACCEPTANCE_SCHEMA'):
            build(self.repo, 'HEAD', self.root / 'out')


if __name__ == '__main__': unittest.main()
