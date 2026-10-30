#!/usr/bin/env python3
from pathlib import Path
from io import BytesIO
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from PIL import Image
from pypdf import PdfReader, PdfWriter

out = Path(__file__).parent / "Fixtures"
out.mkdir(exist_ok=True)
buffer = BytesIO()
c = canvas.Canvas(buffer, pagesize=(612, 792), pageCompression=1)
c.setTitle("AdaptivePDF academic test fixture")
for page in range(3):
    c.setFont("Helvetica-Bold", 22)
    c.drawString(54, 724, f"AdaptivePDF | Experiment {page + 1}")
    c.setFont("Times-Roman", 13)
    c.drawString(54, 678, "First selected line: native PDF annotations.")
    c.drawString(54, 657, "Second selected line.")
    c.drawString(54, 620, "Energy: E = mc\u00b2     Integral: f(x) = x\u00b2 + 2x + 1")
    c.drawString(54, 592, "This text remains selectable, searchable and copyable.")
    c.drawString(54, 566, "The chart and image below must retain their saved colors.")
    c.setStrokeColorRGB(0.2, 0.2, 0.2)
    c.line(64, 320, 310, 320)
    c.line(64, 320, 64, 510)
    for color, delta in [((1, 0.1, 0.1), 0), ((0, 0.6, 0.2), 38), ((0.1, 0.3, 1), 76)]:
        c.setStrokeColorRGB(*color)
        c.setLineWidth(2)
        p = c.beginPath()
        p.moveTo(64, 340 + delta)
        p.curveTo(130, 480 + delta / 3, 220, 320 + delta / 4, 310, 440 + delta / 2)
        c.drawPath(p)
    image = Image.new("RGB", (192, 128))
    image.putdata([(x * 255 // 191, y * 255 // 127, (x + y) * 255 // 318) for y in range(128) for x in range(192)])
    c.drawImage(ImageReader(image), 350, 340, width=192, height=128)
    c.setFillColorRGB(0, 0, 0)
    c.setFont("Helvetica", 11)
    c.drawString(54, 278, "Vector color curves + embedded RGB raster: preservation fixture")
    c.drawString(54, 100, f"Page {page + 1}: cross-page selection starts or ends here.")
    c.showPage()
c.save()
reader = PdfReader(buffer)
writer = PdfWriter()
for page in reader.pages:
    writer.add_page(page)
writer.pages[1].rotate(90)
writer.pages[1].cropbox.lower_left = (20, 20)
writer.pages[1].cropbox.upper_right = (590, 770)
with (out / "Academic.pdf").open("wb") as f:
    writer.write(f)
encrypted = PdfWriter()
encrypted.clone_document_from_reader(PdfReader(out / "Academic.pdf"))
encrypted.encrypt("reader", "owner", algorithm="AES-256")
with (out / "Encrypted.pdf").open("wb") as f:
    encrypted.write(f)
print(out)
