#!/usr/bin/env python3
"""Verify canonical AcroForm values and field-tree references outside PDFKit."""
import argparse
from pathlib import Path
from pypdf import PdfReader

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, default=root / "tmp/test-output")
output = parser.parse_args().output
source = PdfReader(root / "Tests/Fixtures/Forms.pdf")
for name, text, checkbox in [("Forms-annotated.pdf", "Ada Lovelace", "/Yes"),
                              ("Forms-cleared.pdf", "", "/Off")]:
    reader = PdfReader(output / name)
    fields = reader.get_fields()
    assert fields["reader"]["/V"] == text
    assert fields["decision"]["/V"] == "accepted"
    assert fields["reviewed"]["/V"] == checkbox
    assert fields["reference"]["/V"] == "Read only reference"
    assert fields["reference"]["/Ff"] & 1
    assert fields["reader"]["/DV"] == "Original reader"
    root_fields = reader.trailer["/Root"]["/AcroForm"]["/Fields"]
    text_parent = next(ref for ref in root_fields if ref.get_object().get("/T") == "reader")
    text_widget = text_parent.get_object()["/Kids"][0]
    assert text_widget.get_object()["/Parent"].indirect_reference == text_parent
    assert text_widget in reader.pages[0]["/Annots"]
    button = next(ref.get_object() for ref in reader.pages[0]["/Annots"] if ref.get_object().get("/T") == "reviewed")
    assert button["/AS"] == checkbox
    assert checkbox in button["/AP"]["/N"]
    assert reader.pages[0].get_contents().get_data() == source.pages[0].get_contents().get_data()
    print(f"PASS: {name}: canonical field values, defaults, inherited /Kids-/Parent links and checkbox appearances")
