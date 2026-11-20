"""A recorded source commit must determine the emitted probe bytes."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import build_probe


class ProbeProvenanceTests(unittest.TestCase):
    def test_uncommitted_edits_cannot_change_recorded_source_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            repo = base / 'repo'
            repo.mkdir()
            subprocess.run(['git', '-c', 'core.autocrlf=false', 'init', '-q', str(repo)], check=True)
            subprocess.run(['git', '-C', str(repo), 'config', 'core.autocrlf', 'false'], check=True)
            contents = {
                'src/usr/lib/home-gateway/common.sh': b'# committed common\n',
                'src/usr/lib/home-gateway/dns.sh': b'# committed DNS\n',
                'src/usr/lib/home-gateway/redmi.sh': b'# committed REDMI\n',
                'scripts/observability/router-redmi-probe-footer.sh': b'echo committed-footer\n',
                'scripts/observability/check-redmi.ps1': b'# committed runner\n'}
            for name, raw in contents.items():
                path = repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(raw)
            subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture',
                            '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Fixture'], check=True)
            source = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'])
            for name in contents:
                (repo / name).write_bytes(b'PRIVATE_UNCOMMITTED\n')
            with patch.object(build_probe, 'ROOT', repo):
                build_probe.build(base/'out')
            self.assertEqual((base/'out/SOURCE.txt').read_bytes(), source)
            payload = (base/'out/router-redmi-probe.sh').read_bytes()
            self.assertNotIn(b'PRIVATE_UNCOMMITTED', payload)
            self.assertIn(b'echo committed-footer', payload)
            self.assertEqual((base/'out/check-redmi.ps1').read_bytes(), b'# committed runner\n')


if __name__ == '__main__':
    unittest.main()
