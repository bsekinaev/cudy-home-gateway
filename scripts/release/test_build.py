"""Release format and source-isolation tests using a disposable Git repository."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

from build import build


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Bundle Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "core.autocrlf", "false")
        self.runtime = ["usr/bin/gateway", "usr/bin/home-gateway-ci-smoke",
                        "etc/init.d/home-gateway-telegram", "usr/lib/home-gateway/common.sh"]
        for name in self.runtime:
            path = self.repo / "src" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"HG_VERSION='0.5.0-dev'\n" if name.endswith("common.sh") else b"#!/bin/sh\nexit 0\n")
        self.git("add", "src")
        for name in self.runtime[:3]:
            self.git("update-index", "--chmod=+x", "src/" + name)
        self.git("commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.STDOUT)

    def test_reproducibility_manifest_and_dirty_worktree_isolation(self):
        first = build(self.repo, "HEAD", self.root / "first")
        (self.repo / "src/usr/bin/gateway").write_bytes(b"uncommitted\r\n")
        (self.repo / "src/private.key").write_bytes(b"untracked secret")
        second = build(self.repo, "HEAD", self.root / "second")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        expected_hash = Path(str(first) + ".sha256").read_text().split()[0]
        self.assertEqual(hashlib.sha256(first.read_bytes()).hexdigest(), expected_hash)
        with tarfile.open(first) as archive:
            manifest = json.load(archive.extractfile("manifest.json"))
            self.assertEqual(manifest["commit"], self.git("rev-parse", "HEAD").decode().strip())
            self.assertEqual(set(archive.getnames()), {"manifest.json"} | {"payload/" + p for p in self.runtime})
            for record in manifest["files"]:
                member = archive.getmember("payload/" + record["path"])
                data = archive.extractfile(member).read()
                self.assertEqual(len(data), record["size"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), record["sha256"])
                self.assertEqual(member.mode, int(record["mode"], 8))
                self.assertTrue(member.isfile())
        self.assertEqual(Path(str(first) + ".manifest.json").read_bytes(),
                         (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode())

    def test_rejects_tracked_unexpected_file(self):
        (self.repo / "src/private.key").write_bytes(b"secret")
        self.git("add", "src/private.key")
        self.git("commit", "-qm", "bad path")
        with self.assertRaisesRegex(ValueError, "Unsupported runtime"):
            build(self.repo, "HEAD", self.root / "out")

    def test_rejects_symlink_without_following_it(self):
        oid = self.git("hash-object", "-w", "src/usr/bin/gateway").decode().strip()
        self.git("update-index", "--cacheinfo", "120000", oid, "src/usr/bin/gateway")
        self.git("commit", "-qm", "symlink")
        with self.assertRaisesRegex(ValueError, "Unsupported runtime"):
            build(self.repo, "HEAD", self.root / "out")

    def test_rejects_non_executable_entrypoint(self):
        self.git("update-index", "--chmod=-x", "src/usr/bin/gateway")
        self.git("commit", "-qm", "bad mode")
        with self.assertRaisesRegex(ValueError, "executable"):
            build(self.repo, "HEAD", self.root / "out")

    def test_ref_and_existing_output(self):
        with self.assertRaises(subprocess.CalledProcessError):
            build(self.repo, "missing-ref", self.root / "out")
        build(self.repo, "HEAD", self.root / "out")
        with self.assertRaisesRegex(ValueError, "already exists"):
            build(self.repo, "HEAD", self.root / "out")


if __name__ == "__main__":
    unittest.main()
