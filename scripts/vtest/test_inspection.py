"""Run actual gateway inspection and poller with an isolated Telegram boundary."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
GATEWAY = ROOT / 'src/usr/bin/gateway'
POLLER = ROOT / 'src/usr/lib/home-gateway/telegram-poller.uc'


class VtestInspectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.busybox = os.environ.get('HG_TEST_BUSYBOX', 'busybox')
        for name in ('runtime', 'secrets'):
            (self.base / name).mkdir()
        self.provider = self.base / 'vtest'
        self.provider.write_text('#!/bin/sh\ntouch "$HG_VTEST_SENTINEL"\necho PRIVATE_PROVIDER_CONTENT\n')
        self.provider.chmod(0o755)
        self.cron = self.base / 'cron'
        self.cron.write_text('0 4 * * 0 /usr/bin/vtest --private PRIVATE_CRON_CONTENT\n')
        (self.base / 'secrets/telegram.user_id').write_text('111\n')
        (self.base / 'secrets/telegram.chat_id').write_text('222\n')
        self.env = dict(os.environ, HG_LIBDIR=str(GATEWAY.parents[1] / 'lib/home-gateway'),
                        HG_VTEST_PATH=str(self.provider), HG_VTEST_CRONTAB=str(self.cron),
                        HG_VTEST_SENTINEL=str(self.base / 'executed'),
                        HG_TELEGRAM_RUNTIME_DIR=str(self.base / 'runtime'),
                        HG_TELEGRAM_SECRETS_DIR=str(self.base / 'secrets'),
                        HG_VTEST_TEST_BASE=str(self.base), HG_VTEST_REAL_GATEWAY=str(GATEWAY),
                        HG_VTEST_TEST_BUSYBOX=self.busybox)
        self.helper = self.base / 'helper.py'
        self.helper.write_text('''import json, os, pathlib, subprocess, sys
base = pathlib.Path(os.environ['HG_VTEST_TEST_BASE'])
args = sys.argv[1:]
with (base / 'calls').open('a') as out: out.write(json.dumps(args) + '\\n')
if args[0] == 'vtest':
    result = subprocess.run([os.environ['HG_VTEST_TEST_BUSYBOX'], 'ash', os.environ['HG_VTEST_REAL_GATEWAY'], *args], capture_output=True)
    sys.stdout.buffer.write(result.stdout)
    sys.exit(result.returncode)
if args[:2] == ['telegram', 'get-updates']:
    print(json.dumps({'ok': True, 'result': json.loads((base / 'updates').read_text())}))
else:
    print(json.dumps({'ok': True, 'result': {'message_id': 900}}))
''')
        self.bridge = self.base / 'gateway'
        self.bridge.write_text('#!/bin/sh\nexec python3 ' + shlex.quote(str(self.helper)) + ' "$@"\n')

    def cli(self, *args):
        return subprocess.run([self.busybox, 'ash', str(GATEWAY), 'vtest', *args],
                              env=self.env, text=True, capture_output=True, timeout=5)

    def inspect(self):
        result = self.cli('--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('PRIVATE_', result.stdout)
        self.assertFalse((self.base / 'executed').exists())
        return json.loads(result.stdout)

    def poll(self, update):
        (self.base / 'updates').write_text(json.dumps([update]))
        result = subprocess.run(['ucode', str(POLLER), str(self.bridge), 'once'],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / 'executed').exists())
        return [json.loads(line) for line in (self.base / 'calls').read_text().splitlines()]

    def message(self, user=111, chat=222, at=None):
        return {'update_id': 1, 'message': {'from': {'id': user}, 'chat': {'id': chat},
                'date': int(time.time()) if at is None else at, 'text': '/vtest'}}

    def test_fingerprint_cron_and_explicit_unknown_results(self):
        data = self.inspect()
        self.assertEqual(data['provider']['sha256'], hashlib.sha256(self.provider.read_bytes()).hexdigest())
        self.assertTrue(data['provider']['installed'])
        self.assertTrue(data['provider']['executable'])
        self.assertTrue(data['cron_configured'])
        self.assertEqual(data['state'], 'UNKNOWN')
        self.assertEqual(data['integration'], 'BLOCKED')
        self.assertIsNone(data['latest'])
        self.assertIsNone(data['history'])

    def test_inspection_never_counts_unbounded_file_streams(self):
        tools = self.base / 'bin'
        tools.mkdir()
        wc = tools / 'wc'
        wc.write_text('#!/bin/sh\ntouch "$HG_VTEST_SENTINEL"\nexit 97\n')
        wc.chmod(0o755)
        self.env['PATH'] = str(tools) + ':' + self.env['PATH']
        data = self.inspect()
        self.assertTrue(data['cron_configured'])
        self.assertIsNotNone(data['provider']['sha256'])
        self.provider.write_bytes(b'')
        with self.provider.open('r+b') as out:
            out.truncate(100 * 1024 * 1024)  # Sparse; no large test payload allocation.
        self.assertEqual(self.inspect()['reason'], 'PROVIDER_TOO_LARGE')

    def test_missing_provider_not_reported_as_idle(self):
        self.provider.unlink()
        data = self.inspect()
        self.assertEqual(data['reason'], 'PROVIDER_MISSING')
        self.assertFalse(data['provider']['installed'])
        self.assertEqual(data['state'], 'UNKNOWN')

    def test_symlink_provider_not_followed(self):
        actual = self.base / 'actual'
        self.provider.rename(actual)
        self.provider.symlink_to(actual)
        data = self.inspect()
        self.assertEqual(data['reason'], 'PROVIDER_SYMLINK')
        self.assertIsNone(data['provider']['sha256'])

    def test_oversized_provider_bounded(self):
        self.provider.write_bytes(b'x' * 262145)
        data = self.inspect()
        self.assertEqual(data['reason'], 'PROVIDER_TOO_LARGE')
        self.assertIsNone(data['provider']['sha256'])

    def test_commented_cron_and_large_cron_not_exposed(self):
        for contents in ('# 0 4 * * 0 /usr/bin/vtest\n', 'x' * 65537):
            self.cron.write_text(contents)
            self.assertFalse(self.inspect()['cron_configured'])

    def test_runs_and_arbitrary_arguments_never_execute_provider(self):
        for profile in ('quick', 'full', 'capability'):
            self.assertEqual(self.cli('run', profile).returncode, 70)
        for args in (('run', 'arbitrary'), ('run', 'quick;touch /tmp/test'), ('exec',), ('--json', 'extra')):
            self.assertEqual(self.cli(*args).returncode, 2)
        self.assertFalse((self.base / 'executed').exists())

    def test_authorized_telegram_view_uses_actual_inspection(self):
        calls = self.poll(self.message())
        self.assertIn(['vtest', '--json'], calls)
        sent = next(c for c in calls if c[:2] == ['telegram', 'send-message'])
        self.assertIn('UNKNOWN', sent[3])
        self.assertIn('заблокирован', sent[3])
        self.assertNotIn('PRIVATE_', sent[3])
        buttons = json.loads(sent[4])['inline_keyboard'][0]
        self.assertTrue(any(b['callback_data'].startswith('vtest:') for b in buttons))

    def test_wrong_identity_or_stale_message_does_not_inspect(self):
        for update in (self.message(user=999), self.message(chat=999), self.message(at=1)):
            calls = self.poll(update)
            self.assertNotIn(['vtest', '--json'], calls)

    def test_vtest_callback_validates_nonce_and_message_identity(self):
        calls = self.poll(self.message())
        markup = json.loads(next(c for c in calls if c[:2] == ['telegram', 'send-message'])[4])
        button = next(b for b in markup['inline_keyboard'][0] if b['callback_data'].startswith('vtest:'))
        callback = {'id': 'cb', 'from': {'id': 111}, 'message': {'chat': {'id': 222}, 'message_id': 900},
                    'data': button['callback_data']}
        count = calls.count(['vtest', '--json'])
        callback['data'] += 'bad'
        calls = self.poll({'update_id': 2, 'callback_query': callback})
        self.assertEqual(calls.count(['vtest', '--json']), count)
        callback['data'] = button['callback_data']
        calls = self.poll({'update_id': 3, 'callback_query': callback})
        self.assertEqual(calls.count(['vtest', '--json']), count + 1)
        edit = next(c for c in calls if c[:2] == ['telegram', 'edit-message'])
        self.assertIn('UNKNOWN', edit[4])

    def test_expired_callback_rejected(self):
        self.poll(self.message())
        issued = int(time.time()) - 200
        (self.base / 'runtime/telegram.callback').write_text(f'{issued}:nonce:900\n')
        callback = {'id': 'cb', 'from': {'id': 111}, 'message': {'chat': {'id': 222}, 'message_id': 900},
                    'data': f'vtest:{issued}:nonce'}
        calls = self.poll({'update_id': 2, 'callback_query': callback})
        self.assertEqual(calls.count(['vtest', '--json']), 1)


if __name__ == '__main__':
    unittest.main()
