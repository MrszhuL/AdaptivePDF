#!/usr/bin/env python3
"""Offline provenance checks for the committed qpdf distribution dependency."""
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
vendor = root / "Vendor/qpdf"
manifest = json.loads((vendor / "manifest.json").read_text())
for name, expected in manifest["headers_git_blobs"].items():
    data = (vendor / "include/qpdf" / name).read_bytes()
    actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    assert actual == expected, f"qpdf header differs from pinned upstream: {name}"
library = vendor / "lib/libqpdf.30.dylib"
assert hashlib.sha256(library.read_bytes()).hexdigest() == manifest["universal_library_sha256"]
archs = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
assert {"x86_64", "arm64"}.issubset(set(archs))
for name in ["LICENSE.txt", "NOTICE.md", "LIBJPEG-TURBO-LICENSE.md", "LIBJPEG-IJG-README.txt"]:
    assert (vendor / name).stat().st_size > 100
print(f"PASS: qpdf {manifest['version']}, {len(manifest['headers_git_blobs'])} pinned upstream headers, Universal dylib and license notices")
