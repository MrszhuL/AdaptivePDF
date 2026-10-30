#!/usr/bin/env python3
"""Run isolated native close/quit processes; never attach to an existing app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

SCENARIOS = ["window-save", "window-discard", "window-cancel", "window-save-failure",
             "quit-save", "quit-discard", "quit-cancel",
             "multi-quit-review-save", "multi-quit-discard", "multi-quit-cancel"]
parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=SCENARIOS)
parser.add_argument("--require-independent", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
app = args.app.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
source = root / "Tests/Fixtures/Academic.pdf"
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
try:
    from pypdf import PdfReader
except ImportError:
    if args.require_independent:
        raise
    PdfReader = None
cases = []
for scenario in args.scenarios:
    folder = output / scenario
    folder.mkdir(exist_ok=True)
    folder.chmod(0o700)
    report_path = folder / "close-report.json"
    report_path.unlink(missing_ok=True)
    environment = {**os.environ, "ADAPTIVEPDF_TEST_ROOT": str(root),
                   "ADAPTIVEPDF_TEST_OUTPUT": str(folder), "ADAPTIVEPDF_CLOSE_SCENARIO": scenario}
    try:
        with (folder / "native.log").open("w") as log:
            result = subprocess.run([str(app / "Contents/MacOS/AdaptivePDF"), "--self-test"],
                                    env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=30)
    finally:
        folder.chmod(0o700)
    assert result.returncode == 0, f"{scenario}: native flow failed; see {folder / 'native.log'}"
    report = json.loads(report_path.read_text())
    assert report["status"] == "passed" and report["scenario"] == scenario
    assert report["app_build"] == info["CFBundleVersion"]
    assert report["source_sha256"] == source_hash
    assert hashlib.sha256(source.read_bytes()).hexdigest() == source_hash
    expected_quit = "quit" in scenario and not scenario.endswith("cancel")
    assert report["native_termination_notification"] == expected_quit
    if PdfReader:
        original = PdfReader(source)
        for item in report["checked_files"]:
            saved = PdfReader(item["path"])
            assert len(saved.pages) == len(original.pages)
            for before, after in zip(original.pages, saved.pages):
                assert before.get_contents().get_data() == after.get_contents().get_data()
                assert before.extract_text() == after.extract_text()
            comments = [ref.get_object().get("/Contents", "")
                        for page in saved.pages for ref in page.get("/Annots", [])
                        if ref.get_object().get("/Subtype") == "/Text"]
            assert comments == ([item["expected_comment"]] if item["expected_comment"] else [])
    report["independent_pdf_check"] = "passed" if PdfReader else "unavailable"
    cases.append(report)
    print(f"PASS: {scenario}: {report['assertion_count']} native assertions, independent PDF check {report['independent_pdf_check']}", flush=True)
summary = {"schema_version": 1, "status": "passed", "app_build": info["CFBundleVersion"],
           "app_version": info["CFBundleShortVersionString"], "cases": cases,
           "assertion_count": sum(case["assertion_count"] for case in cases),
           "unverified_ui_requirements": ["Save As file-panel confirmation via XCUI", "physical pointer and keyboard end-to-end QA"]}
(output / "close-flows.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
