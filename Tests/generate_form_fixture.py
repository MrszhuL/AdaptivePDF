#!/usr/bin/env python3
"""Deterministic public AcroForm fixture, independent of PDFKit's serializer."""
from pathlib import Path
from reportlab.pdfgen import canvas
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DictionaryObject, NameObject, ArrayObject

output = Path(__file__).parent / "Fixtures/Forms.pdf"
c = canvas.Canvas(str(output), pagesize=(612, 792), invariant=1)
c.setTitle("AdaptivePDF AcroForm preservation fixture")
c.setFont("Helvetica", 14)
c.drawString(50, 740, "Native PDF form values must survive save, undo and reopen.")
form = c.acroForm
form.textfield(name="reader", value="Original reader", x=60, y=650, width=260, height=28)
form.choice(name="decision", value="pending", options=["pending", "accepted", "rejected"],
            x=60, y=580, width=180, height=28)
form.checkbox(name="reviewed", x=60, y=520, checked=False, buttonStyle="check")
form.textfield(name="reference", value="Read only reference", x=60, y=450,
               width=260, height=28, fieldFlags="readOnly")
c.showPage()
c.save()
# Exercise a common inherited field hierarchy: the page widget is a /Kid,
# while its field name/type/value live in /AcroForm /Fields, outside the page.
writer = PdfWriter(clone_from=PdfReader(output))
fields = writer._root_object["/AcroForm"]["/Fields"]
for index, reference in enumerate(fields):
    widget = reference.get_object()
    if widget.get("/T") != "reader":
        continue
    parent = DictionaryObject()
    for key in ["/FT", "/T", "/V", "/DV", "/Ff", "/DA", "/MaxLen"]:
        if key in widget:
            parent[NameObject(key)] = widget.pop(key)
    parent[NameObject("/Kids")] = ArrayObject([reference])
    parent_reference = writer._add_object(parent)
    widget[NameObject("/Parent")] = parent_reference
    fields[index] = parent_reference
with output.open("wb") as stream:
    writer.write(stream)
encrypted = PdfWriter(clone_from=PdfReader(output))
encrypted.encrypt("reader", "owner", algorithm="AES-256")
with output.with_name("EncryptedForms.pdf").open("wb") as stream:
    encrypted.write(stream)
no_prompt = PdfWriter(clone_from=PdfReader(output))
no_prompt.encrypt("", "owner", algorithm="AES-256")
with output.with_name("EncryptedFormsEmptyPassword.pdf").open("wb") as stream:
    no_prompt.write(stream)
print(output)
