#!/usr/bin/env python3
"""Turn the picked art into what the app bundles: background removed, trimmed, fitted to spec.

    Art/make_art.py            -> Sources/MrRobotoApp/Resources/Art/<name>.png for every pick

Background removal is a flood fill from the image's edges rather than a segmentation model. The art
is flat illustration on a near-uniform pale ground, so "everything connected to the border that is
close to the border's colour" is exactly the background — and, unlike a matte, it can never eat the
white pads or pale screens *inside* a drawing, because those are not connected to the edge.

Pieces marked `cutout: false` (the header bands) keep their ground; they are only trimmed and fitted.
The app icon concept and document icon are exploration and are not bundled.
"""
import json
import statistics
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ART = Path(__file__).resolve().parent
OUT = ART.parent / "Sources" / "MrRobotoApp" / "Resources" / "Art"
# Pieces that become icon files for the packaged .app rather than images the app draws: cut out and
# fitted like the rest, but written beside this script for scripts/make-app.sh to turn into .icns.
ICONS = {"doc-icon": "doc-icon-1024.png"}
NOT_BUNDLED = {"app-icon-concepts", "doc-icon", "band-record", "band-chop", "band-grid", "band-sound"}
# A record's cover (`cover-<album>`) is not the app's to bundle: it is written whole, square, at the
# spec's size, to Art/out/, for dropping on the Album surface. Nothing is trimmed or cut out of it.
# With `title` and `artist` on the entry, they are set in type over the quiet top of the image —
# Futura, which is of the period the covers so far are from — rather than asked of the model.
COVERS = ART / "out"
TYPEFACE = "/System/Library/Fonts/Supplemental/Futura.ttc"


def typeface(size, index=0):
    """Futura at `size`: index 0 is Medium, 2 is Bold in the system's collection; Helvetica if not there."""
    try:
        return ImageFont.truetype(TYPEFACE, size, index=index)
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size)


def set_type(image, title, artist):
    """The title in letter-spaced capitals and the artist beneath, centred in the top of the frame, in
    ivory with a soft dark halo so they read over a photograph without a panel behind them."""
    w, h = image.size
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    ivory = (242, 232, 210, 255)
    title_font, artist_font = typeface(int(h * 0.075)), typeface(int(h * 0.028))
    tracking = int(h * 0.018)

    def width(text, font, spacing):
        return sum(draw.textlength(c, font=font) for c in text) + spacing * (len(text) - 1)

    def spaced(text, font, spacing, y):
        x = (w - width(text, font, spacing)) / 2
        for c in text:
            draw.text((x, y), c, font=font, fill=ivory)
            x += draw.textlength(c, font=font) + spacing

    spaced(title.upper(), title_font, tracking, int(h * 0.075))
    spaced(artist, artist_font, int(tracking * 0.35), int(h * 0.075) + title_font.size + int(h * 0.022))
    halo = layer.getchannel("A").filter(ImageFilter.GaussianBlur(h * 0.012))
    shadow = Image.new("RGBA", image.size, (20, 14, 8, 0))
    shadow.putalpha(halo.point(lambda v: int(v * 0.75)))
    return Image.alpha_composite(Image.alpha_composite(image.convert("RGBA"), shadow), layer).convert("RGB")
TOLERANCE = 26          # how far from the ground colour still counts as ground (sum of RGB differences / 3)
MARGIN = 0.06           # breathing room left around the trimmed subject, as a fraction of the canvas


def ground_colour(image):
    """The median of the border pixels: the ground, whatever the model actually painted."""
    w, h = image.size
    pixels = image.load()
    border = [pixels[x, y] for x in range(0, w, 4) for y in (0, 1, h - 2, h - 1)]
    border += [pixels[x, y] for y in range(0, h, 4) for x in (0, 1, w - 2, w - 1)]
    return tuple(int(statistics.median(p[i] for p in border)) for i in range(3))


