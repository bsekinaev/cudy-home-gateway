"""Offline documentary gate for stable bundles; no network or router operations.

The gate checks exact immutable runtime identity and recorded acceptance. It does
not authenticate external evidence: maintainers must verify the linked results.
"""
import json
import re
import subprocess


GATES = {
    'ci_review': 'CI',
    'migration_boot_recovery': 'ISOLATED_OPENWRT',
    'vtest_ownership_limits': 'ISOLATED_OPENWRT',
    'main_transactions_rollback': 'ISOLATED_OPENWRT',
    'backup_snapshot_restore': 'ISOLATED_OPENWRT',
    'asata_writer_coordination': 'ISOLATED_OPENWRT',
    'installed_runtime_smoke': 'LIVE',
    'telegram_delivery': 'LIVE',
    'safe_actions': 'LIVE',
    'sysupgrade_persistence': 'LIVE',
    'lan_recovery': 'LIVE',
    'reboot_restore': 'LIVE',
    'soak': 'LIVE',
    'owner_release_approval': 'OWNER',
}
REFERENCE = re.compile(r'https://github\.com/bsekinaev/cudy-home-gateway/(?:'
                       r'actions/runs/[1-9][0-9]*|issues/7#issuecomment-[1-9][0-9]*|'
                       r'pull/[1-9][0-9]*#pullrequestreview-[1-9][0-9]*)')


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE)


def validate(record, version, runtime_tree):
    def require(condition, reason):
        if not condition:
            raise ValueError('STABLE_ACCEPTANCE_' + reason)
    require(isinstance(record, dict) and set(record) == {'schema_version', 'version', 'runtime_tree', 'gates'}, 'SCHEMA')
    require(type(record['schema_version']) is int and record['schema_version'] == 1, 'SCHEMA')
    require(record['version'] == version and record['runtime_tree'] == runtime_tree, 'RUNTIME_IDENTITY')
    rows = record['gates']
    require(isinstance(rows, dict) and set(rows) == set(GATES), 'INCOMPLETE')
    for gate, scope in GATES.items():
        row = rows[gate]
        require(isinstance(row, dict) and set(row) == {'status', 'scope', 'reference'}, 'SCHEMA')
        require(row['status'] == 'PASS' and row['scope'] == scope, 'BLOCKED')
        require(isinstance(row['reference'], str) and REFERENCE.fullmatch(row['reference']), 'REFERENCE')
    return True


def check(repo, commit, version):
    tree = git(repo, 'rev-parse', commit + ':src').decode().strip()
    try:
        entry = git(repo, 'ls-tree', commit, '--', 'docs/release-acceptance.json').decode().strip()
        if not entry.startswith('100644 blob '):
            raise ValueError('STABLE_ACCEPTANCE_MISSING')
        raw = git(repo, 'show', commit + ':docs/release-acceptance.json')
        if len(raw) > 16384:
            raise ValueError('STABLE_ACCEPTANCE_SCHEMA')
        # Duplicate keys must not silently replace a BLOCKED evidence row.
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError('STABLE_ACCEPTANCE_SCHEMA')
                result[key] = value
            return result
        record = json.loads(raw, object_pairs_hook=unique)
    except (subprocess.CalledProcessError, UnicodeError, json.JSONDecodeError, RecursionError):
        raise ValueError('STABLE_ACCEPTANCE_MISSING_OR_INVALID') from None
    return validate(record, version, tree)
