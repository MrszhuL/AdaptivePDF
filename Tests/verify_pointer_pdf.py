#!/usr/bin/env python3
"""Independently inspect comments and coordinates produced by page hit tests."""
import argparse
from pathlib import Path
from pypdf import PdfReader

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, default=root / "tmp/test-output")
output = parser.parse_args().output
source = PdfReader(root / "Tests/Fixtures/Academic.pdf")
saved = PdfReader(output / "Pointer-annotated.pdf")
assert len(source.pages) == len(saved.pages) == 3
for before, after in zip(source.pages, saved.pages):
    assert before.get_contents().get_data() == after.get_contents().get_data()
    assert before.extract_text() == after.extract_text()
    assert before.rotation == after.rotation and list(before.cropbox) == list(after.cropbox)
print("PASS: pointer-annotated PDF retains every page content stream, text, rotation and crop box")
notes, highlights = [], []
for index, page in enumerate(saved.pages):
    for reference in page.get("/Annots", []):
        annotation = reference.get_object()
        if annotation.get("/Subtype") == "/Text":
            notes.append(annotation["/Contents"])
            mode = annotation["/Contents"].split()[-1]
            assert mode in ["light", "dark"] and index in [0, 1]
            x = float(source.pages[index].cropbox.left) + 100 + (80 if mode == "dark" else 0)
            y = float(source.pages[index].cropbox.bottom) + 150
            assert abs(float(annotation["/Rect"][0]) - x) < 0.5
            assert abs(float(annotation["/Rect"][1]) - y) < 0.5
        elif annotation.get("/Subtype") == "/Highlight":
            highlights.append(annotation["/Contents"])
            assert len(annotation["/QuadPoints"]) == 16
assert set(notes) == {f"Pointer note page {page} {mode}" for page in [1, 2] for mode in ["light", "dark"]}
assert len(notes) == 4
assert set(highlights) == {"Pointer highlight light", "Pointer highlight dark"} and len(highlights) == 2
print("PASS: four positioned standard notes and two multi-line highlights retain their hit-edited comments")
