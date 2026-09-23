"""Reject malformed releases before extraction or execution."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from verify import verify


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "bundle.tar.gz"
        self.commit = "a" * 40
        names = ["etc/init.d/home-gateway-telegram", "usr/bin/gateway",
                 "usr/bin/home-gateway-ci-smoke", "usr/lib/home-gateway/common.sh"]
        self.entries = [("payload/" + n, 0o644 if n.endswith(".sh") else 0o755,
                         b"HG_VERSION='0.5.0-dev'\n" if n.endswith(".sh") else b"#!/bin/sh\n") for n in names]
        self.manifest = {"schema_version": 1, "project": "cudy-home-gateway",
                         "commit": self.commit, "commit_timestamp": 0, "version": "0.5.0-dev",
                         "files": [{"path": n[8:], "mode": f"{m:04o}", "size": len(d),
                                    "sha256": hashlib.sha256(d).hexdigest()} for n, m, d in self.entries]}

    def write(self, extra=None):
        with tarfile.open(self.path, "w:gz", format=tarfile.USTAR_FORMAT) as archive:
            for name, mode, data in [("manifest.json", 0o644, json.dumps(self.manifest).encode())] + self.entries:
                info = tarfile.TarInfo(name)
                info.mode, info.size = mode, len(data)
                archive.addfile(info, io.BytesIO(data))
            if extra:
                archive.addfile(extra)
        return hashlib.sha256(self.path.read_bytes()).hexdigest()

    def test_valid_and_checksums(self):
        manifest, checksums = verify(self.path, self.commit, self.write())
        self.assertEqual(len(manifest["files"]), 4)
        self.assertEqual(len(checksums.splitlines()), 4)
        self.assertTrue(all("  payload/" in line for line in checksums.splitlines()))
        self.assertEqual(list(Path(self.temp.name).iterdir()), [self.path])

    def test_wrong_archive_hash_and_commit(self):
        digest = self.write()
        with self.assertRaisesRegex(ValueError, "Archive SHA256"):
            verify(self.path, self.commit, "0" * 64)
        with self.assertRaisesRegex(ValueError, "Commit mismatch"):
            verify(self.path, "b" * 40, digest)

    def test_forbidden_paths(self):
        for name in ("../outside", "/etc/passwd", "payload/usr/bin/../../etc/passwd"):
            with self.subTest(name=name):
                digest = self.write(tarfile.TarInfo(name))
                with self.assertRaisesRegex(ValueError, "Forbidden archive path"):
                    verify(self.path, self.commit, digest)

    def test_links_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            info = tarfile.TarInfo("payload/usr/lib/home-gateway/link.sh")
            info.type, info.linkname = kind, "/etc/passwd"
            with self.assertRaisesRegex(ValueError, "plain regular"):
                verify(self.path, self.commit, self.write(info))

    def test_duplicate_member(self):
        with self.assertRaisesRegex(ValueError, "Duplicate archive"):
            verify(self.path, self.commit, self.write(tarfile.TarInfo(self.entries[0][0])))

    def test_content_tamper(self):
        name, mode, data = self.entries[0]
        self.entries[0] = (name, mode, data.replace(b"sh", b"xx"))
        with self.assertRaisesRegex(ValueError, "File SHA256"):
            verify(self.path, self.commit, self.write())

    def test_mode_tamper(self):
        name, _, data = self.entries[0]
        self.entries[0] = (name, 0o644, data)
        with self.assertRaisesRegex(ValueError, "Mode mismatch"):
            verify(self.path, self.commit, self.write())

    def test_unlisted_and_duplicate_manifest_files(self):
        self.manifest["files"].pop()
        with self.assertRaises(ValueError):
            verify(self.path, self.commit, self.write())
        self.manifest["files"].append(self.manifest["files"][0])
        with self.assertRaisesRegex(ValueError, "Duplicate manifest"):
            verify(self.path, self.commit, self.write())


if __name__ == "__main__":
    unittest.main()
