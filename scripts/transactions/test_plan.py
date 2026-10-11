"""Production ash planner with isolated UCI read boundary, never live CUDY."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        (self.base / 'bin').mkdir()
        script = self.base / 'bin/uci'
        script.write_text('''#!/usr/bin/env python3
import json,os,sys,signal,time
from pathlib import Path
base=Path(os.environ['HG_PLAN_TEST_BASE'])
with (base/'calls').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
data=json.loads((base/'data').read_text())
args=sys.argv[1:]
if data.get('stall'):
 signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)
if args==['-q','changes','passwall2']:
 print(data.get('changes',''),end=''); sys.exit(data.get('changes_rc',0))
if len(args)!=3 or args[:2]!=['-q','get']: sys.exit(99)
key=args[2]
if key not in data: print('private-credential-detail',file=sys.stderr); sys.exit(1)
print(data[key])
''')
        script.chmod(0o755)
        self.data = {'passwall2.@global[0].enabled': '1', 'passwall2.rulenode.default_node': 'socks_P8ART',
                     'passwall2.socks_P8ART': 'socks', 'passwall2.socks_P8ART.enabled': '1',
                     'passwall2.socks_P8ART.port': '1082', 'passwall2.socks_P8ART.enable_autoswitch': '0',
                     'passwall2.socks_P8ART.node': 'current_private_id', 'passwall2.candidate_private_id': 'nodes',
                     'passwall2.current_private_id': 'nodes'}
        self.env = dict(os.environ, HG_PLAN_TEST_BASE=str(self.base), HG_LIBDIR=str(ROOT / 'src/usr/lib/home-gateway'),
                        PATH=str(self.base / 'bin') + ':' + os.environ['PATH'])

    def run_plan(self, candidate='candidate_private_id', mode='plan'):
        (self.base / 'data').write_text(json.dumps(self.data))
        args = [os.environ.get('HG_TEST_BUSYBOX', 'busybox'), 'ash', str(ROOT / 'src/usr/bin/gateway'), 'main-transaction', mode]
        if mode == 'plan': args.append(candidate)
        result = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotIn('private-credential-detail', result.stdout + result.stderr)
        return result

    def test_real_plan_never_claims_network_preflight_or_apply(self):
        result = self.run_plan()
        self.assertEqual(result.returncode, 70)
        data = json.loads(result.stdout)
        self.assertEqual(data['status'], 'PREFLIGHT_ADAPTER_REQUIRED')
        self.assertTrue(data['candidate_exists'])
        self.assertFalse(data['same_as_configured_main'])
        for field in ('apply_supported', 'preflight_passed', 'snapshot_ready'): self.assertFalse(data[field])
        self.assertNotIn('private_id', result.stdout)
        calls = [json.loads(s) for s in (self.base / 'calls').read_text().splitlines()]
        self.assertTrue(all(c[1] in ('get', 'changes') for c in calls))

    def test_same_candidate_remains_blocked_without_change(self):
        result = self.run_plan('current_private_id')
        self.assertTrue(json.loads(result.stdout)['same_as_configured_main'])
        self.assertEqual(result.returncode, 70)

    def test_candidate_injection_rejected_before_uci(self):
        for value in ('', '../node', 'node;reboot', 'node\nset', '-q', '@nodes[0]', 'x' * 65):
            self.assertEqual(self.run_plan(value).returncode, 2)
        self.assertFalse((self.base / 'calls').exists())

    def test_uncommitted_and_failed_changes_blocked(self):
        for edits, rc, reason in [('secret=value\n', 0, 'UNCOMMITTED_CONFIG'), ('', 1, 'UCI_READ_FAILED')]:
            self.data.update(changes=edits, changes_rc=rc)
            result = self.run_plan()
            self.assertEqual(result.returncode, 70)
            self.assertEqual(json.loads(result.stdout)['status'], reason)
            self.assertNotIn('secret', result.stdout)

    def test_untrusted_profile_port_autoswitch_and_candidate_fail_closed(self):
        changes = [('passwall2.rulenode.default_node', 'torrent_profile', 'UNSUPPORTED_MAIN_PROFILE'),
                   ('passwall2.socks_P8ART.port', '1081', 'UNSUPPORTED_MAIN_PROFILE'),
                   ('passwall2.socks_P8ART.enabled', '0', 'UNSUPPORTED_MAIN_PROFILE'),
                   ('passwall2.socks_P8ART.enable_autoswitch', '1', 'AUTOSWITCH_REQUIRES_OWNER'),
                   ('passwall2.candidate_private_id', 'global', 'INVALID_CANDIDATE_TYPE'),
                   ('passwall2.socks_P8ART.node', '../bad', 'INVALID_CURRENT_NODE')]
        for key, value, reason in changes:
            original = self.data[key]
            self.data[key] = value
            result = self.run_plan()
            self.assertEqual(json.loads(result.stdout)['status'], reason)
            self.data[key] = original

    def test_missing_and_oversized_reads_do_not_leak(self):
        del self.data['passwall2.candidate_private_id']
        result = self.run_plan()
        self.assertEqual(json.loads(result.stdout)['status'], 'CANDIDATE_UNAVAILABLE')
        self.data['passwall2.@global[0].enabled'] = 'sensitive' * 1000
        result = self.run_plan()
        self.assertEqual(json.loads(result.stdout)['status'], 'UCI_READ_FAILED')
        self.assertNotIn('sensitive', result.stdout + result.stderr)

    def test_multiline_scalar_cannot_hide_oversize_by_trailing_lf(self):
        for value in ('1' + '\n' * 1000, '1\nextra', '1' + '\n' * 64 + 'secret'):
            self.data['passwall2.@global[0].enabled'] = value
            result = self.run_plan()
            self.assertEqual(json.loads(result.stdout)['status'], 'UCI_READ_FAILED')
            self.assertNotIn('secret', result.stdout)

    def test_uci_ignoring_term_is_killed_within_bound(self):
        import time
        self.data['stall'] = True
        started = time.monotonic()
        result = self.run_plan()
        self.assertEqual(json.loads(result.stdout)['status'], 'UCI_READ_FAILED')
        self.assertLess(time.monotonic() - started, 8)

    def test_mutation_modes_never_touch_uci(self):
        for mode in ('apply', 'rollback', 'recover'):
            result = self.run_plan(mode=mode)
            self.assertEqual(result.returncode, 70)
            self.assertEqual(json.loads(result.stdout)['status'], 'TRANSACTION_NOT_IMPLEMENTED')
        self.assertFalse((self.base / 'calls').exists())


if __name__ == '__main__':
    unittest.main()
