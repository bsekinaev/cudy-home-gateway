"""CI provenance checks and fixed inventory contract."""
from copy import deepcopy
import os
from pathlib import Path
import re
import unittest

from fetch_release import validate_run
from transport import PATHS


class ProvenanceTests(unittest.TestCase):
    def test_valid_ci(self):
        self.run_data = {'conclusion': 'success', 'status': 'completed', 'head_sha': 'a' * 40,
                         'head_branch': 'main', 'event': 'push', 'path': '.github/workflows/ci.yml',
                         'head_repository': {'full_name': 'owner/repo'}}
        validate_run(self.run_data, 'owner/repo', 'a' * 40, 'main')

    def test_wrong_run_rejected(self):
        self.test_valid_ci()
        for key, value in [('conclusion', 'failure'), ('status', 'in_progress'),
                           ('head_sha', 'b' * 40), ('head_branch', 'untrusted'),
                           ('event', 'pull_request'), ('path', '.github/workflows/other.yml'),
                           ('head_repository', {'full_name': 'fork/repo'})]:
            item = deepcopy(self.run_data)
            item[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_run(item, 'owner/repo', 'a' * 40, 'main')

    def test_receiver_inventory_matches_client(self):
        source = Path(__file__).with_name('engine.sh').read_text()
        block = source.split("cat <<'EOF'\n", 1)[1].split('\nEOF', 1)[0]
        self.assertEqual(block.splitlines(), PATHS)

    def test_forced_wrapper_rejects_shell_commands(self):
        if os.name != 'posix':
            self.skipTest('Shell integration runs on Linux CI')
        import subprocess
        wrapper = Path(__file__).with_name('wrapper.sh')
        for command in ('', 'sh', 'apply a b; id', 'plan $(id)', 'status extra', 'scp -t /tmp', 'sftp'):
            result = subprocess.run(['sh', str(wrapper)], env=dict(os.environ, SSH_ORIGINAL_COMMAND=command),
                                    capture_output=True)
            self.assertEqual(result.returncode, 64, (command, result.stderr))
