"""V1 regression keeps its Telegram-only contract while V2 tests new observers."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import run_vm


class OwnerUpdateFixtureTests(unittest.TestCase):
    def test_freezes_only_four_backend_observers_and_keeps_current_helpers(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            head = run_vm.git('rev-parse', 'HEAD').decode().strip()
            repo, source = run_vm.owner_update_fixture(head, workspace)
            for name in ('dns.sh', 'redmi.sh', 'health.sh', 'status.sh'):
                path = 'src/usr/lib/home-gateway/' + name
                self.assertEqual(subprocess.check_output(['git', '-C', str(repo), 'show', source+':'+path]),
                                 run_vm.git('show', '62592457237e7f026786c086d1ca6fdd4b6c095d:'+path))
            for path in ('src/usr/lib/home-gateway/telegram-poller.uc',
                         'src/usr/lib/home-gateway/common.sh', 'scripts/owner_update/update.sh'):
                self.assertEqual(subprocess.check_output(['git', '-C', str(repo), 'show', source+':'+path]),
                                 run_vm.git('show', head+':'+path))
            result = subprocess.run([sys.executable, str(repo/'scripts/owner_update/build_kit.py'),
                                     '--ref', source, '--output', str(workspace/'kit')],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            metadata = json.loads((workspace/'owner-update-fixture.json').read_text())
            self.assertEqual(metadata['real_candidate_commit'], head)
            self.assertEqual(metadata['fixture_commit'], source)
            self.assertEqual(metadata['fixture_scope'], 'VM_ONLY_V1_TELEGRAM_REGRESSION')


if __name__ == '__main__':
    unittest.main()
