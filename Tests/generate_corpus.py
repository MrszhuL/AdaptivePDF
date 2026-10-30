#!/usr/bin/env python3
"""Create an ignored local regression corpus; never redistribute downloaded PDFs."""
import argparse
import hashlib
import json
import urllib.request
from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader

parser = argparse.ArgumentParser()
parser.add_argument("--fetch", action="store_true", help="Download pinned public-paper PDFs if missing")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = root / "tmp/corpus"
out.mkdir(parents=True, exist_ok=True)
sources = json.loads((root / "Tests/corpus-sources.json").read_text())["cases"]
for case in sources:
    path = out / case["file"]
    if not path.exists() and args.fetch:
        temporary = path.with_suffix(".download")
        request = urllib.request.Request(case["source"], headers={"User-Agent": "AdaptivePDF-local-regression/1.0"})
        with urllib.request.urlopen(request, timeout=240) as response, temporary.open("wb") as target:
            while chunk := response.read(65536):
                target.write(chunk)
        temporary.rename(path)
    if not path.exists():
        raise SystemExit(f"Missing {path}; rerun with --fetch")
    assert hashlib.sha256(path.read_bytes()).hexdigest() == case["sha256"], f"Pinned paper bytes changed: {path}"
    assert len(PdfReader(path).pages) == case["pages"]

native = out / "native-400.pdf"
c = canvas.Canvas(str(native), pagesize=(612, 792), pageCompression=1)
c.setTitle("AdaptivePDF generated 400-page native regression")
for index in range(400):
    c.setFont("Helvetica-Bold", 20)
    c.drawString(50, 726, f"AdaptivePDF Native Stress Page {index + 1}")
    c.setFont("Times-Roman", 13)
    for line in range(12):
        c.drawString(50, 680 - line * 22, f"Selectable mathematical text {line}: E = mc\u00b2, y = x\u00b2 + 2x + 1.")
    for r, g, b, offset in [(1, .1, .1, 0), (.1, .7, .2, 30), (.1, .3, 1, 60)]:
        c.setStrokeColorRGB(r, g, b)
        p = c.beginPath();p.moveTo(60, 200 + offset);p.curveTo(180, 350, 280, 170, 530, 290 + offset)
        c.drawPath(p)
    if index % 10 == 0:
        c.textAnnotation(f"Existing note on page {index + 1}", Rect=(530, 680, 550, 700))
    c.showPage()
c.save()

scanned = out / "scanned-24.pdf"
c = canvas.Canvas(str(scanned), pagesize=(612, 792), pageCompression=1)
c.setTitle("AdaptivePDF generated scan-only regression")
font = ImageFont.load_default(size=34)
for index in range(24):
    # Independent sensor-like background noise prevents this from behaving like
    # a tiny, deduplicated single-image PDF. Raster text intentionally has no OCR.
    image = Image.effect_noise((1440, 1920), 16).point(lambda value: 180 + value * 75 // 255)
    drawing = ImageDraw.Draw(image)
    drawing.text((90, 110), f"Scanned experimental notebook - page {index + 1}", fill=25, font=font)
    for line in range(25):
        drawing.text((90, 220 + 54 * line), f"Experiment {index + 1:02d}.{line:02d}  Temperature: 298 K  E = mc2", fill=40, font=font)
    c.drawImage(ImageReader(image), 0, 0, width=612, height=792)
    c.showPage()
c.save()

for id, path, kind, pages in [("native-400", native, "native", 400), ("scanned-24", scanned, "scanned", 24)]:
    sources.append({"id": id, "file": path.name, "kind": kind, "pages": pages,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "source": None})
(out / "manifest.json").write_text(json.dumps({"schema_version": 1, "cases": sources}, indent=2) + "\n")
print(out / "manifest.json")
