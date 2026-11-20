"""Build a no-install owner test from the exact local observer definitions."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def build(output, ref='HEAD'):
    source = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--verify',
                                      '--end-of-options', ref+'^{commit}']).decode().strip()

    def committed(path):
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', source+':'+path])

    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    script = b'#!/bin/sh\n# Read-only candidate DNS test; no installed runtime files.\n'
    for name in ('common.sh', 'dns.sh', 'redmi.sh'):
        script += committed('src/usr/lib/home-gateway/'+name) + b'\n'
    script += committed('scripts/observability/router-redmi-probe-footer.sh')
    if b'\r' in script:
        raise ValueError('CRLF in candidate shell source')
    (output / 'router-redmi-probe.sh').write_bytes(script)
    (output / 'check-redmi.ps1').write_bytes(committed('scripts/observability/check-redmi.ps1'))
    (output / 'CHECK-REDMI.cmd').write_bytes(
        b'@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-redmi.ps1"\r\npause\r\n')
    (output / 'SOURCE.txt').write_bytes((source+'\n').encode('ascii'))
    (output / 'README.txt').write_text(
        'Run CHECK-REDMI.cmd. This is a no-install read-only candidate test.\n'
        'It uses the existing owner session address/port and performs DNS queries.\n'
        'It does not change UCI, firewall, services or installed runtime files.\n'
        'Send CUDY-REDMI-Probe-*.txt from your Windows home directory.\n', encoding='utf-8')
    (output / 'SHA256SUMS.txt').write_text(''.join(
        hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
        for p in sorted(output.iterdir())), encoding='ascii', newline='\n')
    archive = output.with_suffix('.zip')
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as z:
        for path in sorted(output.iterdir()):
            z.write(path, path.name)
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--ref', default='HEAD')
    args = parser.parse_args()
    print(build(args.output, args.ref))
