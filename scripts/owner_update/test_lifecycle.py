"""Execute admission revocation against real files, without a router."""
from pathlib import Path
import re
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHELL = ('C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' and
         Path('C:/Program Files/Git/bin/bash.exe').exists() else
         shutil.which('sh') if os.name != 'nt' else None)


@unittest.skipUnless(SHELL, 'POSIX shell required')
class AdmissionRevocationTests(unittest.TestCase):
    def exercise(self, drift=False):
        source = (ROOT / 'scripts/owner_update/update.sh').read_text(encoding='utf-8')
        match = re.search(r'^revoke_startup_admission\(\) \{\n.*?^\}', source, re.M | re.S)
        self.assertIsNotNone(match, 'startup failure must revoke legacy numeric-PID admission')
        with tempfile.TemporaryDirectory() as tmp:
            lease = Path(tmp) / 'lease'
            lease.mkdir()
            (lease / 'owner-update').write_text('foreign\n' if drift else 'pin\n')
            (lease / 'owner-process').write_text('owner-identity\n')
            script = '''
LOCK=lease; lease=identity; pin=pin; process_record_value=owner-identity
regular() { test -f "$1"; }
stat() { printf 'identity\\n'; }
sync() { :; }
printf '%s\\n' "$$" > "$LOCK/pid"
printf '%s\\n' "$$" > "$LOCK/owner-pid"
''' + match[0] + '\nrevoke_startup_admission\n'
            result = subprocess.run([SHELL, '-c', script], cwd=tmp, capture_output=True)
            self.assertEqual(result.returncode, 1 if drift else 0, result.stderr.decode())
            self.assertEqual((lease / 'pid').exists(), drift)
            self.assertTrue((lease / 'owner-pid').exists(), 'recovery identity must survive')
            self.assertTrue((lease / 'owner-process').exists())
            self.assertTrue((lease / 'owner-update').exists())

    def test_failure_revokes_numeric_pid_and_preserves_recovery_fence(self):
        self.exercise()

    def test_foreign_marker_is_not_modified(self):
        self.exercise(drift=True)


if __name__ == '__main__':
    unittest.main()
