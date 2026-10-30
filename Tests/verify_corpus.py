#!/usr/bin/env python3
"""Independent, strict content verification. PDFKit extraction order is not used."""
import argparse
import hashlib
import json
from pathlib import Path
from pypdf import PdfReader

parser = argparse.ArgumentParser()
parser.add_argument("--manifest", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
cases = json.loads(args.manifest.read_text())["cases"]
native = json.loads((args.output / "corpus-report.json").read_text())
assert native["status"] == "passed"

def stream_hash(value):
    return hashlib.sha256(value.get_object().get_data()).hexdigest()

def resource_streams(resources, seen=None):
    seen = set() if seen is None else seen
    result = []
    def walk(value, path):
        if hasattr(value, "idnum"):
            key = (value.idnum, value.generation)
            if key in seen:
                return
            seen.add(key)
        value = value.get_object() if hasattr(value, "get_object") else value
        if hasattr(value, "get_data"):
            result.append((path, stream_hash(value)))
        if isinstance(value, dict):
            for key, item in sorted(value.items()):
                if key not in {"/Length", "/Parent", "/P"}:
                    walk(item, path + key)
        elif isinstance(value, list):
            for index, item in enumerate(value):
                walk(item, path + f"[{index}]")
    walk(resources, "")
    return sorted(result)

def urls(page):
    found = []
    for reference in page.get("/Annots", []):
        annotation = reference.get_object()
        action = annotation.get("/A", {})
        action = action.get_object() if hasattr(action, "get_object") else action
        if action.get("/S") == "/URI":
            found.append(str(action.get("/URI")))
    return sorted(found)

reports = []
for case in cases:
    source = args.manifest.parent / case["file"]
    assert hashlib.sha256(source.read_bytes()).hexdigest() == case["sha256"]
    before = PdfReader(source)
    after = PdfReader(args.output / f"{case['id']}-annotated.pdf")
    assert len(before.pages) == len(after.pages) == case["pages"]
    for index, (a, b) in enumerate(zip(before.pages, after.pages)):
        assert a.get_contents().get_data() == b.get_contents().get_data(), (case["id"], index, "content stream")
        assert a.extract_text() == b.extract_text(), (case["id"], index, "Unicode text")
        assert resource_streams(a["/Resources"]) == resource_streams(b["/Resources"]), (case["id"], index, "fonts/maps/images")
        assert list(a.mediabox) == list(b.mediabox) and list(a.cropbox) == list(b.cropbox) and a.rotation == b.rotation
        assert urls(a) == urls(b), (case["id"], index, "external links")
    annotations = [ref.get_object() for page in after.pages for ref in page.get("/Annots", [])]
    assert any(a.get("/Subtype") == "/Text" and a.get("/Contents") == "AdaptivePDF corpus regression" for a in annotations)
    if case["kind"] != "scanned":
        assert any(a.get("/Subtype") == "/Highlight" and len(a.get("/QuadPoints", [])) >= 8 for a in annotations)
    reports.append({"id": case["id"], "pages": len(after.pages), "status": "passed",
                    "all_content_streams_exact": True, "all_pypdf_text_exact": True,
                    "all_font_image_resource_streams_exact": True, "links_and_boxes_retained": True})
    print(f"PASS: {case['id']}: all {case['pages']} pages retain exact content, Unicode, font/image streams, links and page boxes")
(args.output / "independent-corpus-report.json").write_text(json.dumps({"schema_version": 1, "status": "passed", "cases": reports}, indent=2) + "\n")
