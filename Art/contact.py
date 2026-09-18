#!/usr/bin/env python3
"""Lay candidates out as one contact sheet: a row per asset, a column per candidate, each labelled.

    Art/contact.py cast-director cast-beatmaker cast-sampler     -> Art/contact/cast-director+2.png

The label under each tile is the file name within the asset's folder, which is what you name when
you pick one ("beatmaker gpt-image-2-1").
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ART = Path(__file__).resolve().parent
TILE, GAP, LABEL, HEAD = 420, 24, 34, 44
GROUND, INK, INK2 = (238, 240, 243), (20, 23, 26), (90, 96, 104)


def font(size, mono=False):
    for path in (["/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc"] if mono else
                 ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main():
    names = sys.argv[1:]
    if not names:
        sys.exit("name the assets to lay out")
    rows = [(n, sorted((ART / "candidates" / n).glob("*.png"))) for n in names]
    columns = max(len(files) for _, files in rows)
    width = GAP + columns * (TILE + GAP)
    height = GAP + len(rows) * (HEAD + TILE + LABEL + GAP)
    sheet = Image.new("RGB", (width, height), GROUND)
    draw = ImageDraw.Draw(sheet)
    title, label = font(24), font(16, mono=True)

    y = GAP
    for name, files in rows:
        draw.text((GAP, y + 8), name, fill=INK, font=title)
        y += HEAD
        for index, file in enumerate(files):
            x = GAP + index * (TILE + GAP)
            image = Image.open(file).convert("RGB")
            image.thumbnail((TILE, TILE))
            sheet.paste(image, (x + (TILE - image.width) // 2, y + (TILE - image.height) // 2))
            draw.rectangle([x, y, x + TILE - 1, y + TILE - 1], outline=(198, 204, 212))
            draw.text((x, y + TILE + 8), file.stem, fill=INK2, font=label)
        y += TILE + LABEL + GAP

    out = ART / "contact" / f"{names[0]}{'+' + str(len(names) - 1) if len(names) > 1 else ''}.png"
    out.parent.mkdir(exist_ok=True)
    sheet.save(out)
    print(out)


if __name__ == "__main__":
    main()
