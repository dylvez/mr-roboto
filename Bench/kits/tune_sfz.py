"""Measures each recording of an SFZ against the key it is mapped to, and can write the correction.

    python tune_sfz.py <file.sfz> [...] [--write] [--over 12]

A sampled instrument is only as in tune as its recordings, and a player a third of a semitone
sharp on one note is sharp on that note every time it is played. Each region's sample is read
for its period near its pitch_keycenter, and the pack's own `tune=` counted; with --write, a
region that still lands more than `--over` cents out (and was read with confidence) is given the
`tune=` that brings it back. Struck and bowed-with-vibrato
recordings whose period is not clear are left as they are.
"""
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bake_sfz_kit import load, note  # noqa: E402
from check_tour import likeness  # noqa: E402


def measured(path, key):
    try:
        audio, rate = load(path)
    except Exception:
        return None
    mono = audio.mean(axis=1)
    peak = int(np.argmax(np.abs(mono)))
    # Past the attack, where the note has settled, and no more than a second of it.
    start = min(len(mono) - 1, peak + int(0.1 * rate))
    piece = mono[start:start + int(1.0 * rate)]
    if len(piece) < rate // 5:
        piece = mono[peak:peak + int(0.6 * rate)]
    if len(piece) < rate // 10:
        return None
    period = rate / (440.0 * 2 ** ((key - 69) / 12.0))
    # Several periods at once, so that a cent is a measurable part of the lag; no more than
    # eight, or one period more or fewer would fit inside the range looked through and read as a
    # semitone's error.
    periods = min(8, max(1, int(np.ceil(600.0 / period))))
    best, found = -2.0, 0
    for cents in range(-120, 121, 2):
        score = likeness(piece, periods * period * 2 ** (-cents / 1200.0))
        if score > best:
            best, found = score, cents
    return found, best


def tune(file, write=False, over=12.0):
    """One file, measured and — with `write` — corrected. What was found, as a line."""
    text = open(file, encoding="utf-8", errors="replace").read()
    folder = os.path.dirname(file)
    default = re.search(r"default_path=([^\n]+)", text)
    samples = os.path.normpath(os.path.join(folder, default.group(1).strip().replace("\\", "/"))) if default else folder
    blocks = re.split(r"(?=<region>)", text)
    head, regions = blocks[0], blocks[1:]
    readings, corrected, out = [], 0, []
    for region in regions:
        sample = re.search(r"sample=([^\n]+?)(?=\s+\w+=|\s*$)", region, re.M)
        centre = re.search(r"pitch_keycenter=(\S+)", region) or re.search(r"\bkey=(\S+)", region)
        reading = None
        if sample and centre:
            reading = measured(os.path.join(samples, sample.group(1).strip().replace("\\", "/")), note(centre.group(1)))
        if reading and reading[1] > 0.85:
            # Where the note lands once the pack's own correction, if it has one, is applied.
            existing = re.search(r"\btune=(-?\d+)", region)
            lands = reading[0] + (int(existing.group(1)) if existing else 0)
            readings.append(lands)
            if write and abs(lands) > over and abs(reading[0]) < 110:
                region = re.sub(r"\btune=-?\d+\s*", "", region)
                region = region.rstrip("\n") + "\ntune=%d\n\n" % -reading[0]
                corrected += 1
        out.append(region)
    if readings:
        values = np.array(readings)
        told = "%-34s %3d of %3d read: median %+4.0f, from %+4.0f to %+4.0f cents; %d more than %d out" % (
            os.path.basename(file)[:-4][:34], len(readings), len(regions), np.median(values), values.min(), values.max(),
            int(np.sum(np.abs(values) > over)), over)
    else:
        told = "%-34s none of %d could be read" % (os.path.basename(file)[:-4][:34], len(regions))
    if write and corrected:
        open(file, "w").write(head + "".join(out))
        told += "; %d corrected" % corrected
    return told


def main():
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    write = "--write" in sys.argv
    over = float(sys.argv[sys.argv.index("--over") + 1]) if "--over" in sys.argv else 12.0
    for file in [a for a in arguments if a.lower().endswith(".sfz")]:
        print(tune(file, write, over))


if __name__ == "__main__":
    main()
