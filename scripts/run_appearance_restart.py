#!/usr/bin/env python3
"""Verify preference persistence across normal application exits and restarts."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
app, output = args.app.resolve(), args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
cases = []
for mode in ["system", "light", "dark"]:
    for strategy in ["original", "preserveImages", "basic"]:
        folder = output / f"{mode}-{strategy}"
        folder.mkdir(exist_ok=True)
        suite = "local.adaptivepdf.tests." + str(uuid.uuid4())
        environment = {**os.environ, "ADAPTIVEPDF_TEST_ROOT": str(root),
                       "ADAPTIVEPDF_TEST_OUTPUT": str(folder), "ADAPTIVEPDF_TEST_DEFAULTS_SUITE": suite,
                       "ADAPTIVEPDF_EXPECTED_THEME": mode, "ADAPTIVEPDF_EXPECTED_STRATEGY": strategy}
        phases = {}
        try:
            for phase in ["write", "read"]:
                (folder / f"{phase}.json").unlink(missing_ok=True)
                with (folder / f"{phase}.log").open("w") as log:
                    result = subprocess.run([str(app / "Contents/MacOS/AdaptivePDF"), "--self-test"],
                                            env={**environment, "ADAPTIVEPDF_APPEARANCE_PHASE": phase},
                                            stdout=log, stderr=subprocess.STDOUT, timeout=20)
                assert result.returncode == 0, f"{mode}/{strategy}/{phase}: see {folder / f'{phase}.log'}"
                phases[phase] = json.loads((folder / f"{phase}.json").read_text())
        finally:
            (folder / "cleanup.json").unlink(missing_ok=True)
            with (folder / "cleanup.log").open("w") as log:
                cleanup = subprocess.run([str(app / "Contents/MacOS/AdaptivePDF"), "--self-test"],
                                         env={**environment, "ADAPTIVEPDF_APPEARANCE_PHASE": "cleanup"},
                                         stdout=log, stderr=subprocess.STDOUT, timeout=20)
            assert cleanup.returncode == 0, f"Preference cleanup failed: {folder / 'cleanup.log'}"
        phases["cleanup"] = json.loads((folder / "cleanup.json").read_text())
        for phase, report in phases.items():
            assert report["status"] == "passed" and report["phase"] == phase
            assert report["app_build"] == info["CFBundleVersion"]
            assert report["theme"] == mode and report["strategy"] == strategy
            assert report["native_termination_notification"]
            assert report["assertion_count"] == len(report["assertions"])
        assert len({report["pid"] for report in phases.values()}) == 3
        cases.append({"theme": mode, "strategy": strategy, "phases": phases, "status": "passed"})
        print(f"PASS: restart {mode}/{strategy}: independent write/read/cleanup processes and restored native windows", flush=True)
summary = {"status": "passed", "app_build": info["CFBundleVersion"], "cases": cases,
           "assertion_count": sum(phase["assertion_count"] for case in cases for phase in case["phases"].values()),
           "scope": "isolated UserDefaults suites and application-level appearance; global OS settings not changed"}
(output / "appearance-restart.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
