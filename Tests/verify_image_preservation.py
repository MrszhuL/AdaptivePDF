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
for name in ["Academic", "ImagePreservation"]:
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
report = {"status": "passed", "objects": records, "image_pixel_checks": pixel_results, "unsupported_page_original_pixels_exact": True}
(args.output / "image-preservation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