def cutout(image):
    rgb = image.convert("RGB")
    ground = ground_colour(rgb)
    # Flood from every border pixel that is ground-coloured into a sentinel colour nothing else uses.
    work = rgb.copy()
    sentinel = (255, 0, 255)
    w, h = work.size
    pixels = work.load()
    seeds = [(x, y) for x in range(0, w, 8) for y in (0, h - 1)] + [(x, y) for y in range(0, h, 8) for x in (0, w - 1)]
    for seed in seeds:
        p = pixels[seed]
        if p != sentinel and sum(abs(p[i] - ground[i]) for i in range(3)) / 3 <= TOLERANCE:
            ImageDraw.floodfill(work, seed, sentinel, thresh=TOLERANCE * 3)
    # Alpha: 0 where the flood reached, 255 elsewhere, softened by a pixel so edges are not jagged.
    diff = ImageChops.difference(work, Image.new("RGB", work.size, sentinel)).convert("L")
    alpha = diff.point(lambda v: 0 if v == 0 else 255)
    alpha = ImageChops.darker(alpha, alpha.filter(ImageFilter.GaussianBlur(0.8)))
    result = rgb.convert("RGBA")
    result.putalpha(alpha)
    return result


def trim(image, keep_ground):
    if keep_ground:
        rgb = image.convert("RGB")
        ground = Image.new("RGB", rgb.size, ground_colour(rgb))
        box = ImageChops.difference(rgb, ground).convert("L").point(lambda v: 255 if v > 10 else 0).getbbox()
    else:
        box = image.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    return image.crop(box) if box else image


def fit(image, size, transparent):
    """Contain the subject in the spec canvas with a margin, never cropping it."""
    w, h = size
    inner = (int(w * (1 - 2 * MARGIN)), int(h * (1 - 2 * MARGIN)))
    scale = min(inner[0] / image.width, inner[1] / image.height)
    resized = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0) if transparent else resized.convert("RGB").getpixel((0, 0)) + (255,))
    canvas.paste(resized, ((w - resized.width) // 2, (h - resized.height) // 2), resized if resized.mode == "RGBA" else None)
    return canvas, scale


def main():
    manifest = {a["name"]: a for a in json.loads((ART / "manifest.json").read_text())["assets"]}
    picks = json.loads((ART / "picks.json").read_text())["picks"]
    only = set(sys.argv[1:])
    OUT.mkdir(parents=True, exist_ok=True)
    for name, file in ICONS.items():
        if name in picks and (not only or name in only):
            icon, _ = fit(trim(cutout(Image.open(ART / "picked" / f"{name}.png")), keep_ground=False), (1024, 1024), True)
            icon.save(ART / file, optimize=True)
            print(f"{name:22} 1024x1024  -> Art/{file}")
    for name in sorted(picks):
        if name in NOT_BUNDLED or (only and name not in only):
            continue
        asset = manifest[name]
        if name.startswith("cover-"):
            COVERS.mkdir(parents=True, exist_ok=True)
            source = Image.open(ART / "picked" / f"{name}.png").convert("RGB")
            side = min(source.size)
            square = source.crop(((source.width - side) // 2, (source.height - side) // 2,
                                  (source.width - side) // 2 + side, (source.height - side) // 2 + side))
            final = square.resize(tuple(asset["size"]), Image.LANCZOS)
            if asset.get("title"):
                final = set_type(final, asset["title"], asset.get("artist", ""))
            final.save(COVERS / f"{name}.png", optimize=True)
            scale = asset["size"][0] / side
            print(f"{name:22} {asset['size'][0]}x{asset['size'][1]}  scale {scale:.2f}"
                  + ("  (upscaled from %d: soft at full size)" % side if scale > 1.2 else "") + f"  -> Art/out/{name}.png")
            continue
        source = Image.open(ART / "picked" / f"{name}.png")
        transparent = asset.get("cutout", False)
        image = cutout(source) if transparent else source.convert("RGBA")
        image = trim(image, keep_ground=not transparent)
        final, scale = fit(image, tuple(asset["size"]), transparent)
        final.save(OUT / f"{name}.png", optimize=True)
        note = "  (upscaled — will be soft)" if scale > 1.2 else ""
        print(f"{name:22} {asset['size'][0]}x{asset['size'][1]}  scale {scale:.2f}{note}")


if __name__ == "__main__":
    main()
