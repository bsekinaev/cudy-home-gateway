"""One-time production environment configuration using the user's authenticated gh CLI."""
import argparse
import getpass
import json
from pathlib import Path
import subprocess

REPO = 'bsekinaev/cudy-home-gateway'


def api(method, endpoint, body=None):
    cmd = ['gh', 'api', '--method', method, endpoint]
    data = None
    if body is not None:
        cmd += ['--input', '-']
        data = json.dumps(body).encode()
    return json.loads(subprocess.check_output(cmd, input=data) or b'{}')


def secret(name, value):
    subprocess.run(['gh', 'secret', 'set', name, '--repo', REPO, '--env', 'production'],
                   input=value, check=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--branch', default='feature/health-alerts')
    p.add_argument('--key', type=Path, default=Path('local/cudy-cd'))
    p.add_argument('--known-hosts', type=Path, default=Path('local/cudy-cd-known-hosts'))
    args = p.parse_args()
    key, hosts = args.key.read_bytes(), args.known_hosts.read_bytes()
    # Read credentials interactively, never from command-line arguments or logs.
    client = getpass.getpass('Tailscale CD client ID: ').strip().encode()
    audience = getpass.getpass('Tailscale CD audience: ').strip().encode()
    if not client or not audience or not key or not hosts:
        raise ValueError('All credentials are required')
    user = api('GET', 'user')
    endpoint = f'repos/{REPO}/environments/production'
    api('PUT', endpoint, {
        'wait_timer': 0, 'prevent_self_review': False,
        'reviewers': [{'type': 'User', 'id': user['id']}],
        'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True},
    })
    policies = api('GET', endpoint + '/deployment-branch-policies')['branch_policies']
    if any(item['name'] != args.branch for item in policies):
        raise ValueError('Existing environment allows other branches; review its branch policies manually')
    if not policies:
        api('POST', endpoint + '/deployment-branch-policies', {'name': args.branch, 'type': 'branch'})
    subprocess.run(['gh', 'variable', 'set', 'CD_ALLOWED_REF', '--repo', REPO,
                    '--env', 'production', '--body', 'refs/heads/' + args.branch], check=True)
    for name, value in [('TS_CD_CLIENT_ID', client), ('TS_CD_AUDIENCE', audience),
                        ('CUDY_CD_SSH_KEY', key), ('CUDY_CD_KNOWN_HOSTS', hosts)]:
        secret(name, value)
    print('GITHUB_PRODUCTION_CONFIGURED')


if __name__ == '__main__':
    main()
