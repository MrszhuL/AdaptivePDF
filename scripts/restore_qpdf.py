#!/usr/bin/env python3
"""Optional reproducible vendor restore. Normal Xcode builds are fully offline.

Restores only from pinned official upstream releases, verifies both release ZIPs
and source tarball, then combines the unchanged architecture dylibs with lipo.
The committed manifest is the trust input, not freshly downloaded hash metadata.
"""
import hashlib
import json
import shutil
import subprocess
import tarfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
vendor = root / "Vendor/qpdf"
manifest = json.loads((vendor / "manifest.json").read_text())
cache = root / "tmp/vendor-restore"
cache.mkdir(parents=True, exist_ok=True)
tag = manifest["source_tag"]
def fetch(name, expected):
    path = cache / name
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        subprocess.run(["curl", "-fL", "--retry", "2", "--connect-timeout", "15", "--max-time", "1200",
                        f"https://github.com/qpdf/qpdf/releases/download/{tag}/{name}", "-o", str(path)], check=True)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, f"Upstream checksum mismatch: {name}"
    return path

libraries = []
for architecture in ["x86_64", "arm64"]:
    archive = fetch(f"qpdf-{manifest['version']}-bin-macos-{architecture}.zip", manifest["upstream_archives"][f"macos-{architecture}"])
    target = cache / f"libqpdf-{architecture}.dylib"
    with zipfile.ZipFile(archive) as source:
        target.write_bytes(source.read("lib/libqpdf.30.4.2.dylib"))
    libraries.append(target)
source = fetch(f"qpdf-{manifest['version']}.tar.gz", "8a58af5b6141319287c1883bec8bd1bd545b7567b7fc5e6ce5d25a1c85f36397")
with tarfile.open(source) as archive:
    for name, expected in manifest["headers_git_blobs"].items():
        data = archive.extractfile(f"qpdf-{manifest['version']}/include/qpdf/{name}").read()
        assert hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() == expected
        (vendor / "include/qpdf" / name).write_bytes(data)
output = cache / "libqpdf.30.dylib"
subprocess.run(["lipo", "-create", *map(str, libraries), "-output", str(output)], check=True)
assert hashlib.sha256(output.read_bytes()).hexdigest() == manifest["universal_library_sha256"]
shutil.copyfile(output, vendor / "lib/libqpdf.30.dylib")
subprocess.run(["python3", str(root / "scripts/verify_vendor.py")], check=True)
