"""Real DNS query with synthetic process/socket boundary, never a client ping."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

from test_dns import Resolver, ROOT, BUSYBOX


class RedmiDNSTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.server = Resolver('ok')
        self.addCleanup(self.server.close)
        self.config = self.base / 'acl_test.json'
        self.proc = self.base / 'proc'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.node = self.base / 'node'
        self.node.write_text('node_a\n')
        uci = self.bin / 'uci'
        uci.write_text('#!/bin/sh\ncase "$*" in *.enabled) echo 1;; *.node) cat '
                       + shlex.quote(str(self.node)) + ';; *) echo acl_rule;; esac\n')
        uci.chmod(0o755)
        self.configure()
        self.process()
        (self.proc / 'net').mkdir()
        self.udp()

    def configure(self, protocol='tunnel', port=None, listen='127.0.0.1', duplicate=False):
        item = dict(tag='dns-in', listen=listen, port=port or self.server.port,
                    protocol=protocol, settings=dict(allowedNetwork='tcp,udp', network='tcp,udp'))
        self.config.write_text(json.dumps(dict(inbounds=[item, item] if duplicate else [item],
                                               private='DO_NOT_ECHO')))

    def process(self, pid='301', path=None, owner=True, start='12345'):
        directory = self.proc / pid
        directory.mkdir(exist_ok=True, parents=True)
        (directory / 'fd').mkdir(exist_ok=True)
        (directory / 'exe').symlink_to('/usr/bin/xray')
        (directory / 'cmdline').write_bytes(b'xray\0run\0-c\0' + str(path or self.config).encode() + b'\0')
        (directory / 'stat').write_text(f'{pid} (xray) S ' + ' '.join(['0'] * 18 + [start]) + '\n')
        if owner:
            (directory / 'fd/3').symlink_to('socket:[555]')

    def udp(self, inode='555'):
        (self.proc / 'net/udp').write_text(
            'sl local_address rem_address st queues timer retr uid timeout inode\n'
            f'0: 0100007F:{self.server.port:04X} 00000000:0000 07 0:0 0:0 0 0 0 {inode}\n')

    def collect(self, prefix='', proc=None):
        command = f'''
. {shlex.quote(str(ROOT / 'src/usr/lib/home-gateway/dns.sh'))}
. {shlex.quote(str(ROOT / 'src/usr/lib/home-gateway/redmi.sh'))}
HG_REDMI_ACL_PROFILE=acl_test
HG_REDMI_NODE=node_a
HG_REDMI_CONFIG_STATE=OK
HG_REDMI_XRAY_STATE=OK
{prefix}
hg_redmi_dns_collect
printf '%s|%s|%s|%s\\n' "$HG_REDMI_DNS_STATE" "$HG_REDMI_DNS_REASON" "$HG_REDMI_DNS_PORT" "$HG_REDMI_DNS_SOURCE"
'''
        result = subprocess.run([BUSYBOX, 'ash', '-c', command], text=True,
            env=dict(os.environ, HG_REDMI_RUNTIME_CONFIG=str(self.config),
                     HG_REDMI_PROC_ROOT=str(proc or self.proc), PATH=str(self.bin)+':'+os.environ['PATH']),
            capture_output=True, timeout=16)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('not found', result.stderr)
        self.assertNotIn('DO_NOT_ECHO', result.stdout + result.stderr)
        return result.stdout.strip()

    def test_bound_tunnel_query_succeeds_without_phone(self):
        self.assertEqual(self.collect(), f'OK|answer|{self.server.port}|live_probe')
        self.assertTrue(self.server.queries)

    def test_live_procfs_owner_and_socket_are_detected(self):
        executable = self.base / 'xray'
        built = subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-O2',
                                str(ROOT/'scripts/observability/dns-fixture.c'), '-o', str(executable)],
                               capture_output=True, text=True, timeout=20)
        self.assertEqual(built.returncode, 0, built.stderr)
        process = subprocess.Popen([str(executable), 'run', '-c', str(self.config)],
                                   stdout=subprocess.PIPE, text=True)
        try:
            port = int(process.stdout.readline())
            self.configure(port=port)
            self.assertEqual(self.collect(proc='/proc'), f'OK|answer|{port}|live_probe')
        finally:
            process.terminate()
            process.wait(timeout=5)
            process.stdout.close()

    def test_missing_proc_data_is_unknown_without_query(self):
        (self.proc / 'net/udp').unlink()
        self.assertTrue(self.collect().startswith('UNKNOWN|runtime_unverified|'))
        self.assertEqual(self.server.queries, [])

    def test_missing_configuration_is_unknown_without_query(self):
        self.config.unlink()
        self.assertTrue(self.collect().startswith('UNKNOWN|runtime_unverified|'))
        self.assertEqual(self.server.queries, [])

    def test_stalled_snapshot_is_bounded(self):
        uci = self.bin / 'uci'
        uci.write_text('#!/bin/sh\ntrap "" TERM\nsleep 30\n')
        started = time.monotonic()
        self.assertTrue(self.collect().startswith('UNKNOWN|runtime_unverified|'))
        self.assertLess(time.monotonic()-started, 5.5)
        self.assertEqual(self.server.queries, [])

    def test_silent_profile_dns_is_failed_without_changing_egress(self):
        self.server.mode = 'silence'
        self.assertEqual(self.collect(), f'DOWN|query_failed|{self.server.port}|live_probe')

    def test_legacy_dokodemo_udp_is_supported(self):
        self.configure(protocol='dokodemo-door')
        self.assertTrue(self.collect().startswith('OK|answer|'))

    def test_duplicate_endpoints_or_processes_are_unknown(self):
        self.configure(duplicate=True)
        self.assertTrue(self.collect().startswith('UNKNOWN|runtime_unverified|'))
        self.assertEqual(self.server.queries, [])
        self.configure()
        self.process(pid='302')
        self.assertTrue(self.collect().startswith('UNKNOWN|runtime_unverified|'))
        self.assertEqual(self.server.queries, [])

    def test_same_path_prefix_is_not_matching_process(self):
        (self.proc / '301/cmdline').write_bytes(b'xray\0-c\0'+str(self.config).encode()+b'.other\0')
        self.assertTrue(self.collect().startswith('UNKNOWN|runtime_unverified|'))
        self.assertEqual(self.server.queries, [])

    def test_socket_owned_by_other_process_is_not_probed(self):
        self.udp(inode='999')
        self.assertTrue(self.collect().startswith('UNKNOWN|runtime_unverified|'))
        self.assertEqual(self.server.queries, [])

    def test_non_loopback_endpoint_is_not_probed(self):
        self.configure(listen='0.0.0.0')
        self.assertTrue(self.collect().startswith('UNKNOWN|runtime_unverified|'))
        self.assertEqual(self.server.queries, [])

    def test_node_changed_during_query_discards_success(self):
        prefix = f'''hg_dns_probe() {{
HG_DNS_PROBE_STATE=OK; HG_DNS_PROBE_REASON=answer
printf 'node_b\\n' > {shlex.quote(str(self.node))}
}}'''
        self.assertTrue(self.collect(prefix).startswith('UNKNOWN|runtime_changed|'))

    def test_configuration_changed_during_query_discards_success(self):
        prefix = f'''hg_dns_probe() {{
HG_DNS_PROBE_STATE=OK; HG_DNS_PROBE_REASON=answer
printf ' ' >> {shlex.quote(str(self.config))}
}}'''
        self.assertTrue(self.collect(prefix).startswith('UNKNOWN|runtime_changed|'))

    def test_missing_query_tool_is_not_live_evidence(self):
        prefix = '''hg_dns_probe() {
HG_DNS_PROBE_STATE=UNKNOWN; HG_DNS_PROBE_REASON=tool_unavailable
}'''
        self.assertEqual(self.collect(prefix),
                         f'UNKNOWN|tool_unavailable|{self.server.port}|unverified')

    def test_process_restart_during_query_discards_success(self):
        stat = self.proc / '301/stat'
        prefix = f'''hg_dns_probe() {{
HG_DNS_PROBE_STATE=OK; HG_DNS_PROBE_REASON=answer
printf '%s\\n' '301 (xray) S {' '.join(['0'] * 18 + ['54321'])}' > {shlex.quote(str(stat))}
}}'''
        self.assertTrue(self.collect(prefix).startswith('UNKNOWN|runtime_changed|'))

    def test_socket_replaced_during_query_discards_success(self):
        udp = self.proc / 'net/udp'
        fd = self.proc / '301/fd/3'
        prefix = f'''hg_dns_probe() {{
HG_DNS_PROBE_STATE=OK; HG_DNS_PROBE_REASON=answer
sed -i 's/555/999/' {shlex.quote(str(udp))}
rm {shlex.quote(str(fd))}; ln -s 'socket:[999]' {shlex.quote(str(fd))}
}}'''
        self.assertTrue(self.collect(prefix).startswith('UNKNOWN|runtime_changed|'))

    def test_policy_not_ready_does_not_probe(self):
        self.assertEqual(self.collect('HG_REDMI_CONFIG_STATE=DOWN'),
                         'UNKNOWN|profile_unavailable||unverified')
        self.assertEqual(self.server.queries, [])


if __name__ == '__main__':
    unittest.main()
