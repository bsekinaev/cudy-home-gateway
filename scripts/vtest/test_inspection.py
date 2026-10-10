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
        self.env = dict(os.environ, HG_VTEST_RESULTS_DIR=str(self.base / 'results'), HG_LIBDIR=str(GATEWAY.parents[1] / 'lib/home-gateway'),
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

    def test_partial_reader_failure_discards_digest_and_cron(self):
        tools = self.base / 'bin'
        tools.mkdir()
        head = tools / 'head'
        head.write_text('#!/bin/sh\nprintf "0 4 * * 0 /usr/bin/vtest\\n"\nexit 97\n')
        head.chmod(0o755)
        self.env['PATH'] = str(tools) + ':' + self.env['PATH']
        data = self.inspect()
        self.assertIsNone(data['provider']['sha256'])
        self.assertEqual(data['reason'], 'PROVIDER_UNREADABLE')
        self.assertFalse(data['cron_configured'])

    def test_hasher_failure_discards_plausible_partial_digest(self):
        tools = self.base / 'bin'
        tools.mkdir()
        hasher = tools / 'sha256sum'
        hasher.write_text('#!/bin/sh\nprintf "' + 'a' * 64 + '  -\\n"\nexit 97\n')
        hasher.chmod(0o755)
        self.env['PATH'] = str(tools) + ':' + self.env['PATH']
        data = self.inspect()
        self.assertIsNone(data['provider']['sha256'])
        self.assertEqual(data['reason'], 'PROVIDER_UNREADABLE')

    def test_provider_growth_after_stat_never_publishes_prefix_hash(self):
        tools = self.base / 'bin'
        tools.mkdir()
        head = tools / 'head'
        head.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
if sys.argv[-1] == os.environ['HG_VTEST_PATH']:
    pathlib.Path(sys.argv[-1]).write_bytes(b'x' * 262145)
os.execvp(os.environ['HG_VTEST_TEST_BUSYBOX'], [os.environ['HG_VTEST_TEST_BUSYBOX'], 'head', *sys.argv[1:]])
""")
        head.chmod(0o755)
        self.env['PATH'] = str(tools) + ':' + self.env['PATH']
        data = self.inspect()
        self.assertIsNone(data['provider']['sha256'])
        self.assertEqual(data['reason'], 'PROVIDER_UNREADABLE')

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


    RAW_HEADER = 'run_id\tstage\tnode_id\tname\tround\tprovider\tstatus\tcurl_rc\thttp_code\tlatency_ms\tttfb_ms\tspeed_mbps\ttotal_sec\tbytes\terror\n'
    RAW_OK = '20261010-220000\tquick\tprivate-id\tPRIVATE_NODE\t1\tCF\tOK\t0\t200\t20\t30\t12.3\t2.1\t100\tPRIVATE_ERROR\n'

    def results(self):
        directory = self.base / 'results'
        directory.mkdir(exist_ok=True)
        (directory / 'history').mkdir(exist_ok=True)
        return directory

    def test_latest_real_schema_is_redacted_observations(self):
        directory = self.results()
        (directory / 'latest.tsv').write_text(self.RAW_HEADER + self.RAW_OK + self.RAW_OK.replace('\tOK\t', '\tFAIL\t'))
        data = self.inspect()
        self.assertEqual(data['latest']['speed'], dict(samples=2, success=1, failed=1))
        self.assertIsNone(data['latest']['summary'])
        self.assertFalse(data['run_supported'])
        self.assertEqual(data['state'], 'UNKNOWN')
        calls = self.poll(self.message())
        sent = next(c for c in calls if c[:2] == ['telegram', 'send-message'])
        self.assertIn('samples: 2', sent[3])
        self.assertNotIn('private-id', sent[3])
        self.assertNotIn('PRIVATE_', sent[3])

    def test_corrupt_oversized_and_symlink_results_fail_closed(self):
        directory = self.results()
        file = directory / 'latest.tsv'
        for text in (self.RAW_HEADER + self.RAW_OK.replace('\tOK\t', '\tWRONG\t'),
                     self.RAW_HEADER + self.RAW_OK.replace('12.3', 'nan'),
                     self.RAW_HEADER + 'x' * 262144, (self.RAW_HEADER + self.RAW_OK).rstrip('\n'), 'unrecognized schema\n'):
            file.write_text(text)
            self.assertIsNone(self.inspect()['latest']['speed'])
        file.unlink()
        file.symlink_to(self.provider)
        self.assertIsNone(self.inspect()['latest']['speed'])

    def test_history_caps_twenty_and_ignores_unsafe_names(self):
        directory = self.results()
        history = directory / 'history'
        for day in range(1, 26):
            (history / f'202610{day:02d}-220000.tsv').write_text(self.RAW_HEADER + self.RAW_OK)
        (history / 'PRIVATE_NAME.tsv').write_text(self.RAW_HEADER + self.RAW_OK)
        data = self.inspect()
        self.assertEqual(len(data['history']), 20)
        self.assertEqual(data['history'][0]['run_id'], '20261025-220000')
        self.assertEqual(data['history'][-1]['run_id'], '20261006-220000')
        self.assertTrue(all(row['speed']['samples'] == 1 for row in data['history']))

    def test_history_listing_budget_fails_closed(self):
        history = self.results() / 'history'
        for i in range(100):
            (history / (str(i) + 'x' * 140 + '.tsv')).write_text('')
        self.assertIsNone(self.inspect()['history'])

    def test_results_directory_symlink_refused(self):
        directory = self.results()
        (directory / 'latest.tsv').write_text(self.RAW_HEADER + self.RAW_OK)
        moved = self.base / 'moved'
        directory.rename(moved)
        directory.symlink_to(moved, target_is_directory=True)
        self.assertIsNone(self.inspect()['latest'])

    def test_summary_and_capability_actual_headers(self):
        directory = self.results()
        summary = 'node_id\tname\tscore\teligible\tmedian_mbps\tmedian_latency_ms\tsuccess_rate_pct\tspread_pct\tfailures\tstalls\tprovider_good\tcapability\tchatgpt_pass\topenai_pass\thttps_pass\tloc\tsource_stage\n'
        (directory / 'latest-summary.tsv').write_text(summary + 'private-id\tPRIVATE_NODE\t90.0\tYES\t12.1\t20\t100\t0\t0\t0\t2\tYES\t2\t2\t2\tXX\tdeep\n')
        cap = 'stage\tnode_id\tname\teligible\tgoogle_pass\tchatgpt_pass\topenai_pass\thttps_pass\tloc\n'
        (directory / 'latest-capability.tsv').write_text(cap + 'cap_only\tprivate-id\tPRIVATE_NODE\tNO\t0\t0\t0\t0\tXX\n')
        data = self.inspect()
        self.assertEqual(data['latest']['summary'], dict(nodes=1, eligible=1))
        self.assertEqual(data['latest']['capability'], dict(nodes=1, eligible=0))


if __name__ == '__main__':
    unittest.main()
