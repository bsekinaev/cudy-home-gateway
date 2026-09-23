"""Build/verify/encode integration and transport boundary failures."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

from transport import encode, PATHS
from build import build


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'core.autocrlf', 'false')
        for path in PATHS:
            file = self.repo / 'src' / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"HG_VERSION='0.5.0-dev'\n" if path.endswith('/common.sh') else b'#!/bin/sh\nexit 0\n')
        self.git('add', 'src')
        for path in PATHS[:3]:
            self.git('update-index', '--chmod=+x', 'src/' + path)
        self.git('commit', '-qm', 'fixture')
        self.commit = self.git('rev-parse', 'HEAD').decode().strip()
        self.archive = build(self.repo, 'HEAD', self.root / 'dist')
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.STDOUT)

    def test_built_bundle_wire_contents(self):
        wire = encode(self.archive, self.commit, self.digest)
        lines = wire.splitlines()
        self.assertEqual(lines[0], ('HGDEPLOY1 ' + self.commit).encode())
        self.assertEqual(lines[-1], b'END')
        self.assertEqual(len(lines), 40)
        for index, path in enumerate(PATHS):
            data = base64.b64decode(lines[index * 2 + 2], validate=True)
            mode, size, digest = lines[index * 2 + 1].decode().split()
            self.assertEqual(data, (self.repo / 'src' / path).read_bytes())
            self.assertEqual(int(size), len(data))
            self.assertEqual(digest, hashlib.sha256(data).hexdigest())
            self.assertEqual(mode, '0755' if path in PATHS[:3] else '0644')

    def test_changed_inventory_fails_closed(self):
        file = self.repo / 'src/usr/lib/home-gateway/new.sh'
        file.write_bytes(b'#!/bin/sh\n')
        self.git('add', str(file))
        self.git('commit', '-qm', 'new runtime file')
        commit = self.git('rev-parse', 'HEAD').decode().strip()
        archive = build(self.repo, 'HEAD', self.root / 'new-dist')
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            encode(archive, commit, hashlib.sha256(archive.read_bytes()).hexdigest())

    def test_tampered_archive_not_sent(self):
        self.archive.write_bytes(self.archive.read_bytes() + b'tamper')
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
            encode(self.archive, self.commit, self.digest)

    @unittest.skipUnless(os.name == 'posix', 'Receiver runs on Linux')
    def test_build_to_receiver_plan(self):
        import shutil
        root = self.root / 'router'
        root.mkdir()
        (root / '.hg-deploy-test-root').touch()
        (root / 'etc/home-gateway-deploy').mkdir(parents=True)
        (root / 'tmp').mkdir()
        for path in PATHS:
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.repo / 'src' / path, target)
            target.chmod(0o755 if path in PATHS[:3] else 0o644)
        common = root / PATHS[4]
        previous = common.read_bytes() + b'# previous\n'
        common.write_bytes(previous)
        testbin = root / 'test-bin'
        testbin.mkdir()
        (testbin / 'ucode').write_text('#!/bin/sh\nexit 0\n')
        (testbin / 'ucode').chmod(0o755)
        wire = encode(self.archive, self.commit, self.digest)
        engine = Path(__file__).with_name('engine.sh').resolve()
        command = os.environ.get('HG_TEST_SHELL', '/bin/sh').split() + [
            str(engine), '--test-root', str(root), 'plan', self.commit, hashlib.sha256(wire).hexdigest()]
        result = subprocess.run(command, input=wire, capture_output=True,
                                env=dict(os.environ, HG_TEST_BIN=str(testbin)), timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(b'CHANGED=1', result.stdout)
        self.assertEqual(common.read_bytes(), previous)
