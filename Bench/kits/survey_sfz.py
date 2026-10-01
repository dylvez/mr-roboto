"""Says what an SFZ file is, as a player with its controllers at rest would find it.

    python survey_sfz.py <file.sfz or folder> [...]

For each file: how many regions sound, over which keys, in how many velocity layers and round
robins, whether any key plays more than one recording at once (several microphones, which have to
be mixed down before Mr. Roboto can play them), whether it switches articulation by key, what
its samples are and how long, and whether the samples are there.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bake_sfz_kit import Player, load, note, parse  # noqa: E402

NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]


def name(key):
    return "%s%d" % (NAMES[key % 12], key // 12 - 1)


def survey(path):
    try:
        control, curves, regions = parse(path)
    except Exception as error:  # a file that does not read is said, not fatal
        return "%s: could not be read (%s)" % (os.path.basename(path), error)
    player = Player(control, curves, {})
    folder = os.path.join(os.path.dirname(path), control.get("default_path", "").replace("\\", "/"))
    sounding, switched, release, silent, missing = [], 0, 0, 0, 0
    kinds, size, seconds = {}, 0, []
    for region in regions:
        sample = region.get("sample", "")
        if not sample or sample.startswith("*"):
            silent += 1
            continue
        if region.get("trigger", "attack") != "attack":
            release += 1
            continue
        if not player.sounds(region):
            continue
        if any(key in region for key in ("sw_last", "sw_down", "sw_up", "sw_previous")):
            switched += 1
            default = control.get("sw_default", region.get("sw_default"))
            if default is not None and "sw_last" in region and note(region["sw_last"]) != note(default):
                continue
        file = os.path.normpath(os.path.join(folder, sample.replace("\\", "/")))
        if not os.path.exists(file):
            missing += 1
            continue
        extension = os.path.splitext(file)[1].lower()
        kinds[extension] = kinds.get(extension, 0) + 1
        size += os.path.getsize(file)
        if len(seconds) < 40:
            try:
                audio, rate = load(file)
                seconds.append(len(audio) / float(rate))
            except Exception:
                pass
        sounding.append(region)
    if not sounding:
        return "%s: nothing sounds (%d regions, %d missing samples, %d release, %d silent)" % (
            os.path.basename(path), len(regions), missing, release, silent)
    lows = [note(r.get("lokey", r.get("key", "0"))) for r in sounding]
    highs = [note(r.get("hikey", r.get("key", "127"))) for r in sounding]
    layers = sorted({(int(r.get("lovel", 1)), int(r.get("hivel", 127))) for r in sounding})
    robins = max(int(r.get("seq_length", 1)) for r in sounding)
    random = any("lorand" in r or "hirand" in r for r in sounding)
    slots = {}
    for r in sounding:
        slot = (note(r.get("lokey", r.get("key", "0"))), note(r.get("hikey", r.get("key", "127"))),
                int(r.get("lovel", 1)), int(r.get("hivel", 127)), int(r.get("seq_position", 1)),
                r.get("lorand", ""), r.get("hirand", ""))
        slots[slot] = slots.get(slot, 0) + 1
    stacked = max(slots.values())
    loops = sum(1 for r in sounding if r.get("loop_mode") in ("loop_continuous", "loop_sustain"))
    told = "%s: %d regions, %s-%s, %d layer%s, %d round robin%s%s" % (
        os.path.basename(path), len(sounding), name(min(lows)), name(max(highs)), len(layers), "" if len(layers) == 1 else "s",
        robins, "" if robins == 1 else "s", " (random)" if random else "")
    told += ", %s" % ", ".join("%d %s" % (count, kind) for kind, count in sorted(kinds.items()))
    if seconds:
        told += ", %.1f-%.1f s" % (min(seconds), max(seconds))
    told += ", %d MB" % (size // 1048576)
    if stacked > 1:
        told += "; UP TO %d RECORDINGS A KEY AT ONCE" % stacked
    if switched:
        told += "; switches by key (%d regions)" % switched
    if loops:
        told += "; %d looped" % loops
    if missing:
        told += "; %d samples missing" % missing
    if release:
        told += "; %d release samples left out" % release
    return told


def main():
    for target in sys.argv[1:]:
        if os.path.isdir(target):
            files = sorted(os.path.join(root, file) for root, _, names in os.walk(target) for file in names
                           if file.lower().endswith(".sfz"))
        else:
            files = [target]
        for file in files:
            print(survey(file))


if __name__ == "__main__":
    main()
