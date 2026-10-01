"""Writes plain SFZ files, named as a player would name the instrument, that point into a pack.

    python derive_sfz.py <manifest.json> <folder of packs> <out folder>

A pack's own files are named for its maker's convenience ("SViolinVib.sfz") and stop where the
recordings stop. Each entry of the manifest names one instrument: the pack's file it is made
from, what it is called, the family a picker lists it under, and how far past the lowest and
highest recording its range is carried (a recording stretched a tone is not heard as stretched; a
note that does not sound at all is), and how far its keys are moved when the pack maps it where
it is written rather than where it sounds. The files land in one folder with `instruments.json` beside
them, which the app's import reads.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def derive(entry, packs, out):
    source = os.path.join(packs, entry["from"])
    text = open(source, encoding="utf-8", errors="replace").read()
    text = re.sub(r"\r\n?", "\n", text)
    here = os.path.dirname(source)

    def path(match):
        folder = os.path.normpath(os.path.join(here, match.group(1).strip().replace("\\", "/")))
        return "default_path=" + os.path.relpath(folder, out) + "/"

    if re.search(r"default_path=", text):
        text = re.sub(r"default_path=([^\n]+)", path, text)
    else:
        text = "<control>\ndefault_path=%s/\n" % os.path.relpath(here, out) + text
    blocks = re.split(r"(?=<region>)", text)
    head, regions = blocks[0], blocks[1:]
    # Layers that fade into one another by velocity become layers that meet: the app's sampler
    # plays one recording a note, and two that both cover every velocity are one too many.
    split = []
    for region in regions:
        fades_in = re.search(r"xfin_lovel=(\d+)", region), re.search(r"xfin_hivel=(\d+)", region)
        fades_out = re.search(r"xfout_lovel=(\d+)", region), re.search(r"xfout_hivel=(\d+)", region)
        region = re.sub(r"\bxf(in|out)_(lo|hi)vel=\d+\s*", "", region)
        region = re.sub(r"\b(lo|hi)vel=\d+\s*", "", region) if (all(fades_in) or all(fades_out)) else region
        if all(fades_in):
            low = (int(fades_in[0].group(1)) + int(fades_in[1].group(1))) // 2 + 1
            region = region.rstrip("\n") + "\nlovel=%d\n" % low
        if all(fades_out):
            high = (int(fades_out[0].group(1)) + int(fades_out[1].group(1))) // 2
            region = region.rstrip("\n") + "\nhivel=%d\n" % high
        split.append(region)
    regions = split
    # A pack that maps an instrument where it is written, not where it sounds: a piccolo an octave
    # under itself. Moved, so the key played is the note heard.
    shift = entry.get("shift", 0)
    if shift:
        def moved(match):
            return "%s=%d" % (match.group(1), int(match.group(2)) + shift)
        regions = [re.sub(r"\b(lokey|hikey|key|pitch_keycenter)=(\d+)", moved, region) for region in regions]
    keyed = [r for r in regions if re.search(r"lokey=(\d+)", r) and re.search(r"hikey=(\d+)", r)]
    if keyed:
        bottom = min(int(re.search(r"lokey=(\d+)", r).group(1)) for r in keyed)
        top = max(int(re.search(r"hikey=(\d+)", r).group(1)) for r in keyed)
        low, high = max(0, bottom - entry.get("below", 2)), min(127, top + entry.get("above", 2))
        carried = []
        for region in regions:
            found_low, found_high = re.search(r"lokey=(\d+)", region), re.search(r"hikey=(\d+)", region)
            if found_low and int(found_low.group(1)) == bottom:
                region = re.sub(r"lokey=\d+", "lokey=%d" % low, region)
            if found_high and int(found_high.group(1)) == top:
                region = re.sub(r"hikey=\d+", "hikey=%d" % high, region)
            carried.append(region)
        regions = carried
    header = "// %s: %s, %s\n" % (entry["name"], entry["credit"], os.path.basename(entry["from"]))
    open(os.path.join(out, entry["name"] + ".sfz"), "w").write(header + head + "".join(regions))


def main():
    manifest, packs, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    entries = json.load(open(manifest))
    listed = []
    index = os.path.join(out, "instruments.json")
    if os.path.exists(index):
        listed = [e for e in json.load(open(index)) if e["name"] not in {entry["name"] for entry in entries}]
    for entry in entries:
        derive(entry, packs, out)
        # Each recording brought to the key it is mapped to, where it can be read; a drum or a
        # bell whose pitch is not one period is left as its maker left it.
        if entry.get("tune", True):
            from tune_sfz import tune
            told = tune(os.path.join(out, entry["name"] + ".sfz"), write=True)
            if "corrected" in told:
                print(told)
        listed.append({"name": entry["name"], "family": entry["family"], "file": entry["name"] + ".sfz",
                       "credit": entry["credit"], "licence": entry["licence"]})
    json.dump(sorted(listed, key=lambda e: (e["family"], e["name"])), open(index, "w"), indent=1, ensure_ascii=False)
    print("%d instruments written, %d listed in %s" % (len(entries), len(listed), index))


if __name__ == "__main__":
    main()
