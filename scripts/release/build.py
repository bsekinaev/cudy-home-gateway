"""Build a non-installing release bundle from immutable Git blobs (Python 3.10+)."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE)


def allowed(path):
    return path in {
        "etc/init.d/home-gateway-telegram", "usr/bin/gateway",
        "usr/bin/home-gateway-ci-smoke",
    } or re.fullmatch(r"usr/lib/home-gateway/[a-z][a-z0-9-]*\.(sh|uc)", path)


def build(repo, ref, output):
    commit = git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()
    timestamp = int(git(repo, "show", "-s", "--format=%ct", commit))
    files = []
    entries = git(repo, "ls-tree", "-rz", "--full-tree", commit, "--", "src/")
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        header, raw_path = entry.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        path = raw_path.decode("utf-8").removeprefix("src/")
        if not allowed(path) or kind != "blob" or mode not in ("100644", "100755"):
            raise ValueError(f"Unsupported runtime entry: {path} ({mode}, {kind})")
        if path.startswith(("usr/bin/", "etc/init.d/")) and mode != "100755":
            raise ValueError(f"Entrypoint must be executable in Git: {path}")
        data = git(repo, "cat-file", "blob", oid)
        if b"\r" in data or b"\0" in data:
            raise ValueError(f"Runtime must be LF-only text: {path}")
        files.append((path, int(mode[-3:], 8), data))
    files.sort()
    required = {"usr/bin/gateway", "usr/bin/home-gateway-ci-smoke",
                "etc/init.d/home-gateway-telegram", "usr/lib/home-gateway/common.sh"}
    if not required.issubset({p for p, _, _ in files}):
        raise ValueError("Required runtime files are missing")
    common = next(data for p, _, data in files if p.endswith("/common.sh"))
    versions = re.findall(rb"^HG_VERSION='([0-9][A-Za-z0-9.+-]*)'$", common, re.M)
    if len(versions) != 1:
        raise ValueError("Expected one literal HG_VERSION in common.sh")
    version = versions[0].decode()
    manifest = {
        "schema_version": 1, "project": "cudy-home-gateway",
        "version": version, "commit": commit, "commit_timestamp": timestamp,
        "files": [{"path": p, "mode": f"{mode:04o}", "size": len(data),
                   "sha256": hashlib.sha256(data).hexdigest()} for p, mode, data in files],
    }
    manifest_data = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", filename="", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for path, mode, data in [("manifest.json", 0o644, manifest_data)] + [
                ("payload/" + p, mode, data) for p, mode, data in files
            ]:
                info = tarfile.TarInfo(path)
                info.size, info.mode, info.mtime = len(data), mode, timestamp
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                archive.addfile(info, io.BytesIO(data))
    bundle = buffer.getvalue()
    name = f"cudy-home-gateway-{version}-{commit}.tar.gz"
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    paths = [output / name, output / (name + ".sha256"), output / (name + ".manifest.json")]
    if any(p.exists() for p in paths):
        raise ValueError("Output already exists; select a fresh output directory")
    paths[0].write_bytes(bundle)
    paths[1].write_text(hashlib.sha256(bundle).hexdigest() + "  " + name + "\n", encoding="ascii")
    paths[2].write_bytes(manifest_data)
    return paths[0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--output", type=Path, default=Path("dist"))
    args = parser.parse_args()
    try:
        print(build(Path(__file__).resolve().parents[2], args.ref, args.output))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Build failed: {error}\n")
