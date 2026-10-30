#!/usr/bin/env python3
"""Independently validate saved PDF structure with pypdf, outside PDFKit."""
from pathlib import Path
import hashlib
import argparse
from pypdf import PdfReader

root = Path(__file__).resolve().parent.parent
source = PdfReader(root / "Tests/Fixtures/Academic.pdf")
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, default=root / "tmp/test-output")
output = parser.parse_args().output
def digest(data):
    return hashlib.sha256(data).hexdigest()

def images(resources):
    found = []
    for ref in resources.get("/XObject", {}).get_object().values() if "/XObject" in resources else []:
        obj = ref.get_object()
        if obj.get("/Subtype") == "/Image":
            found.append((int(obj["/Width"]), int(obj["/Height"]), int(obj.get("/BitsPerComponent", 0)), digest(obj.get_data())))
        if obj.get("/Subtype") == "/Form":
            found.extend(images(obj.get("/Resources", {})))
    return sorted(found)

def snapshot(reader):
    return [(digest(page.get_contents().get_data()), images(page["/Resources"])) for page in reader.pages]

original = snapshot(source)
baseline = snapshot(PdfReader(output / "before-theme.pdf"))
for name in ["Annotated.pdf", "before-theme.pdf", "after-theme.pdf"]:
    reader = PdfReader(output / name)
    current = snapshot(reader)
    assert [x[1] for x in current] == [x[1] for x in original], f"Decoded image bytes changed in {name}"
    assert current == baseline, f"Theme changed serialized page content in {name}"
    assert [(p.rotation, list(p.cropbox), list(p.mediabox)) for p in reader.pages] == [
        (p.rotation, list(p.cropbox), list(p.mediabox)) for p in source.pages]
    print(f"PASS: {name}: theme leaves page content streams unchanged; original RGB image bytes, rotations and boxes retained")

saved = PdfReader(output / "Annotated.pdf")
annotations = [ref.get_object() for page in saved.pages for ref in page.get("/Annots", [])]
highlights = [a for a in annotations if a.get("/Subtype") == "/Highlight"]
notes = [a for a in annotations if a.get("/Subtype") == "/Text"]
assert len(highlights) == 4 and len(notes) == 1
assert any(a.get("/Contents") == "Saved highlight comment" for a in highlights)
assert notes[0]["/Contents"] == "Sticky note edited and saved again"
for annotation in highlights:
    assert len(annotation["/QuadPoints"]) >= 8
    assert len(annotation["/QuadPoints"]) % 8 == 0
print("PASS: independent parser recognizes four /Highlight annotations with /QuadPoints and one /Text note")
print("PASS: comments survive in standard /Contents fields")
