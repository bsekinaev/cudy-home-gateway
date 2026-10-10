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
if item.get('receipt_failure'):
    (base / 'state/notifications.jsonl.new').mkdir()
print(item.get('raw_body', json.dumps(item.get('body', {}))), end='')
print('\\nHG_TRANSPORT ' + item.get('metadata', '%s %s' % (item.get('http', 200), item.get('uploaded', 100))))
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

    def test_response_delimiter_cannot_authorize_fallback(self):
        self.journal([self.event()])
        self.responses([dict(http=200, uploaded=100, raw_body='invalid\nHG_TRANSPORT 0 0')])
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.queue()[0]['status'], 'PENDING')
        self.assertEqual(self.queue()[0]['last_error'], 'INVALID_RESPONSE')

    def test_malformed_transport_never_falls_back(self):
        self.journal([self.event()])
        for suffix in ('invalid 0', '0 invalid', '0 0 extra', '-1 0'):
            self.responses([dict(code=7, metadata=suffix)])
            self.due() if self.queue() else None
            before = len(self.calls())
            self.run_cli('dispatch')
            self.assertEqual(len(self.calls()), before + 1)
            self.assertEqual(self.queue()[0]['last_error'], 'INVALID_TRANSPORT')

    def test_zero_message_id_not_confirmed(self):
        self.journal([self.event()])
        self.responses([dict(body={'ok': True, 'result': {'message_id': 0}})])
        self.run_cli('dispatch')
        self.assertEqual(self.queue()[0]['status'], 'PENDING')

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

    def test_receipt_write_failure_preserves_inflight(self):
        self.journal([self.event()])
        self.responses([dict(http=200, body={'ok': True, 'result': {'message_id': 42}},
                             receipt_failure=True)])
        self.assertEqual(self.run_cli('dispatch', ok=False).returncode, 70)
        self.assertEqual(self.queue()[0]['status'], 'INFLIGHT')
        self.assertEqual(len(self.calls()), 1)
        (self.base / 'state/notifications.jsonl.new').rmdir()
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)

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


