"""Discovery output must never disclose unrelated generated configuration."""
import json
import os
import shlex
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/observability/router-dns-preflight.sh'


class PreflightTests(unittest.TestCase):
    def test_shell_transport_without_base64(self):
        with tempfile.TemporaryDirectory() as temporary:
            real_busybox = shutil.which('busybox')
            wrapper = Path(temporary) / 'busybox'
            wrapper.write_text('#!/bin/sh\n[ "$1" != base64 ] || exit 99\nexec '
                               + shlex.quote(real_busybox) + ' "$@"\n')
            wrapper.chmod(0o755)
            captured = os.environ.get('HG_DNS_TRANSPORT_COMMAND_FILE')
            if captured:
                command = Path(captured).read_text()
            else:
                encoded = ''.join('\\0%03o' % b for b in SCRIPT.read_bytes())
                command = "printf '%b' '" + encoded + "' | sh -s -- 'acl_A2dNs'"
            result = subprocess.run([real_busybox, 'ash', '-c', command],
                env=dict(os.environ, PATH=temporary + ':' + os.environ['PATH'],
                         HG_DNS_PREFLIGHT_CONFIG='/missing'),
                capture_output=True, text=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.startswith('HG_DNS_DISCOVERY_V1\n'))
            self.assertEqual(len(result.stdout.splitlines()), 9)
            self.assertIn('network_changes=none', result.stdout)

    def test_disabled_and_invalid_router_ports_are_labelled(self):
        with tempfile.TemporaryDirectory() as temporary:
            uci = Path(temporary) / 'uci'
            uci.write_text('#!/bin/sh\nprintf "%s" "$HG_TEST_PORT"\n')
            uci.chmod(0o755)
            for port, expected in [('0', 'disabled'), ('65536', 'invalid'),
                                   ('00053', 'invalid'), ('53', '53')]:
                env = dict(os.environ, PATH=temporary + ':' + os.environ['PATH'],
                           HG_TEST_PORT=port, HG_DNS_PREFLIGHT_CONFIG='/missing')
                result = subprocess.run(['busybox', 'ash', str(SCRIPT)], env=env,
                                        capture_output=True, text=True, timeout=8)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('router_dns_port=' + expected + '\n', result.stdout)
                self.assertIn('network_changes=none', result.stdout)

    def test_runtime_report_contains_only_safe_endpoint_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / 'profile.json'
            config.write_text(json.dumps(dict(
                outbounds=[dict(secret='DO_NOT_DISCLOSE_ABC')],
                inbounds=[dict(tag='dns-in', listen='127.0.0.1', port=2007,
                               protocol='dokodemo-door', settings=dict(secret='PRIVATE'))])))
            env = dict(os.environ, HG_DNS_PREFLIGHT_CONFIG=str(config))
            result = subprocess.run(['busybox', 'ash', str(SCRIPT)], env=env,
                                    capture_output=True, text=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('HG_DNS_DISCOVERY_V1', result.stdout)
            self.assertIn('busybox_awk=supported', result.stdout)
            endpoints = next(line.split('=', 1)[1] for line in result.stdout.splitlines()
                             if line.startswith('runtime_dns='))
            self.assertEqual(json.loads(endpoints), [dict(port=2007, loopback=True,
                                                       protocol='dokodemo-door')])
            self.assertNotIn('DO_NOT_DISCLOSE', result.stdout + result.stderr)
            self.assertNotIn('PRIVATE', result.stdout + result.stderr)
            self.assertNotIn(str(config), result.stdout)

    def test_malformed_json_produces_no_config_dump(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / 'profile.json'
            config.write_text('{"secret":"DO_NOT_DISCLOSE" broken')
            result = subprocess.run(['busybox', 'ash', str(SCRIPT)],
                env=dict(os.environ, HG_DNS_PREFLIGHT_CONFIG=str(config)),
                capture_output=True, text=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('runtime=unreadable_or_unsupported', result.stdout)
            self.assertNotIn('DO_NOT_DISCLOSE', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
