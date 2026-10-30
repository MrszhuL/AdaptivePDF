#!/usr/bin/env python3
import argparse
import hashlib
import json
import plistlib
import zipfile
import subprocess
import os
import shutil
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--notarized", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = args.output.resolve()
reports = {name: json.loads((out / "verification" / f"{name}.json").read_text())
           for name in ["debug", "optimized", "production", "launch"]}
assert all(report["status"] == "passed" for report in reports.values())
assert reports["launch"]["binary_sha256"] == reports["production"]["binary_sha256"], "Installed binary differs from verified production binary"
assert reports["launch"]["readonly_volume"], "Install check was not run from the read-only disk image"
assert reports["launch"]["stable_reader_window"], "Install check did not observe the completed reader window"
assert reports["debug"]["assertions"] == reports["optimized"]["assertions"], "Debug / optimized coverage differs"
info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
close_flows = {}
appearance_restarts = {}
expected_close = {"window-save", "window-discard", "window-cancel", "window-save-failure",
                  "quit-save", "quit-discard", "quit-cancel", "multi-quit-review-save",
                  "multi-quit-discard", "multi-quit-cancel"}
for variant in ["debug", "optimized"]:
    close_report = json.loads((out / f"verification/{variant}-close.json").read_text())
    assert close_report["status"] == "passed" and close_report["app_build"] == info["CFBundleVersion"]
    assert {case["scenario"] for case in close_report["cases"]} == expected_close
    assert all(case["status"] == "passed" and case["independent_pdf_check"] == "passed" for case in close_report["cases"])
    assert all(case["assertion_count"] == len(case["assertions"]) for case in close_report["cases"])
    assert close_report["assertion_count"] == sum(case["assertion_count"] for case in close_report["cases"])
    close_flows[variant] = {"scenarios": len(close_report["cases"]), "assertions": close_report["assertion_count"]}
    appearance = json.loads((out / f"verification/{variant}-appearance.json").read_text())
    assert appearance["status"] == "passed" and appearance["app_build"] == info["CFBundleVersion"]
    assert {(case["theme"], case["strategy"]) for case in appearance["cases"]} == {
        (theme, strategy) for theme in ["system", "light", "dark"] for strategy in ["original", "preserveImages", "basic"]}
    for case in appearance["cases"]:
        assert case["status"] == "passed" and set(case["phases"]) == {"write", "read", "cleanup"}
        assert len({phase["pid"] for phase in case["phases"].values()}) == 3
        assert all(phase["status"] == "passed" and phase["native_termination_notification"] and
                   phase["assertion_count"] == len(phase["assertions"]) for phase in case["phases"].values())
    assert appearance["assertion_count"] == sum(phase["assertion_count"] for case in appearance["cases"] for phase in case["phases"].values())
    appearance_restarts[variant] = {"combinations": len(appearance["cases"]), "assertions": appearance["assertion_count"]}
assert all(reports[name]["app_version"] == info["CFBundleShortVersionString"] and
           reports[name]["app_build"] == info["CFBundleVersion"] for name in ["debug", "optimized"])
if args.notarized:
    assert reports["production"]["developer_id_signed"] and reports["production"]["hardened_runtime"]
    for name in ["app-notarization", "dmg-notarization"]:
        receipt = json.loads((out / "verification" / f"{name}.json").read_text())
        assert receipt["status"] == "Accepted"
    subprocess.run(["xcrun", "stapler", "validate", str(args.app)], check=True)
    subprocess.run(["xcrun", "stapler", "validate", str(out / "AdaptivePDF.dmg")], check=True)
    subprocess.run(["spctl", "--assess", "--type", "execute", str(args.app)], check=True)

sources = []
for base in ["AdaptivePDF", "AdaptivePDF.xcodeproj", "Tests", "scripts", "Verification", "Vendor", "docs"]:
    sources.extend(path for path in (root / base).rglob("*") if path.is_file() and
                   not {"__pycache__", "xcuserdata"}.intersection(path.parts))
