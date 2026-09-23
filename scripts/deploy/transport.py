"""Convert a verified release into the bounded, fixed-path router protocol."""
import argparse
import base64
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'release'))
from verify import verify

PATHS = ['etc/init.d/home-gateway-telegram', 'usr/bin/gateway', 'usr/bin/home-gateway-ci-smoke'] + [
    'usr/lib/home-gateway/' + n for n in (
        'asata.sh', 'common.sh', 'dns.sh', 'doctor.sh', 'health.sh', 'incidents.uc',
        'network.sh', 'redmi.sh', 'selftest.sh', 'status.sh', 'tailscale.sh',
        'telegram-poller.uc', 'telegram.sh', 'torrent.sh', 'vpn.sh')]


def encode(archive, commit, digest):
    # Freeze bytes so the file cannot change between verification and encoding.
    import tempfile
    with Path(archive).open('rb') as source:
        raw = source.read(8 * 1024 * 1024 + 1)
    if len(raw) > 8 * 1024 * 1024:
        raise ValueError('Archive too large')
    with tempfile.TemporaryDirectory() as tmp:
        frozen = Path(tmp) / 'release.tar.gz'
        frozen.write_bytes(raw)
        manifest, _ = verify(frozen, commit, digest)
    if {r['path'] for r in manifest['files']} != set(PATHS):
        raise ValueError('Runtime inventory changed; update the trusted receiver first')
    lines = [f'HGDEPLOY1 {commit}\n'.encode()]
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as tar:
        for path in PATHS:
            member = tar.getmember('payload/' + path)
            data = tar.extractfile(member).read()
            mode = 0o755 if path in PATHS[:3] else 0o644
            if member.mode != mode or len(data) > 262144:
                raise ValueError('Unsupported file mode/size: ' + path)
            lines.append(f'{mode:04o} {len(data)} {hashlib.sha256(data).hexdigest()}\n'.encode())
            lines.append(base64.b64encode(data) + b'\n')
    request = b''.join(lines) + b'END\n'
    if len(request) > 1048576:
        raise ValueError('Request too large')
    return request


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('operation', choices=['plan', 'apply', 'status', 'recover', 'rollback'])
    p.add_argument('--archive', type=Path)
    p.add_argument('--commit')
    p.add_argument('--sha256')
    p.add_argument('--host', default='100.84.35.92')
    p.add_argument('--port', type=int, default=2223)
    p.add_argument('--key', type=Path, required=True)
    p.add_argument('--known-hosts', type=Path, required=True)
    args = p.parse_args()
    # This client only targets the configured CUDY; no option injection.
    import ipaddress
    ipaddress.ip_address(args.host)
    if not 1 <= args.port <= 65535:
        p.error('Invalid port')
    request = b''
    command = args.operation
    if args.operation in ('plan', 'apply'):
        if not all((args.archive, args.commit, args.sha256)):
            p.error('archive, commit and sha256 are required')
        request = encode(args.archive, args.commit, args.sha256)
        command += ' ' + args.commit + ' ' + hashlib.sha256(request).hexdigest()
    ssh = ['ssh', '-T', '-p', str(args.port), '-i', str(args.key),
           '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'PasswordAuthentication=no',
           '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + str(args.known_hosts),
           '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4',
           'root@' + args.host, command]
    result = subprocess.run(ssh, input=request, timeout=900)
    return result.returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.TimeoutExpired) as e:
        sys.exit(f'Deployment transport failed: {e}')
