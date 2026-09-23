"""Download only a successful CI release from this repository and allowed branch."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from transport import encode


def validate_run(run, repo, commit, branch):
    if (run.get('conclusion') != 'success' or run.get('status') != 'completed'
            or run.get('head_sha') != commit or run.get('head_branch') != branch
            or run.get('event') not in ('push', 'workflow_dispatch')
            or run.get('path') != '.github/workflows/ci.yml'
            or run.get('head_repository', {}).get('full_name') != repo):
        raise ValueError('Run must be successful CI for this exact commit and trusted branch')


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path]))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run-id', required=True)
    p.add_argument('--commit', required=True)
    p.add_argument('--branch', required=True)
    p.add_argument('--output', type=Path, default=Path('release-download'))
    args = p.parse_args()
    if not re.fullmatch(r'[0-9]+', args.run_id) or not re.fullmatch(r'[0-9a-f]{40}', args.commit):
        p.error('Numeric run ID and full lowercase commit SHA are required')
    repo = os.environ['GITHUB_REPOSITORY']
    run = api(f'repos/{repo}/actions/runs/{args.run_id}')
    validate_run(run, repo, args.commit, args.branch)
    name = 'home-gateway-' + args.commit
    artifacts = api(f'repos/{repo}/actions/runs/{args.run_id}/artifacts?per_page=100')['artifacts']
    matches = [a for a in artifacts if a['name'] == name and not a['expired']]
    if len(matches) != 1:
        raise ValueError('Expected one unexpired release artifact')
    args.output.mkdir(exist_ok=False)
    subprocess.run(['gh', 'run', 'download', args.run_id, '--repo', repo, '--name', name,
                    '--dir', str(args.output)], check=True)
    archives = list(args.output.glob('*.tar.gz'))
    if len(archives) != 1:
        raise ValueError('Expected one release archive')
    archive = archives[0]
    checksum = Path(str(archive) + '.sha256').read_text(encoding='ascii').strip().split()
    if len(checksum) != 2 or checksum[1] != archive.name:
        raise ValueError('Invalid checksum file')
    encode(archive, args.commit, checksum[0])  # Full manifest and protocol verification before joining tailnet.
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        output.write(f'archive={archive.resolve()}\nsha256={checksum[0]}\n')
    print(f'CI_RELEASE_VERIFIED run={args.run_id} commit={args.commit}')


if __name__ == '__main__':
    main()