sources.extend(root / name for name in ["README.md", "TESTING.md", "RELEASE.md", ".gitignore", ".gitattributes"])
source_hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(sources)}
source_archive = out / "AdaptivePDF-source.zip"
with zipfile.ZipFile(source_archive, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(sources):
        archive.write(path, Path("AdaptivePDF") / path.relative_to(root))
artifacts = {}
for path in sorted(out.glob("*")):
    if path.suffix in {".zip", ".dmg"}:
        if path.suffix == ".zip":
            with zipfile.ZipFile(path) as archive:
                assert archive.testzip() is None
        artifacts[path.name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size}
corpus_summary = {"status": "missing"}
if (out / "verification/corpus.json").is_file():
    corpus = json.loads((out / "verification/corpus.json").read_text())
    independent = json.loads((out / "verification/corpus-independent.json").read_text())
    assert corpus["status"] == independent["status"] == "passed"
    assert corpus["app_build"] == info["CFBundleVersion"]
    assert {case["id"] for case in corpus["cases"]} == {case["id"] for case in independent["cases"]}
    assert all(case["status"] == "passed" and case["all_content_streams_exact"] and
               case["all_pypdf_text_exact"] and case["all_font_image_resource_streams_exact"] for case in independent["cases"])
    corpus_summary = {"status": "passed", "documents": len(corpus["cases"]),
                      "pages": sum(case["pages"] for case in corpus["cases"]),
                      "source_hashes": {case["id"]: case["source_sha256"] for case in corpus["cases"]}}
manifest = {
    "schema_version": 1, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    "channel": "notarized" if args.notarized else "candidate",
    "notarized": args.notarized, "ready_for_public_distribution": False,
    "remaining_gates": ["native end-to-end UI authorization and QA", "Preview interoperability",
                        "publisher identity, bundle identifier, support contact and distribution license"]
        + ([] if corpus_summary["status"] == "passed" else ["full corpus regression"])
        + ([] if args.notarized else ["Developer ID signature", "Apple notarization and stapling"]),
    "automated_assertions_per_configuration": reports["debug"]["assertion_count"],
    "independent_pdf_checks_per_configuration": 5,
    "independent_form_checks_per_configuration": 2,
    "independent_pointer_pdf_checks_per_configuration": 2,
    "close_quit_regression": close_flows,
    "appearance_restart_regression": appearance_restarts,
    "corpus_regression": corpus_summary,
    "artifacts": artifacts, "source_sha256": source_hashes,
}
(out / "release-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
(out / "SHA256SUMS").write_text("".join(f"{item['sha256']}  {name}\n" for name, item in artifacts.items()))
# Refresh stable local download paths only after every candidate check passes.
# Stage all copies first; each visible artifact is replaced by an atomic rename.
with tempfile.TemporaryDirectory(prefix=".download-stage-", dir=root / "dist") as staging:
    staging = Path(staging)
    for name, artifact in artifacts.items():
        shutil.copyfile(out / name, staging / name)
        assert hashlib.sha256((staging / name).read_bytes()).hexdigest() == artifact["sha256"]
    for name in artifacts:
        os.replace(staging / name, root / "dist" / name)
(root / "dist/README.txt").write_text(
    f"最新候选包：{manifest['version']} build {manifest['build']}\n{out}\n\n"
    "本目录根部的 DMG、应用 ZIP、源码 ZIP 已同步至该版本。"
    "完整 UI/Preview 验收与发行状态请查看候选目录中的 release-manifest.json。\n")
for older in (root / "dist").glob("AdaptivePDF-*-build*"):
    if older.is_dir() and older != out:
        (older / "SUPERSEDED.txt").write_text(f"此包已由 {manifest['version']} build {manifest['build']} 替代。请使用：\n{out}\n")
print(f"Release artifacts verified: {out}")
print("Public distribution gate: PENDING (see release-manifest.json)")
