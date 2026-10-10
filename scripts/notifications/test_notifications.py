"""Run production ucode + gateway + shell adapter against a fault-injected curl boundary."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'src/usr/lib/home-gateway/notifications.uc'
GATEWAY = ROOT / 'src/usr/bin/gateway'


class DispatcherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        for name in ('state', 'runtime', 'secrets', 'bin'):
            (self.base / name).mkdir()
        self.env = dict(os.environ, HG_LIBDIR=str(ENGINE.parent),
                        HG_NOTIFICATION_STATE_DIR=str(self.base / 'state'),
                        HG_NOTIFICATION_RUNTIME_DIR=str(self.base / 'runtime'),
                        HG_NOTIFICATION_SECRETS_DIR=str(self.base / 'secrets'),
                        HG_TELEGRAM_TOKEN_FILE=str(self.base / 'secrets/token'),
                        HG_SYSUPGRADE_FILE=str(self.base / 'sysupgrade.conf'),
                        HG_TEST_BASE=str(self.base))
        self.env['PATH'] = str(self.base / 'bin') + ':' + self.env['PATH']
        # Deliberately synthetic, not a production credential.
        (self.base / 'secrets/token').write_text('1:synthetic_test_value\n')
        (self.base / 'secrets/telegram.chat_id').write_text('123\n')
        curl = self.base / 'bin/curl'
        curl.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
base = pathlib.Path(os.environ['HG_TEST_BASE'])
args = sys.argv[1:]
config = sys.stdin.read()
assert 'synthetic_test_value' not in ' '.join(args)
assert '--noproxy' in args and args[args.index('--noproxy') + 1] == ''
proxy = args[args.index('--socks5-hostname') + 1]
path = args[args.index('--data-binary') + 1][1:]
payload = json.loads(pathlib.Path(path).read_text())
assert payload['chat_id'] == '123'
with (base / 'calls').open('a') as out:
    out.write(json.dumps({'proxy': proxy, 'payload': payload}) + '\\n')
if (base / 'pause').exists():
    (base / 'entered').touch()
    while (base / 'pause').exists(): time.sleep(.02)
plans = json.loads((base / 'responses').read_text())
item = plans.pop(0) if plans else {'http': 200, 'body': {'ok': True, 'result': {'message_id': 42}}}
(base / 'responses').write_text(json.dumps(plans))
print(json.dumps(item.get('body', {})), end='')
print('\\nHG_TRANSPORT %s %s' % (item.get('http', 200), item.get('uploaded', 100)))
sys.exit(item.get('code', 0))
''')
        curl.chmod(0o755)
        (self.base / 'responses').write_text('[]')
        self.run_cli('configure', 'enable')

    def run_cli(self, *args, ok=True):
        result = subprocess.run(['ucode', str(ENGINE), str(GATEWAY), *args],
                                env=self.env, text=True, capture_output=True, timeout=15)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def event(self, kind='OPEN', at=100, component='main', incident='main-100'):
        return dict(schema_version=1, incident_id=incident, event=kind, at=at,
                    component=component, role='core', state='OK' if kind == 'RECOVERED' else 'DOWN',
                    reason='NEVER_LEAK_REASON')

    def journal(self, events):
        (self.base / 'state/incidents.jsonl').write_text(''.join(json.dumps(x) + '\n' for x in events))

    def queue(self):
        return json.loads(self.run_cli('json').stdout)['notifications']

    def calls(self):
        path = self.base / 'calls'
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def responses(self, items):
        (self.base / 'responses').write_text(json.dumps(items))

    def due(self):
        items = self.queue()
        for item in items:
            item['next_attempt_at'] = 0
        (self.base / 'state/notifications.jsonl').write_text(''.join(json.dumps(x) + '\n' for x in items))

    def test_success_and_no_resend_after_process_restart(self):
        self.journal([self.event()])
        self.run_cli('dispatch')
        self.assertEqual(self.queue()[0]['status'], 'SENT')
        self.assertEqual(self.queue()[0]['message_id'], 42)
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)
        self.assertNotIn('NEVER_LEAK_REASON', str(self.calls()))
        self.assertEqual((self.base / 'state/notifications.jsonl').stat().st_mode & 0o777, 0o600)

    def test_state_changes_not_lost_and_projection_idempotent(self):
        self.journal([self.event(), self.event('STATE_CHANGED', 101), self.event('STATE_CHANGED', 102)])
        self.run_cli('sync')
        self.run_cli('sync')
        self.assertEqual(len(self.queue()), 3)

    def test_main_unreachable_falls_back(self):
        self.journal([self.event()])
        self.responses([dict(http=0, uploaded=0, code=7)])
        self.run_cli('dispatch')
        self.assertEqual([x['proxy'] for x in self.calls()], ['127.0.0.1:1082', '127.0.0.1:1081'])
        self.assertEqual(self.queue()[0]['route'], 'TORRENT')

    def test_ambiguous_timeout_never_falls_back(self):
        self.journal([self.event()])
        self.responses([dict(http=0, uploaded=100, code=28)])
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.queue()[0]['status'], 'PENDING')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)
        self.due()
        self.run_cli('dispatch')
        self.assertEqual(self.queue()[0]['attempts'], 2)
        self.assertEqual(self.queue()[0]['status'], 'SENT')

    def test_both_proxies_down_persists_backoff(self):
        self.journal([self.event()])
        self.responses([dict(http=0, uploaded=0, code=7)] * 2)
        self.run_cli('dispatch')
        item = self.queue()[0]
        self.assertEqual(item['status'], 'PENDING')
        self.assertGreater(item['next_attempt_at'], time.time())
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 2)

    def test_rate_limit_honours_delay_and_stops_batch(self):
        self.journal([self.event(), self.event(at=101, incident='main-101')])
        self.responses([dict(http=429, code=22, body={'ok': False, 'error_code': 429,
                                                     'parameters': {'retry_after': 120}})])
        before = time.time()
        self.run_cli('dispatch')
        self.assertGreaterEqual(self.queue()[0]['next_attempt_at'], int(before) + 120)
        self.assertEqual(len(self.calls()), 1)
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)

    def test_unauthorized_is_terminal_not_hot_loop(self):
        self.journal([self.event()])
        self.responses([dict(http=401, code=22, body={'ok': False})])
        self.run_cli('dispatch')
        self.run_cli('dispatch')
        self.assertEqual(self.queue()[0]['status'], 'FAILED')
        self.assertEqual(len(self.calls()), 1)

    def test_server_failure_is_retryable(self):
        self.journal([self.event()])
        self.responses([dict(http=503, code=22, body={'ok': False})])
        self.run_cli('dispatch')
        self.assertEqual(self.queue()[0]['last_error'], 'TELEGRAM_UNAVAILABLE')
        self.assertEqual(len(self.calls()), 1)

    def test_api_ok_false_not_marked_sent(self):
        self.journal([self.event()])
        self.responses([dict(http=200, body={'ok': False})])
        self.run_cli('dispatch')
        self.assertEqual(self.queue()[0]['status'], 'PENDING')

    def test_recovery_summary_coalesces_pending_transitions(self):
        self.journal([self.event(), self.event('STATE_CHANGED', 110), self.event('RECOVERED', 130)])
        self.run_cli('dispatch')
        self.assertEqual([x['status'] for x in self.queue()], ['COALESCED', 'COALESCED', 'SENT'])
        self.assertEqual(len(self.calls()), 1)
        self.assertIn('30 с.', self.calls()[0]['payload']['text'])

    def test_mute_and_categories_preserve_pending(self):
        self.journal([self.event()])
        self.run_cli('configure', 'mute', '3600')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 0)
        self.run_cli('configure', 'mute', '0')
        self.run_cli('configure', 'category', 'main', 'off')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 0)
        self.run_cli('configure', 'category', 'main', 'on')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)

    def test_disabled_by_default(self):
        (self.base / 'state/notification-policy.json').unlink()
        self.journal([self.event()])
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 0)

    def test_corrupt_queue_fails_closed_preserves_bytes(self):
        self.journal([self.event()])
        self.run_cli('sync')
        path = self.base / 'state/notifications.jsonl'
        raw = path.read_text() + '{partial'
        path.write_text(raw)
        self.assertNotEqual(self.run_cli('dispatch', ok=False).returncode, 0)
        self.assertEqual(path.read_text(), raw)
        self.assertEqual(len(self.calls()), 0)

    def test_corrupt_policy_fails_closed(self):
        (self.base / 'state/notification-policy.json').write_text('{broken')
        self.journal([self.event()])
        self.assertNotEqual(self.run_cli('dispatch', ok=False).returncode, 0)
        self.assertEqual(len(self.calls()), 0)

    def test_invalid_typed_record_fails_closed(self):
        self.journal([self.event()])
        self.run_cli('sync')
        items = self.queue()
        items[0]['next_attempt_at'] = 'never'
        (self.base / 'state/notifications.jsonl').write_text(json.dumps(items[0]) + '\n')
        self.assertNotEqual(self.run_cli('dispatch', ok=False).returncode, 0)
        self.assertEqual(len(self.calls()), 0)

    def test_singleton(self):
        lock = (self.base / 'runtime/notifications.lock').open('a')
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.run_cli('sync', ok=False).returncode, 73)

    def test_crash_inflight_lease_and_restart(self):
        self.journal([self.event()])
        (self.base / 'pause').touch()
        proc = subprocess.Popen(['ucode', str(ENGINE), str(GATEWAY), 'dispatch'], env=self.env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(lambda: proc.poll() is None and os.killpg(proc.pid, signal.SIGKILL))
        deadline = time.monotonic() + 5
        while not (self.base / 'entered').exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue((self.base / 'entered').exists())
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)
        (self.base / 'pause').unlink()
        self.assertEqual(self.queue()[0]['status'], 'INFLIGHT')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)
        self.due()
        self.run_cli('dispatch')
        self.assertEqual(self.queue()[0]['status'], 'SENT')
        self.assertEqual(self.queue()[0]['attempts'], 2)

    def test_reboot_runtime_removed_preserves_sent(self):
        self.journal([self.event()])
        self.run_cli('dispatch')
        shutil.rmtree(self.base / 'runtime')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)

    def test_batch_bounded(self):
        self.journal([self.event(at=100 + i, incident=f'main-{100+i}') for i in range(6)])
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 4)
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 6)

    def test_persistence_idempotent_preserves_existing_entries(self):
        path = self.base / 'sysupgrade.conf'
        path.write_text('# existing\n/etc/custom/')
        self.run_cli('persistence')
        raw = path.read_text()
        self.run_cli('persistence')
        self.assertEqual(raw, path.read_text())
        self.assertIn('/etc/custom/\n', raw)
        self.assertIn('/etc/home-gateway/\n', raw)

    def test_rate_limit_crash_before_policy_receipt_still_blocks_batch(self):
        self.journal([self.event(), self.event(at=101, incident='main-101')])
        self.responses([dict(http=429, code=22, body={'ok': False, 'error_code': 429,
                                                     'parameters': {'retry_after': 120}})])
        self.run_cli('dispatch')
        policy_path = self.base / 'state/notification-policy.json'
        policy = json.loads(policy_path.read_text())
        policy['delivery_not_before'] = 0
        policy_path.write_text(json.dumps(policy))
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)

    def test_recovery_after_ambiguous_inflight_waits_and_coalesces(self):
        self.journal([self.event()])
        self.run_cli('sync')
        item = self.queue()[0]
        item.update(status='INFLIGHT', attempts=1, next_attempt_at=int(time.time()) + 60)
        (self.base / 'state/notifications.jsonl').write_text(json.dumps(item) + '\n')
        self.journal([self.event(), self.event('RECOVERED', 130)])
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 0)
        self.due()
        self.run_cli('dispatch')
        self.assertEqual([x['status'] for x in self.queue()], ['COALESCED', 'SENT'])
        self.assertEqual(len(self.calls()), 1)

    def test_disk_write_failure_never_sends(self):
        self.journal([self.event()])
        (self.base / 'state/notifications.jsonl.new').mkdir()
        self.assertNotEqual(self.run_cli('dispatch', ok=False).returncode, 0)
        self.assertEqual(len(self.calls()), 0)

    def test_orphan_new_file_not_used_as_receipt(self):
        self.journal([self.event()])
        self.run_cli('dispatch')
        (self.base / 'state/notifications.jsonl.new').write_text('{partial')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)

    def test_queue_size_limit_fails_closed(self):
        (self.base / 'state/notifications.jsonl').write_text(' ' * 2097153)
        self.assertNotEqual(self.run_cli('dispatch', ok=False).returncode, 0)
        self.assertEqual(len(self.calls()), 0)

    def test_legacy_projection_dedup(self):
        self.journal([self.event('STATE_CHANGED', 101)])
        self.run_cli('sync')
        item = self.queue()[0]
        item['notification_id'] = 'main-100-STATE_CHANGED'
        (self.base / 'state/notifications.jsonl').write_text(json.dumps(item) + '\n')
        self.journal([self.event('STATE_CHANGED', 101), self.event('STATE_CHANGED', 102)])
        self.run_cli('sync')
        self.assertEqual(len(self.queue()), 1)

    def test_invalid_configuration(self):
        for args in [('mute', '-1'), ('mute', '86401'), ('category', 'evil', 'on')]:
            self.assertEqual(self.run_cli('configure', *args, ok=False).returncode, 2)


if __name__ == '__main__':
    unittest.main()
