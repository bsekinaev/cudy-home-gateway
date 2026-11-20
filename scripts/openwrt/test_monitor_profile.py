"""Ensure each native VM profile admits only its own executed check inventory."""
from pathlib import Path
import re
import subprocess
import unittest
import run_vm

GUEST = Path(__file__).with_name('guest-owner-series.sh').read_bytes()

class MonitorProfileTests(unittest.TestCase):
    def test_monitor_selects_installed62_and_monitor_lifecycle(self):
        raw = run_vm.series_guest(GUEST, 'owner-monitor')
        self.assertIn(b'check installed62_apply ', raw)
        self.assertIn(b'check monitor_missing_setsid_before_writes ', raw)
        self.assertIn(b'check monitor_broken_setsid_before_writes ', raw)
        self.assertIn(b'check monitor_rollback_to_installed62 ', raw)
        self.assertNotIn(b'check series_apply_b ', raw)
        self.assertNotIn(b'"$update/inspect.uc"', raw)
        self.assertIn(b'check explicit_series_recovery ', raw)
        self.assertIn(b'check network_config_unchanged ', raw)
        subprocess.run(['sh', '-n'], input=raw, check=True)

    def test_monitor_crash_verifies_latest_receipt_and_exact_baseline_bytes(self):
        raw = run_vm.series_guest(GUEST, 'owner-monitor')
        crash = raw.split(b'crash_case() {', 1)[1].split(b'check cut_lease_published', 1)[0]
        self.assertNotIn(b'stage "$LAB/baseline" verify', crash)
        self.assertIn(b'stage "$LAB/a" verify "$(cat /etc/home-gateway-owner-series/latest)"', crash)
        self.assertIn(b'sha256sum -c "$LAB/baseline/candidate.sha256"', crash)

    def test_observer_preserves_historical_matrix(self):
        raw = run_vm.series_guest(GUEST, 'owner-series')
        self.assertIn(b'check series_apply_b ', raw)
        self.assertNotIn(b'check installed62_apply ', raw)
        self.assertNotIn(b'check monitor_missing_setsid_before_writes ', raw)
        self.assertIn(b'"$update/inspect.uc"', raw)
        checks = re.findall(rb'^\s*check ([a-z0-9_]+) ', raw, re.M)
        self.assertEqual(len(checks), 67)
        self.assertEqual(len(set(checks)), len(checks))
        subprocess.run(['sh', '-n'], input=raw, check=True)

if __name__ == '__main__': unittest.main()
