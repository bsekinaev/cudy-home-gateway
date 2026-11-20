"""Build an exact-commit, no-install monitoring readiness probe."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
MODULES = ('common', 'status', 'network', 'vpn', 'dns', 'torrent', 'redmi', 'asata', 'tailscale', 'health')


def build(output, ref='HEAD'):
    source = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--verify',
                                      '--end-of-options', ref + '^{commit}']).decode('ascii').strip()

    def committed(path):
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', source + ':' + path])

    script = b'#!/bin/sh\n# Owner-run read-only monitoring readiness; no installation.\n'
    script += ("HG_MONITOR_PROBE_SOURCE='" + source + "'\n").encode('ascii')
    for name in MODULES:
        script += committed('src/usr/lib/home-gateway/' + name + '.sh') + b'\n'
    script += committed('scripts/observability/router-monitor-probe-footer.sh')
    runner = committed('scripts/observability/check-monitor.ps1')
    if b'\r' in script:
        raise ValueError('CRLF in committed candidate shell source')
    output = Path(output)
    archive = output.with_suffix('.zip')
    if archive.exists():
        raise FileExistsError(archive)
    output.mkdir(parents=True, exist_ok=False)
    (output / 'router-monitor-probe.sh').write_bytes(script)
    (output / 'check-monitor.ps1').write_bytes(runner)
    (output / 'CHECK-MONITOR.cmd').write_bytes(
        b'@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-monitor.ps1"\r\npause\r\n')
    (output / 'SOURCE.txt').write_text(source + '\n', encoding='ascii', newline='\n')
    (output / 'README.txt').write_text(
        'Run CHECK-MONITOR.cmd explicitly. No installation or settings changes.\n'
        'The existing 2026-11-20 owner-session.json supplies the router identity.\n'
        'This performs normal bounded DNS/HTTPS monitoring checks and reads system resources.\n'
        'Only a private temporary directory is written; it is removed when the probe exits.\n'
        'The remote process has a 45-second deadline. An unhealthy health result is recorded.\n'
        'Send CUDY-Monitor-Readiness-*.txt from your Windows home directory.\n'
        'The report contains no public IP addresses or configuration secrets.\n', encoding='utf-8', newline='\n')
    (output / 'SHA256SUMS.txt').write_text(''.join(
        hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
        for p in sorted(output.iterdir())), encoding='ascii', newline='\n')
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as package:
        for path in sorted(output.iterdir()):
            package.write(path, path.name)
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--ref', default='HEAD')
    args = parser.parse_args()
    print(build(args.output, args.ref))
