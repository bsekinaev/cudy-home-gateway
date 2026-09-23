"""Install the trusted CD receiver over the existing administrative LAN SSH connection."""
import argparse
from pathlib import Path
import re
import subprocess


def run(args, **kw):
    return subprocess.run(args, check=True, **kw)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--key', type=Path, default=Path('local/cudy-cd'))
    args = p.parse_args()
    args.key.parent.mkdir(parents=True, exist_ok=True)
    if not args.key.exists():
        # Python passes the empty passphrase correctly even on Windows PowerShell 5.
        if Path(str(args.key) + '.pub').exists():
            raise ValueError('Public key exists without private key; select a new key path')
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'cudy-cd', '-f', str(args.key)])
    public = subprocess.check_output(['ssh-keygen', '-y', '-P', '', '-f', str(args.key)]).strip()
    if not re.fullmatch(rb'ssh-ed25519 [A-Za-z0-9+/=]{68}(?: .*|)', public):
        raise ValueError('An Ed25519 deployment key is required')
    public = b' '.join(public.split()[:2]) + b'\n'
    pub = Path(str(args.key) + '.pub')
    pub.write_bytes(public)
    ssh = ['ssh', '-o', 'StrictHostKeyChecking=yes', 'root@192.168.1.1']
    remote = subprocess.check_output(ssh + ['umask 077; mktemp -d /tmp/cudy-cd-bootstrap.XXXXXX']).decode().strip()
    if not re.fullmatch(r'/tmp/cudy-cd-bootstrap\.[A-Za-z0-9]+', remote):
        raise ValueError('Unexpected staging path')
    here = Path(__file__).resolve().parent
    for name in ('bootstrap.sh', 'engine.sh', 'wrapper.sh', 'recovery.init'):
        run(['scp', '-O', '-o', 'StrictHostKeyChecking=yes', str(here / name), f'root@192.168.1.1:{remote}/{name}'])
    run(['scp', '-O', '-o', 'StrictHostKeyChecking=yes', str(pub), f'root@192.168.1.1:{remote}/deploy.pub'])
    run(ssh + [f'sh {remote}/bootstrap.sh'])
    host = subprocess.check_output(ssh + ['dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key']).decode()
    match = re.search(r'^ssh-ed25519 ([A-Za-z0-9+/=]+)', host, re.M)
    if not match:
        raise ValueError('Missing Ed25519 host key')
    known = args.key.parent / 'cudy-cd-known-hosts'
    known.write_bytes(f'[100.84.35.92]:2223 ssh-ed25519 {match[1]}\n'.encode())
    print('BOOTSTRAP_CLIENT_OK')
    print(f'Private key (keep local): {args.key}')
    print(f'Pinned host key: {known}')


if __name__ == '__main__':
    main()
