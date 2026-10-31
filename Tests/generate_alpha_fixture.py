"""Normal opacity plus a nested unsupported blend between supported pages."""
from pathlib import Path
from PIL import Image
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
out=Path(__file__).parent/'Fixtures/AlphaPreservation.pdf'
rgb=Image.new('RGB',(120,80))
rgb.putdata([(x*255//119,y*255//79,(x+y)*255//198) for y in range(80) for x in range(120)])
rgba=rgb.convert('RGBA');rgba.putalpha(Image.linear_gradient('L').resize(rgb.size))
c=canvas.Canvas(str(out),pagesize=(612,792),pageCompression=1,invariant=1)
c.beginForm('photo',0,0,240,160);c.drawImage(ImageReader(rgb),0,0,240,160);c.endForm()
# A page-sized wrapper must still be inspected; its own unsupported blend must
# not disable supported pages before and after it.
c.beginForm('unsupported',0,0,612,792);c.drawImage(ImageReader(rgb),0,0,240,160);c.endForm()
for alpha in [0.5,None,0.25]:
 c.setFont('Helvetica',16);c.drawString(40,730,'Normal opacity images' if alpha else 'Nested complex blend fallback')
 if alpha is None:
  c.saveState();c.translate(60,480);c.doForm('unsupported');c.restoreState()
 else:
  c.saveState();c.setFillAlpha(alpha);c.setStrokeAlpha(alpha)
  c.drawImage(ImageReader(rgb),60,480,240,160)
  c.drawImage(ImageReader(rgba),320,480,240,160,mask='auto')
  c.drawInlineImage(rgb,60,260,240,160)
  c.saveState();c.translate(320,260);c.doForm('photo');c.restoreState()
  c.restoreState()
  c.saveState();c.setFillAlpha(0);c.drawImage(ImageReader(rgb),60,70,60,40);c.restoreState()
 c.showPage()
c.save()
from pypdf import PdfReader,PdfWriter
from pypdf.generic import DictionaryObject,NameObject,DecodedStreamObject
reader=PdfReader(out);writer=PdfWriter();writer.clone_document_from_reader(reader)
for page in writer.pages:
 for name,ref in list(page['/Resources'].get('/XObject',{}).items()):
  if 'unsupported' not in name: continue
  form=ref.get_object()
  states=DictionaryObject({NameObject('/Complex'):DictionaryObject({NameObject('/BM'):NameObject('/Multiply')})})
  form['/Resources'][NameObject('/ExtGState')]=states
  data=form.get_data()
  clone=DecodedStreamObject()
  clone.update({key:value for key,value in form.items() if key not in ['/Filter','/DecodeParms','/Length']})
  clone.set_data(b'/Complex gs\n'+data)
  page['/Resources']['/XObject'][NameObject(name)]=writer._add_object(clone)
with out.open('wb') as f: writer.write(f)
print(out)
