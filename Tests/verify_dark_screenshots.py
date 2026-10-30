#!/usr/bin/env python3
"""Check PDF page pixels captured from the real window, including CA filters.

Use with ADAPTIVEPDF_CAPTURE=1; PDF thumbnails would bypass the display filter.
The AppKit probe supplies a blank margin rectangle on the actual PDF page.
"""
import argparse
import json
import statistics
from pathlib import Path
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
results = []
images = {}
for shot in json.loads((args.output / "screenshots.json").read_text()):
    assert shot["exit_code"] == 0, "Window capture unavailable"
    image = Image.open(args.output / f"window-{shot['mode']}.png").convert("RGB")
    window_width, window_height = shot["window_size"]
    x, y, width, height = shot["page_margin_sample"]
    sx, sy = image.width / window_width, image.height / window_height
    box = (round(x * sx), round((window_height - y - height) * sy),
           round((x + width) * sx), round((window_height - y) * sy))
    assert 0 <= box[0] < box[2] <= image.width and 0 <= box[1] < box[3] <= image.height
    sample = image.crop(box)
    pixels = [sample.getpixel((x,y)) for y in range(sample.height) for x in range(sample.width)]
    rgb = [statistics.median(p[channel] for p in pixels) for channel in range(3)]
    target = 36 if shot["mode"] == "dark" else 255
    assert all(abs(value - target) <= 12 for value in rgb), (shot["mode"], rgb)
    results.append({"mode": shot["mode"], "pdf_page_margin_rgb": rgb, "sample_box_pixels": box})
    x, y, width, height = shot["image_sample"]
    image_box = (round(x * sx), round((window_height - y - height) * sy),
                 round((x + width) * sx), round((window_height - y) * sy))
    images[shot["mode"]] = image.crop(image_box)
assert {case["mode"] for case in results} == {"light", "dark"}
assert images["light"].size == images["dark"].size
from PIL import ImageChops, ImageStat
diff = ImageChops.difference(images["light"], images["dark"])
mean = ImageStat.Stat(diff).mean
assert max(mean) <= 1.0, ("Embedded image colors changed", mean)
report = {"status": "passed", "method": "actual AppKit window screenshot; PDF page margin and embedded image pixels", "cases": results,
          "image_mean_absolute_channel_difference": mean}
(args.output / "dark-pixels.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
