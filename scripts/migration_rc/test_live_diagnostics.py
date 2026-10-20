"""Native read-only owner evidence collection; never run service/admission start."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).with_name('diagnose-rolled-back.uc')
NONCE = '38bd5771-7472-45e7-8e2f-e4a37f7948ab'

class LiveDiagnostics(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / 'etc/home-gateway-migration'
        self.base.mkdir(parents=True, mode=0o700)
        self.lock = self.root / 'etc/home-gateway-migration.lock'
        self.lock.touch(mode=0o600)
        self.put('phase', 'ROLLED_BACK\n')
        self.put('marker', f'HG_MIGRATION_STATE_V1 {NONCE}\n')
        self.put('admission', f'HG_MIGRATION_ADMITTED_V2 ROLLED_BACK {NONCE} {self.lock.stat().st_ino}\n')
        self.put('service-check', f'HG_MIGRATION_SERVICE_CHECK_V1 {NONCE} {self.lock.stat().st_ino}\n')
        # The diagnostic has no production input/root override. Adapt constants
        # and fixture UID/GID in a disposable source copy solely for the native
        # test. GitHub hosted runners are not root; production still requires 0:0.
        self.script = self.root / 'probe.uc'
        self.script.write_text(SOURCE.read_text().replace("const BASE='/etc/home-gateway-migration', LOCK='/etc/home-gateway-migration.lock';", f"const BASE='{self.base}', LOCK='{self.lock}';").replace("st.uid!=0 || st.gid!=0", f"st.uid!={os.getuid()} || st.gid!={os.getgid()}"))

    def put(self, name, raw):
        path = self.base / name
        path.write_text(raw)
        path.chmod(0o600)

    def run_probe(self, held=False):
        args = ['ucode', str(self.script)]
        if held:
            import shlex
            args = [shutil.which('busybox'), 'ash', '-c', f'exec 8< {shlex.quote(str(self.lock))}; exec '+shlex.join(args)]
        return subprocess.run(args, capture_output=True, text=True, timeout=10)

    def test_probe_is_read_only_and_inherited_fd_identity_is_measured(self):
        before = {str(p): (p.read_bytes(), p.stat().st_mode, p.stat().st_ino, p.stat().st_mtime_ns)
                  for p in self.root.rglob('*') if p.is_file()}
        for held in (False, True):
            r = self.run_probe(held)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('FD8_IDENTITY='+str(held).lower(), r.stdout)
            self.assertIn('ROLLED_BACK_ADMISSION_MATCH=true', r.stdout)
            self.assertIn('RETAINED_SERVICE_TICKET_MATCH=true', r.stdout)
            self.assertIn('HISTORICAL_REJECTING_ASSERTION="UNKNOWN_REQUIRES_ADDITIONAL_EVIDENCE"', r.stdout)
        after = {str(p): (p.read_bytes(), p.stat().st_mode, p.stat().st_ino, p.stat().st_mtime_ns)
                 for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_nonterminal_state_refuses_without_service_or_state_changes(self):
        for phase in ('APPLYING\n', 'RESTORING\n', 'COMMITTED\n', 'CORRUPT\n'):
            self.put('phase', phase)
            r = self.run_probe()
            self.assertEqual(r.returncode, 73, r.stderr)
            self.assertEqual(r.stdout, 'PROBE_REFUSED=EXPECTED_ROLLED_BACK\n')
            self.assertEqual((self.base / 'phase').read_text(), phase)

    def test_unknown_record_contents_are_never_printed(self):
        secret = 'DO_NOT_PRINT_PRIVATE_INPUT_12345'
        for name in ('marker', 'admission', 'service-check', 'coordinator.json', 'handoff.json'):
            self.put(name, secret)
        r = self.run_probe(True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(secret, r.stdout + r.stderr)
        self.assertIn('OWNER_TRANSACTION_MATCH=false', r.stdout)
        self.assertIn('RETAINED_SERVICE_TICKET_MATCH=false', r.stdout)

if __name__ == '__main__':
    unittest.main()
