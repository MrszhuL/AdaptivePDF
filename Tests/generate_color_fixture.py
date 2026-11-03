"""Synthetic solid-color spaces; no article names, bytes or private resources."""
from pathlib import Path
from pypdf import PdfWriter
from pypdf.generic import (
    ArrayObject, DecodedStreamObject, DictionaryObject, FloatObject,
    NameObject, NumberObject, ByteStringObject,
)

writer = PdfWriter()
def name(s): return NameObject(s)
def array(values): return ArrayObject([FloatObject(x) for x in values])
def dictionary(**values): return DictionaryObject({name('/'+k): v for k, v in values.items()})
def stream(data, **values):
    obj = DecodedStreamObject(); obj.update(dictionary(**values)); obj.set_data(data)
    return writer._add_object(obj)
def exponential(c0, c1):
    return dictionary(FunctionType=NumberObject(2), Domain=array([0, 1]),
                      C0=array(c0), C1=array(c1), N=NumberObject(1))
def sampled(size, samples, ranges, decode=None, encode=None):
    values = dict(FunctionType=NumberObject(0), Domain=array([0, 1]*len(size)),
                  Size=ArrayObject([NumberObject(n) for n in size]), BitsPerSample=NumberObject(8),
                  Range=array(ranges))
    if decode is not None: values['Decode'] = array(decode)
    if encode is not None: values['Encode'] = array(encode)
    return stream(bytes(samples), **values)
def separation(tint, alternate='/DeviceCMYK', ink='/NeutralInk'):
    return ArrayObject([name('/Separation'), name(ink), name(alternate), tint])

font = writer._add_object(dictionary(Type=name('/Font'), Subtype=name('/Type1'), BaseFont=name('/Helvetica')))
photo = stream(
    bytes(v for y in range(16) for x in range(24) for v in (x*255//23, y*255//15, (x+y)*255//38)),
    Type=name('/XObject'), Subtype=name('/Image'), Width=NumberObject(24), Height=NumberObject(16),
    ColorSpace=name('/DeviceRGB'), BitsPerComponent=NumberObject(8))
figure_resources = dictionary(Font=dictionary(F1=font), XObject=dictionary(Photo=photo))
figure = stream(b'''0.9 0.95 1 rg 0 0 480 200 re f
0 g 0 G 2 w 1 1 478 198 re S
BT /F1 14 Tf 15 175 Td (Complete vector figure stays unchanged) Tj ET
0.5 g 20 40 80 90 re f 1 g 100 40 80 90 re f
0 g 20 40 160 90 re S 1 0 0 rg 210 50 70 80 re f
q 130 0 0 100 320 40 cm /Photo Do Q
''', Type=name('/XObject'), Subtype=name('/Form'), BBox=array([0,0,480,200]), Resources=figure_resources)

cases = [
    ('Sampled spot ink with Decode and nonstandard name',
     separation(sampled([2], [0,0,0,0,255,255,255,255], [0,0,0,0,0,0,0,1], [0,0,0,0,0,0,0,1])), '1', '0', None),
    ('Exponential spot ink', separation(exponential([0,0,0,0], [0,0,0,1])), '1', '0', None),
    ('Stitching spot ink', separation(dictionary(FunctionType=NumberObject(3), Domain=array([0,1]),
        Functions=ArrayObject([exponential([0],[1]), exponential([1],[0])]),
        Bounds=array([0.5]), Encode=array([0,1,0,1])), '/DeviceGray'), '1', '0.5', None),
    ('Calculator spot ink with neutral and colored tints',
     separation(stream(b'{ dup 0.5 le { 2 mul 1 exch sub 1 exch dup } { 2 mul 2 exch sub 0 0 } ifelse }',
         FunctionType=NumberObject(4), Domain=array([0,1]), Range=array([0,1]*3)), '/DeviceRGB'), '1', '0', '0.5'),
    ('Two-channel DeviceN sampled ink', ArrayObject([name('/DeviceN'), ArrayObject([name('/InkA'),name('/InkB')]), name('/DeviceCMYK'),
        sampled([2,2], [v for k in (0,128,128,255) for v in (0,0,0,k)], [0,1]*4)]), '1 1', '0 0', None),
    ('Indexed RGB lookup with neutral colors', ArrayObject([name('/Indexed'), name('/DeviceRGB'), NumberObject(1),
        ByteStringObject(bytes([255,255,255,0,0,0]))]), '1', '0', None),
    ('Lab color and lightness', ArrayObject([name('/Lab'), dictionary(WhitePoint=array([0.9505,1,1.089]), Range=array([-128,127,-128,127]))]),
        '0 0 0', '100 0 0', '54 80 67'),
    ('Invisible None ink with ordinary body text', separation(exponential([1],[0]), '/DeviceGray', '/None'), '1', '0', None),
    ('Page wrapper with spot ink and bounded figure', separation(exponential([0,0,0,0],[0,0,0,1])), '1', '0', None),
]

for index, (label, space, black, white, colored) in enumerate(cases):
    page = writer.add_blank_page(612,792)
    resources = dictionary(Font=dictionary(F1=font), ColorSpace=dictionary(Ink=space), XObject=dictionary(Figure=figure, Photo=photo))
    # Exercise defaults, source-space restoration after mapped gray, stroke,
    # q/Q, and a raster image and complete vector figure on every page.
    body = f'''0 g BT /F1 14 Tf 40 730 Td ({label}) Tj ET
/Ink cs BT /F1 12 Tf 40 705 Td (Default ink color) Tj ET
/Ink cs {black} scn 40 650 120 30 re f
{white} scn 190 650 120 30 re f
{black} scn BT /F1 14 Tf 40 605 Td (Body text in a named color space) Tj ET
/Ink CS {black} SCN 3 w 40 580 m 310 580 l S
q {white} scn 40 550 50 15 re f Q
320 550 80 15 re f
q 1 0 0 1 60 340 cm /Figure Do Q
q 180 0 0 120 60 160 cm /Photo Do Q
'''
    if colored:
        body += f'/Ink cs {black} scn 350 650 60 30 re f\n{colored} scn 430 650 120 30 re f\n'
        body += f'/Ink CS {black} SCN 350 600 m 410 600 l S\n{colored} SCN 430 600 m 550 600 l S\n'
    if index == 7:
        body += '0 g BT /F1 14 Tf 40 100 Td (Visible text outside invisible ink) Tj ET\n'
    if index == 8:
        wrapper = stream(body.encode(), Type=name('/XObject'), Subtype=name('/Form'), BBox=array([0,0,612,792]), Resources=resources)
        resources = dictionary(XObject=dictionary(Wrapper=wrapper))
        body = '/Wrapper Do\n'
    page[name('/Resources')] = resources
    page[name('/Contents')] = stream(body.encode())

out = Path(__file__).parent/'Fixtures/ColorSpacePreservation.pdf'
writer.write(out)
print(out)
