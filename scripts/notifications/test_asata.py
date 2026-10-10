"""Exercise the production ASATA collector with BusyBox ash/awk and nft output fixtures."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AsataTests(unittest.TestCase):
    def collect(self, rules):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'rules').write_text(rules)
            (base / 'leases').write_text('0 58:04:4f:81:09:6b 192.168.1.140 asata *\n')
            for name, script in {
                'nft': '#!/bin/sh\ncat "$HG_FIXTURE_RULES"\n',
                'ping': '#!/bin/sh\nexit 0\n',
                'ip': '#!/bin/sh\nexit 0\n',
                'keeper': '#!/bin/sh\nexit 0\n',
            }.items():
                path = base / name
                path.write_text(script)
                path.chmod(0o755)
            busybox = os.environ.get('HG_TEST_BUSYBOX', 'busybox')
            awk = base / 'awk'
            awk.write_text('#!/bin/sh\nexec ' + shlex.quote(busybox) + ' awk "$@"\n')
            awk.chmod(0o755)
            env = dict(os.environ, PATH=str(base) + ':' + os.environ['PATH'],
                       HG_FIXTURE_RULES=str(base / 'rules'), HG_ASATA_LEASE_FILE=str(base / 'leases'),
                       HG_ASATA_INIT_SCRIPT=str(base / 'keeper'), HG_ASATA_KEEPER_PATH=str(base / 'keeper'))
            script = '. "$1"; hg_asata_collect; printf "%s %s %s %s\\n" "$HG_ASATA_RULE_STATE" "$HG_ASATA_RULES" "$HG_ASATA_RULE_PACKETS" "$HG_ASATA_RULE_BYTES"'
            result = subprocess.run([busybox, 'ash', '-c', script, 'test',
                                     str(ROOT / 'src/usr/lib/home-gateway/asata.sh')],
                                    env=env, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()

    def rule(self):
        return '    ip saddr 192.168.1.140 meta l4proto udp counter packets 12 bytes 345 return comment "ASATA-UDP-DIRECT" # handle 7\n'

    def test_exact_rule_and_counters(self):
        self.assertEqual(self.collect(self.rule()), 'OK 1 12 345')

    def test_wrong_semantics_fail_closed(self):
        for rule in [self.rule().replace('.140 ', '.1400 '),
                     self.rule().replace('.140 ', '.140/24 '),
                     self.rule().replace('udp ', 'tcp '),
                     self.rule().replace('return ', 'accept '),
                     self.rule().replace('return ', 'meta mark set 1 return '),
                     self.rule().replace('counter ', 'udp dport 53 counter '),
                     self.rule().replace('packets 12', 'packets invalid')]:
            with self.subTest(rule=rule):
                self.assertEqual(self.collect(rule), 'DOWN 1 0 0')

    def test_duplicate_is_degraded(self):
        self.assertEqual(self.collect(self.rule() * 2), 'DEGRADED 2 24 690')

    def test_missing_rule(self):
        self.assertEqual(self.collect(''), 'DOWN 0 0 0')


if __name__ == '__main__':
    unittest.main()
