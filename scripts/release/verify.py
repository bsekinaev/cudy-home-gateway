"""Validate a release without extracting or executing it (Python 3.10+)."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

from build import allowed

MAX_ARCHIVE = 8 * 1024 * 1024
MAX_TOTAL = 16 * 1024 * 1024
MAX_FILE = 2 * 1024 * 1024
REQUIRED = {"usr/bin/gateway", "usr/bin/home-gateway-ci-smoke",
            "etc/init.d/home-gateway-telegram", "usr/lib/home-gateway/common.sh"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def verify(path, commit, expected_hash):
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Expected full commit SHA")
    require(re.fullmatch(r"[0-9a-fA-F]{64}", expected_hash), "Invalid archive SHA256")
    with Path(path).open("rb") as source:
        raw = source.read(MAX_ARCHIVE + 1)
    require(len(raw) <= MAX_ARCHIVE, "Archive exceeds size limit")
    require(hashlib.sha256(raw).hexdigest() == expected_hash.lower(), "Archive SHA256 mismatch")
    contents = {}
    total = 0
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
        for member in archive:
            require(len(contents) < 256, "Too many archive entries")
            require(member.name not in contents, f"Duplicate archive entry: {member.name}")
            require(member.type == tarfile.REGTYPE and not member.pax_headers,
                    f"Only plain regular files are allowed: {member.name}")
            require(member.name == "manifest.json" or
                    (member.name.startswith("payload/") and allowed(member.name[8:])),
                    f"Forbidden archive path: {member.name}")
            require(member.mode in (0o644, 0o755) and member.uid == member.gid == 0,
                    f"Invalid mode or owner: {member.name}")
            require(0 <= member.size <= MAX_FILE, "File exceeds size limit")
            total += member.size
            require(total <= MAX_TOTAL, "Payload exceeds size limit")
            data = archive.extractfile(member).read()
            require(len(data) == member.size, "Truncated member")
            contents[member.name] = (member.mode, data)
    require("manifest.json" in contents, "Missing manifest")
    require(contents["manifest.json"][0] == 0o644, "Invalid manifest mode")
    manifest = json.loads(contents["manifest.json"][1], object_pairs_hook=unique_object)
    require(isinstance(manifest, dict), "Manifest must be an object")
    require(type(manifest.get("schema_version")) is int and manifest["schema_version"] == 1,
            "Unsupported schema")
    require(manifest.get("project") == "cudy-home-gateway", "Wrong project")
    require(manifest.get("commit") == commit, "Commit mismatch")
    require(type(manifest.get("commit_timestamp")) is int and manifest["commit_timestamp"] >= 0,
            "Invalid commit timestamp")
    version = manifest.get("version")
    require(isinstance(version, str) and re.fullmatch(r"[0-9][A-Za-z0-9.+-]*", version),
            "Invalid version")
    records = manifest.get("files")
    require(isinstance(records, list) and 0 < len(records) < 256, "Invalid file list")
    paths = set()
    checksums = []
    for record in records:
        require(isinstance(record, dict), "Invalid file record")
        name = record.get("path")
        require(isinstance(name, str) and allowed(name), "Forbidden manifest path")
        require(name not in paths, f"Duplicate manifest path: {name}")
        paths.add(name)
        key = "payload/" + name
        require(key in contents, f"Missing payload: {name}")
        mode, data = contents[key]
        require(record.get("mode") == f"{mode:04o}", f"Mode mismatch: {name}")
        if name.startswith(("usr/bin/", "etc/init.d/")):
            require(mode == 0o755, f"Entrypoint not executable: {name}")
        require(type(record.get("size")) is int and record["size"] == len(data),
                f"Size mismatch: {name}")
        digest = hashlib.sha256(data).hexdigest()
        require(record.get("sha256") == digest, f"File SHA256 mismatch: {name}")
        require(b"\r" not in data and b"\0" not in data, f"Runtime is not LF text: {name}")
        checksums.append(f"{digest}  {key}\n")
    require(REQUIRED <= paths, "Required runtime files missing")
    require(set(contents) == {"manifest.json"} | {"payload/" + p for p in paths},
            "Unlisted payload files")
    common = contents["payload/usr/lib/home-gateway/common.sh"][1]
    versions = re.findall(rb"^HG_VERSION='([0-9][A-Za-z0-9.+-]*)'$", common, re.M)
    require(versions == [version.encode()], "Runtime version mismatch")
    return manifest, "".join(sorted(checksums))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--sha256", required=True, help="Expected SHA256 from the trusted CI artifact")
    parser.add_argument("--checksums", type=Path, help="Create a NEW file of validated payload hashes")
    args = parser.parse_args()
    try:
        manifest, checksums = verify(args.archive, args.commit, args.sha256)
        if args.checksums:
            with args.checksums.open("x", encoding="ascii", newline="\n") as output:
                output.write(checksums)
        print(f"BUNDLE_VERIFIED commit={manifest['commit']} files={len(manifest['files'])}")
    except (ValueError, OSError, tarfile.TarError, EOFError) as error:
        parser.exit(1, f"Verification failed: {error}\n")
