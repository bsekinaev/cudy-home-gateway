"""V1 regression keeps its Telegram-only contract while V2 tests new observers."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import run_vm


class OwnerUpdateFixtureTests(unittest.TestCase):
    def test_freezes_nineteen_runtime_files_and_keeps_current_controller_helpers(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            head = run_vm.git('rev-parse', 'HEAD').decode().strip()
            repo, source = run_vm.owner_update_fixture(head, workspace)
            baseline='62592457237e7f026786c086d1ca6fdd4b6c095d'
            paths=run_vm.git('ls-tree','-r','--name-only',baseline,'src').decode().splitlines()
            paths=[p for p in paths if p!='src/usr/lib/home-gateway/telegram-poller.uc']
            self.assertEqual(len(paths),19)
            for path in paths:
                self.assertEqual(subprocess.check_output(['git','-C',str(repo),'show',source+':'+path]),
                                 run_vm.git('show',baseline+':'+path),path)
            for path in ('src/usr/lib/home-gateway/telegram-poller.uc',
                         'scripts/owner_update/update.sh'):
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
