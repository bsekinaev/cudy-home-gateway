"""Reject partial, duplicated or contradictory VM completion evidence."""
import unittest
from run_vm import parse_result, failure_report


class ReportTests(unittest.TestCase):
    def test_public_failure_code_without_private_exception_details(self):
        self.assertEqual(failure_report(ValueError('PACKAGE_INDEX_SHA256'))['reason'], 'PACKAGE_INDEX_SHA256')
        for message in ('/private/owner/archive', 'PRIVATE_TOKEN'):
            report = failure_report(ValueError(message))
            self.assertEqual(report['reason'], 'VALIDATION_ERROR')
            self.assertNotIn(message, str(report))
        self.assertEqual(failure_report(OSError('/private/path'))['reason'], 'IO_ERROR')

    def test_complete_report(self):
        raw = 'HGVM_CHECK=boot:PASS\r\nHGVM_CHECK=restore:PASS\r\nHGVM_RESULT=PASS TOTAL=2 FAILED=0 SCOPE=ISOLATED_X86_NOT_CUDY\r\n'
        report = parse_result(raw, {'boot', 'restore'})
        self.assertEqual(report['total'], 2)
        self.assertFalse(report['production_supported'])

    def test_missing_duplicate_unknown_and_incomplete_checks_refused(self):
        for checks in ('', 'HGVM_CHECK=boot:PASS\n', 'HGVM_CHECK=boot:PASS\nHGVM_CHECK=boot:PASS\n',
                       'HGVM_CHECK=boot:PASS\nHGVM_CHECK=unknown:PASS\n'):
            with self.subTest(checks=checks), self.assertRaises(ValueError):
                parse_result(checks + 'HGVM_RESULT=PASS TOTAL=2 FAILED=0 SCOPE=ISOLATED_X86_NOT_CUDY\n', {'boot', 'restore'})

    def test_counts_and_status_cannot_hide_failed_check(self):
        rows = 'HGVM_CHECK=boot:PASS\nHGVM_CHECK=restore:FAIL\n'
        for suffix in ('PASS TOTAL=2 FAILED=0', 'PASS TOTAL=2 FAILED=1', 'FAIL TOTAL=3 FAILED=1'):
            with self.assertRaises(ValueError):
                parse_result(rows + 'HGVM_RESULT=' + suffix + ' SCOPE=ISOLATED_X86_NOT_CUDY\n', {'boot', 'restore'})
        self.assertEqual(parse_result(rows + 'HGVM_RESULT=FAIL TOTAL=2 FAILED=1 SCOPE=ISOLATED_X86_NOT_CUDY\n', {'boot','restore'})['status'], 'FAIL')

    def test_no_completion_or_multiple_completions_refused(self):
        for text in ('HGVM_CHECK=boot:PASS\n', 'HGVM_RESULT=PASS TOTAL=0 FAILED=0 SCOPE=ISOLATED_X86_NOT_CUDY\n' * 2):
            with self.assertRaises(ValueError): parse_result(text, {'boot'})


class AdmissionFixtureTests(unittest.TestCase):
    def test_fresh_repository_needs_only_vendored_fixture_and_refuses_drift(self):
        import subprocess
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        import run_vm
        rel = 'scripts/deploy/fixtures/rc-b-20261019.2-admission.sh'
        expected = (run_vm.ROOT / rel).read_bytes()
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            def commit(raw):
                f = root / rel; f.parent.mkdir(parents=True, exist_ok=True); f.write_bytes(raw)
                subprocess.run(['git', '-C', d, 'add', '.'], check=True)
                subprocess.run(['git', '-C', d, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Fixture only'], check=True)
                return subprocess.check_output(['git', '-C', d, 'rev-parse', 'HEAD'], text=True).strip()
            head = commit(expected)
            missing = subprocess.run(['git', '-C', d, 'cat-file', '-e', '908dd3222b81992d9fee056bd015a1266a0ce8d7'], capture_output=True)
            self.assertNotEqual(missing.returncode, 0)
            with patch.object(run_vm, 'ROOT', root):
                self.assertEqual(run_vm.regression_admission(head), expected)
                corrupt = commit(expected + b'# drift\n')
                with self.assertRaisesRegex(ValueError, 'ADMISSION_REGRESSION_FIXTURE_SHA256'):
                    run_vm.regression_admission(corrupt)


if __name__ == '__main__': unittest.main()
