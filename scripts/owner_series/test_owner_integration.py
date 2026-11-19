"""Full Windows runner with local transport functions, never router access.

Only a temporary runner copy has its two historical bootstrap pins replaced
with synthetic fixture pins. No test switch is added to the shipped runner.
"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from parent import PATHS, CONTROLS, ACCEPTED, OWNER_ARCHIVE, OWNER_MANIFEST
from test_owner_runner import bundle

HERE = Path(__file__).parent
SOURCE = 'a' * 40


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


@unittest.skipUnless(shutil.which('powershell.exe'), 'Windows PowerShell 5.1 required')
class FullRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.session = self.root / 'session.json'
        controls = {p: 'c' * 64 for _, p in CONTROLS}
        runtime = {p: b'HOST TRANSPORT FIXTURE\n' for p in PATHS}
        inventories = {s: {p: digest(v) for p, v in runtime.items()} for s in ('baseline', 'candidate')}
        changed = 'usr/lib/home-gateway/status.sh'
        inventories['candidate'][changed] = digest(b'CHANGED HOST FIXTURE\n')
        parent = dict(format='HG_OWNER_UPDATE_V1', source_commit=ACCEPTED,
                      inventories={'candidate': inventories['baseline']}, controls=controls)
        parent_raw = json.dumps(parent).encode()
        bootstrap = b'NONEXECUTABLE HOST TRANSPORT FIXTURE'
        self.runner = self.root / 'owner.ps1'
        text = (HERE / 'owner.ps1').read_text(encoding='utf-8')
        self.runner.write_text(text.replace(OWNER_ARCHIVE, digest(bootstrap)).replace(
            OWNER_MANIFEST, digest(parent_raw)), encoding='utf-8')
        files = {name: (0o600, b'HOST FIXTURE\n') for name in
                 ('protocol.uc', 'state.uc', 'engine.uc', 'watch.uc', 'owner.ps1')}
        files['boot.init'] = (0o755, b'HOST FIXTURE\n')
        files['bootstrap.tar.gz'] = (0o600, bootstrap)
        files['parent.json'] = (0o600, parent_raw)
        approval = dict(format='HG_OWNER_SERIES_ACCEPTANCE_V1', commit=SOURCE,
                        ci_head=SOURCE, ci_conclusion='success', review_head=SOURCE,
                        review_blockers=0, ci_url='https://github.com/bsekinaev/cudy-home-gateway/actions/runs/1',
                        report=dict(commit=SOURCE, scenario='owner-series', status='PASS', failed=0))
        files['acceptance.json'] = (0o600, json.dumps(approval).encode())
        for side in ('baseline', 'candidate'):
            for p, body in runtime.items():
                if side == 'candidate' and p == changed:
                    body = b'CHANGED HOST FIXTURE\n'
                files[side + '/' + p] = (0o755 if p in PATHS[:3] else 0o644, body)
            files[side + '.sha256'] = (0o600, ''.join(
                inventories[side][p] + '  ' + p + '\n' for p in PATHS).encode())
        manifest = dict(format='HG_OWNER_UPDATE_V2', profile='OWNER_MANUAL', production_apply=True,
                        source_fixture=False, source_commit=SOURCE, baseline_commit=ACCEPTED,
                        parent=dict(format='HG_OWNER_UPDATE_V1', source_commit=ACCEPTED,
                                    manifest_sha256=digest(parent_raw), archive_sha256=digest(bootstrap)),
                        bootstrap=dict(archive_sha256=digest(bootstrap), manifest_sha256=digest(parent_raw)),
                        controls=controls, inventories=inventories, changed=[changed],
                        files=[dict(path=p, mode=m, size=len(b), sha256=digest(b)) for p, (m, b) in sorted(files.items())])
        files['manifest.json'] = (0o600, json.dumps(manifest).encode())
        dirs = {str(d) for p in files for d in PurePosixPath(p).parents if str(d) != '.'}
        entries = [(p + '/', b'', tarfile.DIRTYPE, 0o700) for p in sorted(dirs)]
        entries += [(p, b, tarfile.REGTYPE, m) for p, (m, b) in sorted(files.items())]
        self.archive = self.root / 'fixture.tar.gz'
        self.archive.write_bytes(bundle(entries))
        self.pin = digest(self.archive.read_bytes())

    def run_stage(self, stage, fail=False, pin=None):
        def q(value):
            return "'" + str(value).replace("'", "''") + "'"
        # Functions win PowerShell command resolution. Neither ssh nor scp starts.
        code = r'''
$ErrorActionPreference='Stop'
function global:scp { $global:LASTEXITCODE=0 }
function global:ssh {
 $command=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$args[-1]).Split(' ')[2]))
 [IO.File]::AppendAllText($env:HG_TEST_CALLS,$command+"`n")
 $global:LASTEXITCODE=0
 if($command -like '*mktemp -d*') { Write-Output '/tmp/hg-owner-series-kit.abcdef' }
 elseif($command -like '/usr/bin/ucode *') {
  $parts=$command.Split(' ')
  $s=Get-Content -Raw -LiteralPath $env:HG_TEST_SESSION | ConvertFrom-Json
  if($parts[2] -eq 'apply' -and (!$s.apply_attempted -or $s.last_operation_id -ne $parts[5])) { throw 'Attempt not saved before transport' }
  Write-Output ('OWNER_SERIES_STAGE='+$parts[2]+' RESULT=PASS SOURCE='+'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'+' OPERATION='+$parts[5])
  if($env:HG_TEST_FAIL -eq '1') { $global:LASTEXITCODE=7 }
 }
}
'''
        code += '\n& ' + q(self.runner) + ' -Bundle ' + q(self.archive) + ' -BundleSha256 ' + q(pin or self.pin)
        code += ' -Target root@fixture.invalid -SessionFile ' + q(self.session) + ' -Stage ' + stage
        import os
        env = dict(os.environ, HG_TEST_SESSION=str(self.session), HG_TEST_CALLS=str(self.root / 'calls'),
                   HG_TEST_FAIL='1' if fail else '0')
        return subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', code],
                              capture_output=True, text=True, env=env, timeout=60)

    def test_preflight_apply_verify_rollback_and_replay_refusal(self):
        for stage in ('Preflight', 'Apply', 'Verify', 'Rollback', 'Verify'):
            result = self.run_stage(stage)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        session = json.loads(self.session.read_text(encoding='utf-8-sig'))
        self.assertNotEqual(session['apply_id'], session['rollback_id'])
        before = (self.root / 'calls').read_bytes()
        self.assertNotEqual(self.run_stage('Apply').returncode, 0)
        self.assertEqual((self.root / 'calls').read_bytes(), before)

    def test_failed_transport_with_success_text_keeps_attempt_and_requires_recovery(self):
        self.assertEqual(self.run_stage('Preflight').returncode, 0)
        result = self.run_stage('Apply', fail=True)
        self.assertNotEqual(result.returncode, 0)
        session = json.loads(self.session.read_text(encoding='utf-8-sig'))
        self.assertTrue(session['apply_attempted'])
        self.assertNotEqual(self.run_stage('Apply').returncode, 0)
        self.assertEqual(self.run_stage('Recover').returncode, 0)

    def test_local_authentication_failure_never_calls_transport(self):
        self.assertNotEqual(self.run_stage('Preflight', pin='0' * 64).returncode, 0)
        self.assertFalse((self.root / 'calls').exists())
        self.assertFalse(self.session.exists())
