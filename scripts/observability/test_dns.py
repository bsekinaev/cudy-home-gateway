"""Real BusyBox DNS adapter against an isolated loopback UDP resolver."""
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
DNS = Path(os.environ.get('HG_DNS_TEST_ADAPTER', ROOT / 'src/usr/lib/home-gateway/dns.sh'))
BUSYBOX = os.environ.get('HG_TEST_BUSYBOX', 'busybox')


class Resolver:
    def __init__(self, mode):
        self.mode = mode
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.settimeout(.1)
        self.port = self.sock.getsockname()[1]
        self.stop = threading.Event()
        self.queries = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                data, peer = self.sock.recvfrom(4096)
            except socket.timeout:
                continue
            self.queries.append(data)
            if self.mode == 'silence':
                continue
            end = 12
            while data[end]:
                end += data[end] + 1
            question = data[12:end+5]
            answer = (b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 30, 4)
                      + socket.inet_aton('192.0.2.7')) if self.mode == 'ok' else b''
            flags = 0x8183 if self.mode == 'nxdomain' else 0x8180
            response = data[:2] + struct.pack('!HHHHH', flags, 1, bool(answer), 0, 0)
            self.sock.sendto(response + question + answer, peer)

    def close(self):
        self.stop.set()
        self.thread.join(1)
        self.sock.close()


class DNSProbeTests(unittest.TestCase):
    def resolver(self, mode):
        server = Resolver(mode)
        self.addCleanup(server.close)
        return server

    def probe(self, port, domain='probe.invalid', prefix=''):
        command = (f'. {shlex.quote(str(DNS))}\n' + prefix
                   + f'\nhg_dns_probe {shlex.quote(domain)} {shlex.quote(str(port))}\n'
                   + 'printf "%s|%s\\n" "$HG_DNS_PROBE_STATE" "$HG_DNS_PROBE_REASON"')
        result = subprocess.run([BUSYBOX, 'ash', '-c', command],
                                text=True, capture_output=True, timeout=7)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('not found', result.stderr)
        return result.stdout.strip()

    def test_success_uses_nonstandard_port(self):
        server = self.resolver('ok')
        self.assertEqual(self.probe(server.port), 'OK|answer')
        self.assertTrue(server.queries)
        self.assertEqual(server.queries[0][-4:], b'\x00\x01\x00\x01')

    def test_nxdomain_is_down(self):
        self.assertEqual(self.probe(self.resolver('nxdomain').port), 'DOWN|query_failed')

    def test_empty_noerror_is_not_success(self):
        self.assertTrue(self.probe(self.resolver('empty').port).startswith('DOWN|'))

    def test_silence_has_overall_deadline(self):
        server = self.resolver('silence')
        started = time.monotonic()
        self.assertTrue(self.probe(server.port).startswith('DOWN|'))
        self.assertLess(time.monotonic() - started, 5.5)

    def test_invalid_port_is_unknown_without_query(self):
        for port in ('0', '65536', '-1', '53;true', 'abc', '00053'):
            with self.subTest(port=port):
                self.assertEqual(self.probe(port), 'UNKNOWN|invalid_endpoint')

    def test_invalid_domain_is_unknown_without_query(self):
        server = self.resolver('ok')
        for domain in ('-debug', 'name;true', '', 'bad name'):
            self.assertEqual(self.probe(server.port, domain), 'UNKNOWN|invalid_domain')
        self.assertEqual(server.queries, [])

    def test_missing_tool_is_unknown(self):
        self.assertEqual(self.probe(53, prefix='PATH=/nonexistent'), 'UNKNOWN|tool_unavailable')

    def test_collection_uses_configured_port(self):
        server = self.resolver('ok')
        command = f'''
. {shlex.quote(str(DNS))}
ps() {{ printf '/usr/sbin/dnsmasq\\n'; }}
uci() {{ case "$*" in *dnsmasq*port*) printf '%s' {server.port} ;; esac; }}
hg_dns_collect
printf '%s|%s|%s\\n' "$HG_DNS_STATE" "$HG_DNS_RESOLUTION_STATE" "$HG_DNS_PORT"
'''
        result = subprocess.run([BUSYBOX, 'ash', '-c', command], text=True,
                                capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f'OK|OK|{server.port}')
        self.assertTrue(server.queries)


if __name__ == '__main__':
    unittest.main()
