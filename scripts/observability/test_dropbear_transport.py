"""Opt-in Windows OpenSSH -> disposable loopback Dropbear integration.

Set HG_DNS_DROPBEAR_IMAGE to a local image containing sh/dropbear/dropbearkey.
Never reads an owner session, SSH config or router address.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest
from build_probe import build

ROOT = Path(__file__).resolve().parents[2]
IMAGE = os.environ.get('HG_DNS_DROPBEAR_IMAGE')


@unittest.skipUnless(sys.platform == 'win32' and IMAGE, 'opt-in Windows/Dropbear fixture')
class DropbearTransportTests(unittest.TestCase):
    def test_old_long_command_refused_and_new_stdin_succeeds(self):
        docker = os.environ.get('HG_DNS_TEST_DOCKER', 'docker')
        windows = Path(os.environ['SystemRoot'])
        powershell = windows / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        ssh = windows / 'System32/OpenSSH/ssh.exe'
        keygen = windows / 'System32/OpenSSH/ssh-keygen.exe'

        def run(args, **kwargs):
            return subprocess.run([str(x) for x in args], capture_output=True,
                                  text=True, timeout=40, **kwargs)

        with tempfile.TemporaryDirectory(prefix='cudy-dns-dropbear-') as temporary:
            base = Path(temporary)
            key = base / 'client'
            generated = run([keygen, '-q', '-t', 'ed25519', '-N', '', '-f', key])
            self.assertEqual(generated.returncode, 0, generated.stderr)
            public = base / 'client.pub'
            server = run([docker, 'run', '-d', '--rm', '-p', '127.0.0.1::2222',
                          '--mount', f'type=bind,source={public},target=/fixture/client.pub,readonly',
                          IMAGE, 'sh', '-c',
                          'umask 077; mkdir -p /root/.ssh; cp /fixture/client.pub /root/.ssh/authorized_keys; '
                          'dropbearkey -t ed25519 -f /tmp/fixture-hostkey >/dev/null 2>&1; '
                          'exec dropbear -F -E -s -r /tmp/fixture-hostkey -p 2222'])
            self.assertEqual(server.returncode, 0, server.stderr)
            container = server.stdout.strip()
            self.assertRegex(container, r'^[0-9a-f]{64}$')
            try:
                port_result = run([docker, 'port', container, '2222/tcp'])
                match = re.fullmatch(r'127\.0\.0\.1:([0-9]+)\s*', port_result.stdout)
                self.assertIsNotNone(match, port_result.stdout)
                port = int(match[1])
                host_public = None
                for _ in range(30):
                    result = run([docker, 'exec', container, 'dropbearkey', '-y', '-f', '/tmp/fixture-hostkey'])
                    host_public = next((line for line in result.stdout.splitlines()
                                        if line.startswith('ssh-ed25519 ')), None)
                    if host_public:
                        break
                    time.sleep(.1)
                self.assertIsNotNone(host_public)
                known = base / 'known_hosts'
                known.write_text(f'[127.0.0.1]:{port} ' + ' '.join(host_public.split()[:2]) + '\n')
                session = base / 'session.json'
                session.write_text(json.dumps(dict(format='HG_OWNER_SERIES_SESSION_V1',
                                                   target='root@127.0.0.1', port=port)))
                harness = base / 'harness.ps1'
                harness.write_text('''param($Runner,$Session,$Report)
$ErrorActionPreference='Stop'
function global:ssh {
    $input | & $env:HG_DNS_FIXTURE_SSH -F NUL -i $env:HG_DNS_FIXTURE_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ("UserKnownHostsFile="+$env:HG_DNS_FIXTURE_KNOWN) @args
    $global:LASTEXITCODE=$LASTEXITCODE
}
& $Runner -SessionFile $Session -ReportFile $Report
''', encoding='ascii')
                env = dict(os.environ, HG_DNS_FIXTURE_SSH=str(ssh),
                           HG_DNS_FIXTURE_KEY=str(key), HG_DNS_FIXTURE_KNOWN=str(known))
                old_dir = base / 'old'
                old_dir.mkdir()
                old_runner = old_dir / 'check-dns.ps1'
                old_runner.write_bytes(subprocess.check_output([
                    'git', '-C', str(ROOT), 'show', 'c990294:scripts/observability/check-dns.ps1']))
                (old_dir / 'router-dns-preflight.sh').write_bytes(
                    (ROOT / 'scripts/observability/router-dns-preflight.sh').read_bytes())

                def invoke(runner, name):
                    return run([powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                '-File', harness, '-Runner', runner, '-Session', session,
                                '-Report', base / name], env=env)

                old = invoke(old_runner, 'old-report.txt')
                self.assertNotEqual(old.returncode, 0, old.stdout)
                self.assertFalse((base / 'old-report.txt').exists())
                new = invoke(ROOT / 'scripts/observability/check-dns.ps1', 'new-report.txt')
                self.assertEqual(new.returncode, 0, new.stdout + new.stderr)
                report = (base / 'new-report.txt').read_text().splitlines()
                self.assertEqual(len(report), 9)
                self.assertEqual(report[0], 'HG_DNS_DISCOVERY_V1')
                self.assertEqual(report[-1], 'network_changes=none')
                probe_dir = base / 'candidate-probe'
                build(probe_dir)
                candidate = invoke(probe_dir / 'check-redmi.ps1', 'candidate-report.txt')
                self.assertEqual(candidate.returncode, 0, candidate.stdout + candidate.stderr)
                candidate_report = (base / 'candidate-report.txt').read_text().splitlines()
                self.assertEqual(candidate_report[0], 'HG_REDMI_DNS_TEST_V1')
                self.assertEqual(json.loads(candidate_report[1])['client_internet'], 'unverified')
                print('REAL_DROPBEAR: old command refused; stdin report received; loopback only')
            finally:
                run([docker, 'rm', '-f', container])


if __name__ == '__main__':
    unittest.main()
