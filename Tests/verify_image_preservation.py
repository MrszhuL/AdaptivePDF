#!/usr/bin/env python3
"""Independent pypdf object checks plus rendered RGB/gray/alpha/form/inline crops."""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageChops, ImageStat
from pypdf import PdfReader
from pypdf.generic import ContentStream

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent

def images(reader):
    result, seen = set(), set()
    def canonical(obj):
        obj = obj.get_object()
        if isinstance(obj, dict):
            values = {str(k): canonical(v) for k,v in obj.items() if k != "/Length"}
            if hasattr(obj, "_data"): values["stream_sha256"] = hashlib.sha256(obj._data).hexdigest()
            return values
        if isinstance(obj, list): return [canonical(v) for v in obj]
        return str(obj)
    def visit(obj):
        if hasattr(obj, "idnum"):
            key = (obj.idnum, obj.generation)
            if key in seen: return
            seen.add(key)
        obj = obj.get_object()
        if isinstance(obj, dict):
            if obj.get("/Subtype") == "/Image":
                result.add(hashlib.sha256(json.dumps(canonical(obj), sort_keys=True).encode()).hexdigest())
            for item in obj.values(): visit(item)
        elif isinstance(obj, list):
            for item in obj: visit(item)
    for page in reader.pages: visit(page["/Resources"])
    return result

def inline_images(reader):
    return [hashlib.sha256(operands["data"]).hexdigest()
            for page in reader.pages for operands, op in ContentStream(page["/Contents"], reader).operations
            if op == b"INLINE IMAGE"]

records = []
for name in ["Academic", "ImagePreservation", "AlphaPreservation", "VectorPreservation"]:
    original = PdfReader(root / f"Tests/Fixtures/{name}.pdf")
    display = PdfReader(args.output / f"{name}-image-display.pdf")
    assert images(original) == images(display), "Encoded image or alpha-mask bytes changed"
    assert inline_images(original) == inline_images(display), "Inline image bytes changed"
    assert [page.extract_text() for page in original.pages] == [page.extract_text() for page in display.pages]
    records.append({"fixture": name, "image_streams": len(images(original)), "raw_image_and_inline_bytes_exact": True})

rects = {
    1: [(60, 480, 240, 160), (320, 480, 240, 160), (60, 260, 240, 160), (320, 260, 240, 160)],
    2: [(60, 480, 240, 160), (320, 260, 240, 160)],
    3: [(60, 480, 240, 160), (400, 300, 80, 80)],
    4: [(450, 290, 160, 240)],  # Crop (20,30), rotate 90 degrees.
}
pixel_results = []
for page, regions in rects.items():
    light = Image.open(args.output / f"preservation-source-{page}.png").convert("RGB")
    dark = Image.open(args.output / f"preservation-display-{page}.png").convert("RGB")
    assert light.size == dark.size
    width, height = (730, 570) if page == 4 else (612, 792)
    for x, y, w, h in regions:
        box = (round((x+3)*light.width/width), round((height-y-h+3)*light.height/height),
               round((x+w-3)*light.width/width), round((height-y-3)*light.height/height))
        difference = ImageChops.difference(light.crop(box), dark.crop(box))
        mean = ImageStat.Stat(difference).mean
        assert max(mean) <= 0.5, (page, box, mean)
        pixel_results.append({"page": page, "region": [x,y,w,h], "mean_absolute_channel_difference": mean})
original = Image.open(args.output / "preservation-source-5.png").convert("RGB")
display = Image.open(args.output / "preservation-display-5.png").convert("RGB")
assert ImageChops.difference(original, display).getbbox() is None, "Unsupported compositing page did not retain original appearance"
alpha_results = []
for page in [1, 3]:
    light = Image.open(args.output / f"alpha-source-{page}.png").convert("RGB")
    dark = Image.open(args.output / f"alpha-display-{page}.png").convert("RGB")
    assert max(dark.getpixel((3, 3))) < 64, "Supported opacity page fell back to white"
    for x,y,w,h in [(60,480,240,160),(320,480,240,160),(60,260,240,160),(320,260,240,160)]:
        box=(round((x+4)*light.width/612),round((792-y-h+4)*light.height/792),
             round((x+w-4)*light.width/612),round((792-y-4)*light.height/792))
        mean=ImageStat.Stat(ImageChops.difference(light.crop(box),dark.crop(box))).mean
        assert max(mean) <= 0.5, ("opacity",page,mean)
        alpha_results.append({"page":page,"mean_absolute_channel_difference":mean})
    hidden=(round(80*dark.width/612),round((792-90)*dark.height/792))
    assert max(dark.getpixel(hidden)) < 64, "Invisible image created a white backing"
light = Image.open(args.output / "alpha-source-2.png").convert("RGB")
dark = Image.open(args.output / "alpha-display-2.png").convert("RGB")
assert ImageChops.difference(light,dark).getbbox() is None, "Nested complex blend fallback changed appearance"
vector_results = []
for page, regions in {1: [(60,440,480,220)], 2: [(60,440,480,220)],
                      3: [(80,180,176,384)], 4: [(60,440,480,220),(80,160,440,160)]}.items():
    light = Image.open(args.output / f"vector-source-{page}.png").convert("RGB")
    dark = Image.open(args.output / f"vector-display-{page}.png").convert("RGB")
    assert max(dark.getpixel((3,3))) < 64, "Vector figure made the whole page white"
    for x,y,w,h in regions:
        # Include labels, strokes, neutral cells, transparent fills and nested
        # content across the whole figure, trimming only one edge pixel.
        box = (round(x*light.width/612)+1,round((792-y-h)*light.height/792)+1,
               round((x+w)*light.width/612)-1,round((792-y)*light.height/792)-1)
        diff = ImageChops.difference(light.crop(box), dark.crop(box))
        mean = ImageStat.Stat(diff).mean
        maximum = max(channel[1] for channel in diff.getextrema())
        assert maximum == 0, ("complete vector figure",page,box,mean,maximum)
        vector_results.append({"page":page,"region":[x,y,w,h],"mean_absolute_channel_difference":mean,
                               "maximum_channel_difference":maximum})
    if page == 2:
        # A full-page wrapper must still darken body text outside its figure.
        box = (80, 108, 900, 150)
        a,b = light.crop(box),dark.crop(box)
        left,right = a.load(),b.load()
        pairs = [(left[x,y],right[x,y]) for y in range(a.height) for x in range(a.width) if max(left[x,y])<40]
        assert pairs and sum(min(q)>170 for _,q in pairs)/len(pairs)>0.9, "Page-wrapper body text did not darken"
    if page == 4:
        point = (round(65*dark.width/612),round((792-145)*dark.height/792))
        assert max(dark.getpixel(point)) < 64, "Figure backing escaped its clipping path"
report = {"status": "passed", "objects": records, "image_pixel_checks": pixel_results,
          "opacity_image_pixel_checks": alpha_results, "nested_fallback_isolated": True,
          "complete_vector_figure_checks": vector_results,
          "unsupported_page_original_pixels_exact": True}
(args.output / "image-preservation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
