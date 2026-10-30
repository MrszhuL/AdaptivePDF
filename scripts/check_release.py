#!/usr/bin/env python3
"""Check the actual distributable, rather than inferring from a successful build."""
import argparse
import hashlib
import json
import plistlib
import subprocess
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--report", required=True, type=Path)
parser.add_argument("--require-developer-id", action="store_true")
args = parser.parse_args()
app = args.app.resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
icon = app / "Contents/Resources/AppIcon.icns"
assert icon.is_file() and icon.read_bytes()[:4] == b"icns", "Missing or invalid application icon"
assert info["LSMinimumSystemVersion"] == "15.0"
assert info["CFBundleVersion"].isdigit()
assert all(part.isdigit() for part in info["CFBundleShortVersionString"].split("."))
document_types = info["CFBundleDocumentTypes"]
assert any("com.adobe.pdf" in entry.get("LSItemContentTypes", []) for entry in document_types)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
archs = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True).split()
assert {"x86_64", "arm64"}.issubset(set(archs)), f"Unexpected architectures: {archs}"
for path in (app / "Contents/MacOS").iterdir():
    if path.is_file():
        data = path.read_bytes()
        assert b"ALL INTEGRATION CHECKS PASSED" not in data, "Test harness leaked into distribution"
        assert b"ADAPTIVEPDF_TEST_ROOT" not in data, "Test configuration leaked into distribution"
        assert b"ADAPTIVEPDF_CORPUS_MANIFEST" not in data, "Corpus harness leaked into distribution"
        assert b"ADAPTIVEPDF_CLOSE_SCENARIO" not in data, "Close/quit driver leaked into distribution"
        assert b"ADAPTIVEPDF_TEST_DEFAULTS_SUITE" not in data, "Preference probe override leaked into distribution"
        assert b"ADAPTIVEPDF_APPEARANCE_PHASE" not in data, "Appearance restart driver leaked into distribution"
entitlement_data = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", str(app)],
                                  capture_output=True, check=True).stdout
entitlements = plistlib.loads(entitlement_data) if entitlement_data.strip() else {}
assert not entitlements.get("com.apple.security.get-task-allow", False), "Debug entitlement in executable"
library = app / "Contents/Frameworks/libqpdf.30.dylib"
assert library.is_file(), "Missing bundled preserving-write engine"
library_archs = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
assert {"x86_64", "arm64"}.issubset(set(library_archs))
notices = app / "Contents/Resources/ThirdPartyNotices.txt"
assert notices.is_file() and "Independent JPEG Group" in notices.read_text(), "Missing third-party license notices"
signature = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
developer_id = "Authority=Developer ID Application:" in signature
flag_match = re.search(r"flags=0x([0-9a-fA-F]+)", signature)
runtime = flag_match is not None and bool(int(flag_match.group(1), 16) & 0x10000)
if args.require_developer_id:
    assert developer_id and runtime, "Public distribution requires Developer ID and hardened runtime"
    library_signature = subprocess.run(["codesign", "-d", "--verbose=4", str(library)], capture_output=True, text=True, check=True).stderr
    assert "Authority=Developer ID Application:" in library_signature
    team = re.search(r"^TeamIdentifier=(.+)$", signature, re.MULTILINE)
    library_team = re.search(r"^TeamIdentifier=(.+)$", library_signature, re.MULTILINE)
    assert team and library_team and team.group(1) == library_team.group(1), "Nested library signing team differs"
result = {
    "schema_version": 1, "status": "passed", "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"], "architectures": archs, "deployment_target": "15.0",
    "binary_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
    "developer_id_signed": developer_id, "hardened_runtime": runtime,
    "test_harness_absent": True, "icon_present": True, "pdf_document_type_registered": True,
    "preserving_engine": "qpdf-12.4.2", "preserving_engine_architectures": library_archs,
    "third_party_notices_present": True,
}
args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(f"PASS: production bundle {result['version']} ({result['build']}), architectures {', '.join(archs)}, no self-test code")