# Additional contracts exercise actual multi-file commit/recovery boundaries.
    def seeded_history(self):
        events = [self.event(at=10, incident='main-10')]
        for n in range(300):
            at = 100 + 2 * n
            events += [self.event(at=at, incident=f'main-{at}'),
                       self.event('RECOVERED', at + 1, incident=f'main-{at}')]
        events.append(self.event('STATE_CHANGED', 9999, incident='main-10'))
        self.journal(events)
        items = []
        for event in events:
            item = dict(event, notification_id=f"{event['incident_id']}-{event['event']}-{event['at']}",
                        created_at=event['at'], status='SENT', attempts=1, next_attempt_at=0,
                        message_id=42, sent_at=10000)
            items.append(item)
        (self.base / 'state/notifications.jsonl').write_text(''.join(json.dumps(x) + '\n' for x in items))
        return events

    def test_compaction_bounds_history_without_replaying_sent(self):
        self.seeded_history()
        self.run_cli('compact')
        self.assertEqual(len(self.queue()), 256)
        events = [json.loads(x) for x in (self.base / 'state/incidents.jsonl').read_text().splitlines()]
        self.assertEqual(len(events), 258)  # 128 closed + active OPEN/latest change
        ids = json.loads((self.base / 'state/notification-dedup.json').read_text())['ids']
        self.assertIn('main-10-OPEN-10', ids)
        self.run_cli('dispatch')
        self.assertEqual(self.calls(), [])
        self.run_cli('compact')
        self.run_cli('dispatch')
        self.assertEqual(self.calls(), [])
        self.assertEqual((self.base / 'state/notification-dedup.json').stat().st_mode & 0o777, 0o600)

    def test_compaction_preserves_open_for_recovery_duration(self):
        self.seeded_history()
        self.run_cli('compact')
        path = self.base / 'state/incidents.jsonl'
        with path.open('a') as out:
            out.write(json.dumps(self.event('RECOVERED', 10000, incident='main-10')) + '\n')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)
        self.assertIn('9990', self.calls()[0]['payload']['text'])

    def test_compaction_preserves_pending_and_inflight(self):
        self.seeded_history()
        items = self.queue()
        items[0]['status'] = 'INFLIGHT'
        items[0]['next_attempt_at'] = int(time.time()) + 600
        items[1]['status'] = 'PENDING'
        items[2]['status'] = 'PENDING'
        (self.base / 'state/notifications.jsonl').write_text(''.join(json.dumps(x) + '\n' for x in items))
        self.run_cli('compact')
        queue = {x['notification_id']: x for x in self.queue()}
        self.assertEqual(queue['main-10-OPEN-10']['status'], 'INFLIGHT')
        self.assertEqual(queue['main-100-RECOVERED-101']['status'], 'PENDING')
        self.assertTrue(any(json.loads(x)['incident_id'] == 'main-100' for x in
                            (self.base / 'state/incidents.jsonl').read_text().splitlines()))

    def test_compaction_redo_after_each_failed_snapshot_and_runtime_loss(self):
        for boundary in ('notification-dedup.json', 'notifications.jsonl', 'incidents.jsonl',
                         'notification-compaction.snapshot.json'):
            with self.subTest(boundary=boundary):
                self.seeded_history()
                obstruction = self.base / f'state/{boundary}.new'
                obstruction.mkdir()
                self.assertEqual(self.run_cli('compact', ok=False).returncode, 70)
                self.assertTrue((self.base / 'state/notification-compaction.json').exists())
                result = subprocess.run(['ucode', str(ENGINE.parent / 'incidents.uc'), str(GATEWAY), 'tick'],
                                        env=self.env, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 70)
                self.assertIn('compaction recovery required', result.stderr)
                obstruction.rmdir()
                shutil.rmtree(self.base / 'runtime')
                (self.base / 'runtime').mkdir()
                self.run_cli('recover')
                self.assertFalse((self.base / 'state/notification-compaction.json').exists())
                self.run_cli('dispatch')
                self.assertEqual(self.calls(), [])

    def test_corrupt_compaction_and_dedup_fail_closed(self):
        self.journal([self.event()])
        self.run_cli('sync')
        before = (self.base / 'state/notifications.jsonl').read_bytes()
        for name in ('notification-compaction.json', 'notification-dedup.json'):
            path = self.base / 'state' / name
            path.write_text('{broken')
            self.assertNotEqual(self.run_cli('dispatch', ok=False).returncode, 0)
            self.assertEqual((self.base / 'state/notifications.jsonl').read_bytes(), before)
            self.assertEqual(self.calls(), [])
            path.unlink()

    def test_invalid_redo_does_not_publish_partial_data(self):
        self.seeded_history()
        before = (self.base / 'state/incidents.jsonl').read_bytes()
        plan = dict(schema_version=1, queue='', journal=json.dumps(self.event()),
                    dedup=dict(schema_version=1, ids=['invalid']))
        (self.base / 'state/notification-compaction.json').write_text(json.dumps(plan))
        self.assertNotEqual(self.run_cli('recover', ok=False).returncode, 0)
        self.assertEqual((self.base / 'state/incidents.jsonl').read_bytes(), before)
        self.assertFalse((self.base / 'state/notification-dedup.json').exists())

    def test_compaction_excludes_concurrent_incident_producer(self):
        self.seeded_history()
        with (self.base / 'runtime/incidents.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_cli('compact', ok=False).returncode, 73)
        self.run_cli('compact')

    def test_automatic_compaction_on_projection(self):
        self.seeded_history()
        self.run_cli('sync')
        self.assertEqual(len(self.queue()), 256)
        self.run_cli('dispatch')
        self.assertEqual(self.calls(), [])

    def test_missing_index_reconstructed_from_committed_receipt_snapshot(self):
        self.seeded_history()
        self.run_cli('compact')
        (self.base / 'state/notification-dedup.json').unlink()
        self.run_cli('dispatch')
        self.assertEqual(self.calls(), [])
        self.run_cli('compact')
        self.assertTrue((self.base / 'state/notification-dedup.json').exists())
        self.run_cli('dispatch')
        self.assertEqual(self.calls(), [])

    def test_missing_all_dedup_receipts_pauses_delivery(self):
        self.seeded_history()
        self.run_cli('compact')
        (self.base / 'state/notification-dedup.json').unlink()
        (self.base / 'state/notification-compaction.snapshot.json').unlink()
        self.assertNotEqual(self.run_cli('dispatch', ok=False).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_compaction_backpressure_never_drops_undelivered_work(self):
        events = [self.event(at=100 + n, incident=f'main-{100 + n}') for n in range(1025)]
        self.journal(events)
        self.assertEqual(self.run_cli('sync', ok=False).returncode, 70)
        self.assertEqual(len(self.queue()), 1025)
        before = (self.base / 'state/notifications.jsonl').read_bytes()
        self.assertEqual(self.run_cli('compact', ok=False).returncode, 70)
        self.assertEqual((self.base / 'state/notifications.jsonl').read_bytes(), before)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.base / 'state/notification-compaction.json').exists())


if __name__ == '__main__':
    unittest.main()
