"""Complete vector figures, page wrappers, form matrices and inherited state."""
from pathlib import Path

from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject, FloatObject, NameObject
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

out = Path(__file__).parent / "Fixtures/VectorPreservation.pdf"
photo = Image.new("RGB", (48, 32))
photo.putdata([(x * 255 // 47, y * 255 // 31, (x + y) * 255 // 78)
               for y in range(32) for x in range(48)])
c = canvas.Canvas(str(out), pagesize=(612, 792), pageCompression=1, invariant=1)

c.beginForm("nested-label", 0, 0, 80, 30)
c.setFont("Helvetica", 9)
c.drawString(5, 12, "Nested vector")
c.line(5, 7, 73, 7)
c.endForm()


def diagram():
    # These first labels and strokes intentionally inherit the caller's color.
    c.setFont("Helvetica", 13)
    c.drawString(10, 199, "Vector labels, arrows, grayscale cells and photo")
    c.rect(1, 1, 478, 218, fill=0)
    c.line(20, 180, 455, 180)
    for x, color in [(20, (0.85, 0.93, 0.88)), (130, (0.95, 0.89, 0.96)),
                     (240, (1, 0.94, 0.78))]:
        c.saveState()
        c.setFillColorRGB(*color)
        c.roundRect(x, 105, 90, 55, 7, fill=1, stroke=1)
        c.setFillGray(0)
        c.setFont("Helvetica", 11)
        c.drawString(x + 8, 130, "Black label")
        c.restoreState()
        c.line(x + 92, 132, x + 105, 132)
    for row in range(3):
        for column in range(5):
            c.saveState()
            c.setFillGray(((row + column) % 5) / 4)
            c.rect(20 + column * 22, 20 + row * 22, 22, 22, fill=1, stroke=0)
            c.restoreState()
    c.saveState()
    c.setFillAlpha(0.35)
    c.setFillColorRGB(0.2, 0.65, 0.8)
    c.circle(210, 55, 34, fill=1, stroke=0)
    c.setBlendMode("Multiply")
    c.setFillColorRGB(1, 0.6, 0.2)
    c.circle(240, 55, 34, fill=1, stroke=0)
    c.restoreState()
    c.drawImage(ImageReader(photo), 360, 105, 90, 70)
    c.saveState()
    c.translate(350, 35)
    c.doForm("nested-label")
    c.restoreState()


c.beginForm("figure", 0, 0, 480, 220)
diagram()
c.endForm()
c.beginForm("displaced-figure", 20, 30, 500, 250)
c.translate(20, 30)
diagram()
c.endForm()
c.beginForm("page-wrapper", 0, 0, 1224, 1584)
c.scale(2, 2)
c.setFont("Helvetica", 16)
c.drawString(40, 730, "Body text inside a page-sized wrapper")
c.saveState()
c.translate(60, 440)
c.doForm("figure")
c.restoreState()
c.endForm()


def heading(text):
    c.setFont("Helvetica", 16)
    c.drawString(40, 730, text)


heading("Complete vector figure on dark paper")
c.saveState()
c.translate(60, 440)
c.doForm("figure")
c.restoreState()
c.showPage()

c.saveState()
c.scale(0.5, 0.5)
c.doForm("page-wrapper")
c.restoreState()
c.showPage()

heading("Nonzero bounds and a rotated Form Matrix")
c.saveState()
c.translate(80, 180)
c.scale(0.8, 0.8)
c.doForm("displaced-figure")
c.restoreState()
c.showPage()

heading("Repeated forms inherit different gray colors and opacity")
for x, y, gray, clipped in [(60, 440, 0.25, False), (60, 140, 0.7, True)]:
    c.saveState()
    if clipped:
        clip = c.beginPath()
        clip.rect(80, 160, 440, 160)
        c.clipPath(clip, stroke=0)
    c.setFillGray(gray)
    c.setStrokeGray(gray)
    c.setFillAlpha(0.5)
    c.setStrokeAlpha(0.5)
    c.translate(x, y)
    c.doForm("figure")
    c.restoreState()
c.showPage()
c.save()

reader = PdfReader(out)
writer = PdfWriter()
writer.clone_document_from_reader(reader)
for name, ref in writer.pages[2]["/Resources"]["/XObject"].items():
    if "displaced-figure" in name:
        ref.get_object()[NameObject("/Matrix")] = ArrayObject([
            FloatObject(v) for v in [0, 1, -1, 0, 250, -20]])
with out.open("wb") as stream:
    writer.write(stream)
print(out)
