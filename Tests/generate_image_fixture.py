"""RGB, gray, alpha, nested forms, inline image and conservative fallback cases."""
from io import BytesIO
from pathlib import Path
from PIL import Image, ImageCms
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject, DecodedStreamObject, NameObject, NumberObject

out = Path(__file__).parent / "Fixtures/ImagePreservation.pdf"
data = BytesIO()
c = canvas.Canvas(data, pagesize=(612, 792), pageCompression=1)
rgb = Image.new("RGB", (120, 80))
rgb.putdata([(x*255//119, y*255//79, (x+y)*255//198) for y in range(80) for x in range(120)])
alpha = rgb.convert("RGBA")
alpha.putalpha(Image.linear_gradient("L").resize(rgb.size))

def header(text):
    c.setFillColorRGB(0, 0, 0)
    c.setFont("Helvetica", 16)
    c.drawString(40, 730, text)

header("RGB, grayscale and transparent image colors")
c.drawImage(ImageReader(rgb), 60, 480, 240, 160)
c.drawImage(ImageReader(alpha), 320, 480, 240, 160, mask="auto")
c.drawImage(ImageReader(rgb.convert("L")), 60, 260, 240, 160)
c.drawImage(ImageReader(rgb.convert("CMYK")), 320, 260, 240, 160)
c.showPage()

c.beginForm("nested", 0, 0, 120, 80)
c.drawImage(ImageReader(rgb), 0, 0, 120, 80)
c.endForm()
c.beginForm("outer", 0, 0, 240, 160)
c.scale(2, 2); c.doForm("nested")
c.endForm()
header("Nested and repeated form images")
for x, y in [(60, 480), (320, 260)]:
    c.saveState(); c.translate(x, y); c.doForm("outer"); c.restoreState()
c.showPage()

header("Inline binary image and clipping")
c.drawInlineImage(rgb, 60, 480, 240, 160)
c.saveState()
p = c.beginPath(); p.circle(440, 340, 65); c.clipPath(p, stroke=0)
c.drawImage(ImageReader(rgb), 320, 260, 240, 160)
c.restoreState()
c.showPage()

header("Rotated and cropped image page")
c.drawImage(ImageReader(rgb), 60, 480, 240, 160)
c.showPage()

header("Complex transparency retains original page")
c.saveState(); c.setFillAlpha(0.5)
c.drawImage(ImageReader(rgb), 60, 480, 240, 160)
c.restoreState()
c.showPage()
c.save()
reader = PdfReader(data)
reader.pages[3].rotate(90)
reader.pages[3].cropbox.lower_left = (20, 30)
reader.pages[3].cropbox.upper_right = (590, 760)
writer = PdfWriter()
for page in reader.pages: writer.add_page(page)
profile = DecodedStreamObject()
profile.set_data(ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
profile[NameObject("/N")] = NumberObject(3)
profile[NameObject("/Alternate")] = NameObject("/DeviceRGB")
reference = writer._add_object(profile)
for obj in writer.pages[0]["/Resources"]["/XObject"].values():
    image = obj.get_object()
    if image.get("/ColorSpace") == "/DeviceRGB" and not image.get("/SMask"):
        image[NameObject("/ColorSpace")] = ArrayObject([NameObject("/ICCBased"), reference])
with out.open("wb") as f: writer.write(f)
print(out)
