"""Exercise real poller status rendering through a networkless gateway boundary."""
import json
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
POLLER = ROOT / 'src/usr/lib/home-gateway/telegram-poller.uc'


class StatusEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        for name in ('runtime', 'secrets'):
            (self.base / name).mkdir()
        (self.base / 'secrets/telegram.user_id').write_text('111\n')
        (self.base / 'secrets/telegram.chat_id').write_text('222\n')
        self.env = dict(os.environ, HG_STATUS_TEST_BASE=str(self.base),
                        HG_TELEGRAM_RUNTIME_DIR=str(self.base / 'runtime'),
                        HG_TELEGRAM_SECRETS_DIR=str(self.base / 'secrets'))
        self.bridge = self.base / 'gateway'
        helper = self.base / 'bridge.py'
        helper.write_text('''
import json, os, pathlib, sys
base=pathlib.Path(os.environ['HG_STATUS_TEST_BASE']); args=sys.argv[1:]
with (base/'calls').open('a') as f: f.write(json.dumps(args)+'\\n')
if args==['status','--json']:
    sys.stdout.write((base/'status').read_text()); sys.exit(0)
if args[:2]==['actions','cancel']:
    print('{}'); sys.exit(0)
if args[:2]==['telegram','get-updates']:
    print(json.dumps({'ok':True,'result':json.loads((base/'updates').read_text())}))
elif args[:2]==['telegram','send-message']:
    print(json.dumps({'ok':True,'result':{'message_id':900}}))
else: sys.exit(97)
''')
        self.bridge.write_text('#!/bin/sh\nexec python3 ' + shlex.quote(str(helper)) + ' "$@"\n')
        self.bridge.chmod(0o755)

    def fixture(self):
        now = int(time.time())
        return dict(schema_version=1, gateway_version='0.5.0-dev',
                    generated_at=dict(epoch=now, local='2026-11-18 12:00:00 MSK'),
                    network=dict(wan=dict(state='OK'), direct_egress=dict(state='UNKNOWN')),
                    dns=dict(state='OK'),
                    vpn=dict(main=dict(state='OK', configured_node=dict(name='MAIN TEST'),
                                       egress=dict(state='OK', ipv4='203.0.113.4',
                                                   source='live_probe', checked_at=now-2))),
                    torrent=dict(state='OK', egress=dict(state='UNKNOWN')),
                    redmi=dict(state='OK', xray_process='OK', routing_policy=dict(state='OK'),
                               kill_switch=dict(state='OK'), egress=dict(state='UNKNOWN')))

    def render(self, data, authorized=True):
        (self.base / 'status').write_text(json.dumps(data))
        (self.base / 'updates').write_text(json.dumps([dict(update_id=1,
            message={'from':dict(id=111 if authorized else 999), 'chat':dict(id=222),
                     'date':int(time.time()), 'text':'/status'})]))
        result = subprocess.run(['ucode', str(POLLER), str(self.bridge), 'once'],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.base / 'calls').read_text().splitlines()]
        if not authorized:
            self.assertFalse(any(c[0] != 'telegram' or c[1] != 'get-updates' for c in calls))
            return ''
        self.assertEqual(calls.count(['status', '--json']), 1)
        self.assertTrue(all(c[0] in ('status', 'telegram') or c[:2] == ['actions', 'cancel'] for c in calls))
        messages = [c[3] for c in calls if c[:2] == ['telegram', 'send-message']]
        self.assertEqual(len(messages), 1)
        self.assertLessEqual(len(messages[0].encode()), 4096)
        return messages[0]

    def test_redmi_policy_ok_does_not_claim_client_internet(self):
        text = self.render(self.fixture())
        self.assertIn('Интернет REDMI: не проверен', text)
        self.assertIn('Правила: OK', text)
        self.assertIn('Kill Switch: OK', text)
        self.assertNotIn('Redmi: OK', text)

    def test_fresh_live_exit_has_its_own_age_and_node(self):
        text = self.render(self.fixture())
        self.assertIn('MAIN TEST', text)
        self.assertRegex(text, r'Выход MAIN: проверен · [0-9]+ с назад')
        self.assertIn('203.0.113.4', text)
        self.assertIn('DNS роутера: OK', text)

    def test_fresh_cache_is_explicit(self):
        data = self.fixture()
        data['vpn']['main']['egress'].update(source='cache', checked_at=int(time.time())-120)
        self.assertRegex(self.render(data), r'Выход MAIN: проверен, кэш · [0-9]+ с назад')

    def test_stale_cache_never_presents_current_exit_ip(self):
        data = self.fixture()
        data['vpn']['main']['egress'].update(source='stale_cache', checked_at=int(time.time())-600)
        text = self.render(data)
        self.assertIn('Выход MAIN: нет свежей проверки', text)
        self.assertNotIn('203.0.113.4', text)

    def test_old_live_or_cache_is_not_fresh_even_if_backend_says_ok(self):
        for source in ('live_probe', 'cache'):
            with self.subTest(source=source):
                data = self.fixture()
                data['vpn']['main']['egress'].update(source=source, checked_at=int(time.time())-600)
                # Each poller instance consumes its update only once.
                (self.base / 'runtime/telegram.offset').unlink(missing_ok=True)
                (self.base / 'calls').unlink(missing_ok=True)
                self.assertIn('Выход MAIN: нет свежей проверки', self.render(data))

    def test_missing_future_or_invalid_timestamp_never_confirms(self):
        for stamp in (None, 0, -1, '123', True, {}, int(time.time())+10000):
            with self.subTest(stamp=stamp):
                data = self.fixture()
                data['vpn']['main']['egress']['checked_at'] = stamp
                (self.base / 'runtime/telegram.offset').unlink(missing_ok=True)
                (self.base / 'calls').unlink(missing_ok=True)
                text = self.render(data)
                self.assertIn('Выход MAIN: не проверен', text)
                self.assertNotIn('203.0.113.4', text)

    def test_local_down_overrides_successful_exit_cache(self):
        data = self.fixture()
        data['vpn']['main']['state'] = 'DOWN'
        text = self.render(data)
        self.assertIn('Выход MAIN: нет подтверждения (служба недоступна)', text)
        self.assertNotIn('203.0.113.4', text)

    def test_unknown_source_does_not_confirm(self):
        data = self.fixture()
        data['vpn']['main']['egress']['source'] = 'untrusted'
        self.assertIn('Выход MAIN: не проверен', self.render(data))

    def test_missing_fields_are_unknown_not_success(self):
        text = self.render({})
        self.assertIn('Выход MAIN: не проверен', text)
        self.assertIn('Интернет REDMI: не проверен', text)

    def test_unbounded_node_name_and_invalid_ip_not_echoed(self):
        data = self.fixture()
        data['vpn']['main']['configured_node']['name'] = 'PRIVATE_LONG_VALUE' * 1000
        data['vpn']['main']['egress']['ipv4'] = '999.2.3.4\nMISLEADING'
        text = self.render(data)
        self.assertNotIn('PRIVATE_LONG_VALUE', text)
        self.assertNotIn('MISLEADING', text)

    def test_control_characters_in_node_names_are_not_forwarded(self):
        for control in ('\n', '\x00'):
            with self.subTest(control=repr(control)):
                data = self.fixture()
                data['vpn']['main']['configured_node']['name'] = 'PRIVATE' + control + 'NODE'
                (self.base / 'runtime/telegram.offset').unlink(missing_ok=True)
                (self.base / 'calls').unlink(missing_ok=True)
                self.assertNotIn('PRIVATE', self.render(data))

    def test_recent_explicit_probe_failure_is_distinct_from_missing_probe(self):
        data = self.fixture()
        data['vpn']['main']['egress']['state'] = 'DOWN'
        text = self.render(data)
        self.assertIn('Выход MAIN: проверка неуспешна', text)
        self.assertNotIn('203.0.113.4', text)

    def test_nonobject_payload_is_unavailable(self):
        self.assertEqual(self.render(True), 'Статус временно недоступен.')

    def test_unauthorized_message_does_not_collect_status(self):
        self.render(self.fixture(), authorized=False)
