"""Writes a plain SFZ of a pack's instrument, as a player with its controllers at rest hears it.

    python flatten_sfz.py <manifest.json> <folder of packs> <out folder> [--only "Name; Name"]

A pack written for a full SFZ player leans on what Mr. Roboto's sampler does not do: includes
and defines, controllers that blend microphones or ride the dynamics, envelopes whose sustain is
a controller's resting value, loops kept inside the recording and not in the file. Read by the
app as it stands, a saxophone whose sustain is "0, plus 100 of controller 103" is a saxophone
that dies. So each instrument is worked out here, key by key, and written as regions that say
everything outright:

* the regions that sound with every controller where the pack rests it, in the articulation the
  pack starts in (or the one the manifest names);
* layers that cross-fade by velocity, or by the mod wheel, expression or breath, as velocity
  layers that meet;
* recordings stacked on a key — two microphones, three — mixed into one file, at the pack's own
  balance (`"stack": "first"` keeps the loudest instead);
* random alternatives as round robins, no more than `robins` of them, no more than `layers`
  velocity layers: every recording is held in memory whole;
* keys the pack leaves out, and `below` and `above` its range, played by the nearest recording;
* a loop the recording carries, written as its loop.

Each entry of the manifest: `name`, `family`, `from` (the pack's file), `credit`, `licence`, and
any of `cc` (controllers moved from rest, {"1": 100}), `switch` (the articulation's key),
`shift`, `below`, `above`, `tune`, `robins`, `layers`, `stack`, `veltrack`, `release`, `keys`
([lowest, highest] the pack's file is read between), `loops`, `without` (words in the names of
recordings to leave out) and `defines` (what the pack's player would have defined for it).
"""
import json
import os
import re
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bake_sfz_kit import Player, load, note, parse, write  # noqa: E402

# A pack's scrapes, slides and string noises sit on keys of their own, past the notes.
NOISES = ("noise", "scrape", "fingering", "squeak", "breath")
DYNAMICS = (1, 11, 2)  # the controllers a pack's dynamics ride on: mod wheel, expression, breath
# What tells two recordings on one key apart without making them different sounds.
INCIDENTAL = ("sample", "pitch_keycenter", "tune", "region_label", "group_label", "seq_position", "lorand", "hirand",
              "offset", "end", "loop_start", "loop_end")


def at_rest(region, name, player):
    """The sum of `name`'s controller terms where the controllers rest."""
    total = 0.0
    for key, value in region.items():
        match = re.fullmatch(r"%s_?(?:on)?cc(\d+)" % name, key)
        if not match:
            continue
        number = int(match.group(1))
        curve = region.get("%s_curvecc%d" % (name, number))
        try:
            total += float(value) * player.shaped(number, int(curve) if curve is not None else None)
        except ValueError:
            pass
    return total


def number(region, name, default=0.0):
    try:
        return float(region.get(name, default))
    except ValueError:
        return default


def fade(region, controller, at):
    """How much of a region a controller lets through at `at`: its cross-fade in, and out."""
    gain = 1.0
    low, high = region.get("xfin_locc%d" % controller), region.get("xfin_hicc%d" % controller)
    if low is not None or high is not None:
        low, high = float(low or 0), float(high or 0)
        gain *= 1.0 if at >= high else 0.0 if at <= low else (at - low) / (high - low)
    low, high = region.get("xfout_locc%d" % controller), region.get("xfout_hicc%d" % controller)
    if low is not None or high is not None:
        low, high = float(low if low is not None else 127), float(high if high is not None else 127)
        gain *= 1.0 if at <= low else 0.0 if at >= high else 1.0 - (at - low) / (high - low)
    return float(np.sqrt(gain))


def faded(region):
    """The controllers a region cross-fades on."""
    return sorted({int(m.group(1)) for key in region for m in [re.fullmatch(r"xf(?:in|out)_(?:lo|hi)cc(\d+)", key)] if m})


def whole(path, known={}):
    """Whether the file is audio that reads. A pack fetched through a tool that took its
    recordings for text has line endings rewritten inside them: a header that no longer says
    WAVE, or a length that is no longer the file's."""
    if path not in known:
        with open(path, "rb") as file:
            head = file.read(12)
        if head[:4] == b"RIFF":
            known[path] = head[8:12] == b"WAVE"
            if known[path] and abs(struct.unpack("<I", head[4:8])[0] + 8 - os.path.getsize(path)) > 1:
                try:
                    load(path)
                except Exception:
                    known[path] = False
        else:
            known[path] = head[:4] in (b"fLaC", b"OggS", b"FORM")
    return known[path]


def loop_in(path):
    """The loop a WAV carries in its `smpl` chunk: (start, end), end inclusive."""
    if not path.lower().endswith(".wav"):
        return None
    try:
        with open(path, "rb") as file:
            if file.read(4) != b"RIFF":
                return None
            file.read(8)
            while True:
                head = file.read(8)
                if len(head) < 8:
                    return None
                kind, size = head[:4], struct.unpack("<I", head[4:])[0]
                if kind == b"smpl":
                    body = file.read(size)
                    if len(body) >= 60 and struct.unpack("<I", body[28:32])[0] >= 1:
                        start, end = struct.unpack("<II", body[44:52])
                        return (start, end) if end > start else None
                    return None
                file.seek(size + (size & 1), 1)
    except OSError:
        return None


class Flattened:
    """One recording on some keys, with everything about it said."""

    def __init__(self, region, path, player, loud, offset):
        self.region, self.path = region, path
        key = region.get("key")
        self.low = note(region.get("lokey", key if key is not None else "0")) + offset
        self.high = note(region.get("hikey", key if key is not None else "127")) + offset
        self.centre = note(region.get("pitch_keycenter", key if key is not None else "60")) + offset
        self.velocity = (int(number(region, "lovel", 1)), int(number(region, "hivel", 127)))
        self.position = int(number(region, "seq_position", 1))
        self.chance = number(region, "lorand", -1.0)
        gain = loud.amplitude(region)
        for name in ("group_volume", "master_volume", "global_volume"):
            gain *= 10 ** (number(region, name) / 20.0)
        for controller in faded(region):
            if controller not in DYNAMICS:
                gain *= fade(region, controller, player.value(controller))
        self.gain = gain
        self.pan = max(-100.0, min(100.0, number(region, "pan") + at_rest(region, "pan", player)))
        self.tune = number(region, "tune") + 100 * number(region, "transpose") + at_rest(region, "tune", player) \
            + at_rest(region, "pitch", player)
        self.offset = max(0, int(round(number(region, "offset") + at_rest(region, "offset", player))))
        self.end = int(number(region, "end")) if "end" in region else None
        self.order = 0

    def same_sound(self, other):
        mine = {k: v for k, v in self.region.items() if k not in INCIDENTAL}
        theirs = {k: v for k, v in other.region.items() if k not in INCIDENTAL}
        return mine == theirs


def chosen(entry, source):
    control, curves, regions = parse(source, entry.get("defines"))
    overrides = {int(k): float(v) for k, v in entry.get("cc", {}).items()}
    player = Player(control, curves, overrides)
    # Loudness is read with the dynamics controllers open: velocity is what plays soft.
    open_wide = {n: 127.0 for n in DYNAMICS}
    open_wide.update(overrides)
    loud = Player(control, curves, open_wide)
    folder = os.path.join(os.path.dirname(source), control.get("default_path", "").replace("\\", "/"))
    offset = int(number(control, "note_offset")) + 12 * int(number(control, "octave_offset"))
    switches = sorted({note(r["sw_last"]) for r in regions if "sw_last" in r})
    switch = entry.get("switch")
    if switch is not None:
        switch = note(str(switch))
    else:
        default = control.get("sw_default") or next((r["sw_default"] for r in regions if "sw_default" in r), None)
        switch = note(default) if default is not None and note(default) in switches else (switches[0] if switches else None)
    limits = entry.get("keys")
    found, missing = [], 0
    for index, region in enumerate(regions):
        sample = region.get("sample", "")
        if not sample or sample.startswith("*"):
            continue
        if region.get("trigger", "attack") not in ("attack", "first"):
            continue
        if any(key in region for key in ("sw_down", "sw_up", "sw_previous")):
            continue
        if "sw_last" in region and note(region["sw_last"]) != switch:
            continue
        if not player.sounds(region):
            continue
        if any(re.fullmatch(r"on_(lo|hi)cc\d+", key) for key in region):
            continue
        if number(region, "pitch_keytrack", 100) == 0 and not entry.get("unpitched"):
            continue
        path = os.path.normpath(os.path.join(folder, sample.replace("\\", "/")))
        if any(word in os.path.basename(path).lower() for word in entry.get("without", NOISES)):
            continue
        if not os.path.exists(path) or not whole(path):
            missing += 1
            continue
        try:
            one = Flattened(region, path, player, loud, offset)
        except ValueError:
            continue
        if one.high < 0 or one.high < one.low:
            continue
        if limits and (one.high < limits[0] or one.low > limits[1]):
            continue
        if limits:
            one.low, one.high = max(one.low, limits[0]), min(one.high, limits[1])
        one.order = index
        found.append(one)
    return found, player, missing


def by_velocity(found, told):
    """Layers that fade into one another, by velocity or by a dynamics controller, made to meet."""
    for one in found:
        region = one.region
        fades_in = region.get("xfin_lovel"), region.get("xfin_hivel")
        fades_out = region.get("xfout_lovel"), region.get("xfout_hivel")
        low, high = one.velocity
        if all(v is not None for v in fades_in):
            low = (int(fades_in[0]) + int(fades_in[1])) // 2 + 1
        if all(v is not None for v in fades_out):
            high = (int(fades_out[0]) + int(fades_out[1])) // 2
        one.velocity = (max(1, low), min(127, max(low, high)))
    groups = {}
    for one in found:
        riding = [n for n in faded(one.region) if n in DYNAMICS]
        if riding:
            groups.setdefault((one.low, one.high, one.position, one.chance, riding[0]), []).append(one)
    rode = False
    for (_, _, _, _, controller), layers in groups.items():
        if len(layers) < 2:
            continue
        wins = {id(one): [] for one in layers}
        for velocity in range(1, 128):
            best = max(layers, key=lambda one: fade(one.region, controller, velocity))
            wins[id(best)].append(velocity)
        for one in layers:
            if wins[id(one)]:
                one.velocity = (min(wins[id(one)]), max(wins[id(one)]))
            else:
                one.gain = 0.0
        rode = True
    if rode:
        told.append("dynamics on a controller played by velocity")
    return rode


def mixed(stack, folder, name, count):
    """Several recordings on one key as one file, at the balance the pack rests at."""
    rate = load(stack[0].path)[1]
    parts = []
    for one in stack:
        audio, its_rate = load(one.path)
        if its_rate != rate:
            continue
        audio = audio[one.offset:]
        if audio.shape[1] == 1:
            audio = np.repeat(audio, 2, axis=1)
        # The same law a player pans by: equal power, the centre 3 dB under one side alone.
        angle = (one.pan / 100.0 + 1.0) * np.pi / 4.0
        sides = np.array([np.cos(angle), np.sin(angle)]) * np.sqrt(2.0)
        parts.append(audio[:, :2] * sides * one.gain)
    length = max(len(part) for part in parts)
    total = np.zeros((length, 2))
    for part in parts:
        total[:len(part)] += part
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "%s %03d.wav" % (name, count))
    return path, total, rate


def flatten(entry, packs, out):
    source = os.path.join(packs, entry["from"])
    told = []
    found, player, missing = chosen(entry, source)
    if not found:
        return None, "nothing sounds (%d samples missing)" % missing
    rode = by_velocity(found, told)
    top = max(one.gain for one in found)
    if top <= 0:
        return None, "nothing sounds with the controllers at rest"
    found = [one for one in found if one.gain > 0.03 * top]

    # Recordings stacked on a key: alternatives, or microphones to be mixed.
    slots = {}
    for one in found:
        slots.setdefault((one.low, one.high, one.velocity, one.position, one.chance), []).append(one)
    kept, mixes, written = [], [], 0
    folder = os.path.join(out, entry["name"] + " samples")
    how = entry.get("stack", "mix")
    for slot, stack in slots.items():
        if len(stack) == 1 or all(one.same_sound(stack[0]) for one in stack):
            for turn, one in enumerate(stack):
                one.chance = one.chance if len(stack) == 1 else turn / float(len(stack))
            kept += stack
            continue
        first = max(stack, key=lambda one: one.gain)
        if how == "mix":
            written += 1
            path, audio, rate = mixed(stack, folder, entry["name"], written)
            mixes.append((path, audio, rate))
            first.path, first.gain, first.pan, first.offset = path, 1.0, 0.0, 0
        kept.append(first)
    if mixes:
        # One gain for them all, so that the loudest does not clip and the balance between keys stays.
        peak = max(float(np.max(np.abs(audio))) for _, audio, _ in mixes)
        scale = min(1.0, 0.97 / peak) if peak > 0 else 1.0
        for path, audio, rate in mixes:
            write(path, audio * scale, rate)
        told.append("%d keys mixed from %d recordings each" % (len(mixes), max(len(s) for s in slots.values())))
    elif any(len(stack) > 1 and not all(one.same_sound(stack[0]) for one in stack) for stack in slots.values()):
        told.append("the loudest of each stack kept")

    # Key by key: which layers, and which alternatives of each.
    robins, layers_kept = entry.get("robins", 3), entry.get("layers", 5)
    sampled = sorted({key for one in kept for key in range(max(0, one.low), min(127, one.high) + 1)})
    bottom, top_key = sampled[0], sampled[-1]
    covering = {}
    for one in kept:
        for key in range(max(0, one.low), min(127, one.high) + 1):
            covering.setdefault(key, []).append(one)
    low, high = max(0, bottom - entry.get("below", 2)), min(127, top_key + entry.get("above", 2))
    plans, borrowed = {}, 0
    for key in range(low, high + 1):
        here = covering.get(key)
        if not here:
            nearest = min(sampled, key=lambda other: (abs(other - key), other))
            here = covering[nearest]
            borrowed += bottom < key < top_key
        ranges = sorted({one.velocity for one in here})
        if len(ranges) > layers_kept:
            picks = sorted({int(round(i * (len(ranges) - 1) / float(layers_kept - 1))) for i in range(layers_kept)}) \
                if layers_kept > 1 else [len(ranges) - 1]
            ranges = [ranges[i] for i in picks]
        plan, floor = [], 1
        for index, span in enumerate(ranges):
            ceiling = 127 if index == len(ranges) - 1 else min(span[1], ranges[index + 1][0] - 1)
            if ceiling < floor:
                continue
            turns = sorted((one for one in here if one.velocity == span), key=lambda one: (one.position, one.chance, one.order))
            turns = turns[:max(1, robins)]
            plan.append(((floor, ceiling), tuple(id(one) for one in turns)))
            floor = ceiling + 1
        plans[key] = tuple(plan)
    if borrowed:
        told.append("%d keys the pack leaves out played by their neighbours" % borrowed)
    by_id = {id(one): one for one in kept}

    # Keys that play the same recordings, as one range.
    spans, start = [], low
    for key in range(low + 1, high + 2):
        if key > high or plans[key] != plans[start]:
            spans.append((start, key - 1, plans[start]))
            start = key
    shift = entry.get("shift", 0)
    dynamics = rode or any(re.fullmatch(r"amplitude_(?:on)?cc(%s)" % "|".join(map(str, DYNAMICS)), key)
                           for one in kept for key in one.region)
    lines = ["// %s: %s, %s" % (entry["name"], entry["credit"], os.path.basename(entry["from"])), ""]
    used, frames, looped = set(), 0, 0
    for first, last, plan in spans:
        if last + shift < 0 or first + shift > 127:
            continue
        first, last = max(first, -shift), min(last, 127 - shift)
        for (floor, ceiling), turns in plan:
            for turn, identity in enumerate(turns):
                one = by_id[identity]
                region = one.region
                said = ["lokey=%d hikey=%d pitch_keycenter=%d" % (first + shift, last + shift, one.centre + shift),
                        "lovel=%d hivel=%d" % (floor, ceiling)]
                if len(turns) > 1:
                    said.append("seq_length=%d seq_position=%d" % (len(turns), turn + 1))
                level = 20 * np.log10(max(one.gain, 1e-6))
                if abs(level) > 0.05:
                    said.append("volume=%.2f" % level)
                if abs(one.pan) > 0.5:
                    said.append("pan=%.0f" % one.pan)
                if abs(one.tune) >= 1:
                    said.append("tune=%d" % int(round(one.tune)))
                if one.offset:
                    said.append("offset=%d" % one.offset)
                if one.end is not None and one.end > 0:
                    said.append("end=%d" % one.end)
                mode = region.get("loop_mode")
                points = None
                if "loop_start" in region and "loop_end" in region:
                    points = (int(number(region, "loop_start")), int(number(region, "loop_end")))
                elif entry.get("loops", True) and one.path == os.path.normpath(one.path) and mode not in ("no_loop", "one_shot"):
                    points = loop_in(one.path)
                if mode in ("one_shot",):
                    said.append("loop_mode=one_shot")
                elif points and mode != "no_loop" and entry.get("loops", True):
                    said.append("loop_mode=%s loop_start=%d loop_end=%d" % (
                        mode if mode in ("loop_continuous", "loop_sustain") else "loop_continuous", points[0], points[1]))
                    looped += 1
                for stage in ("attack", "hold", "decay", "release"):
                    name = "ampeg_" + stage
                    value = number(region, name) + at_rest(region, name, player)
                    if stage == "release" and "release" in entry:
                        value = entry["release"]
                    if name in region or value > 0:
                        said.append("%s=%.3f" % (name, max(0.0, value)))
                if "ampeg_sustain" in region or at_rest(region, "ampeg_sustain", player):
                    said.append("ampeg_sustain=%.1f" % max(0.0, min(100.0, number(region, "ampeg_sustain", 100)
                                                                   + at_rest(region, "ampeg_sustain", player))))
                tracking = number(region, "amp_veltrack", 100) + at_rest(region, "amp_veltrack", player)
                if dynamics and tracking < 30:
                    tracking = 70
                tracking = entry.get("veltrack", tracking)
                if tracking != 100:
                    said.append("amp_veltrack=%d" % max(0, min(100, int(round(tracking)))))
                lines.append("<region>\nsample=%s\n%s\n" % (os.path.relpath(one.path, out), " ".join(said)))
                if one.path not in used:
                    used.add(one.path)
                    audio, rate = load(one.path)
                    frames += audio.shape[0] * audio.shape[1] * 48000.0 / rate
    open(os.path.join(out, entry["name"] + ".sfz"), "w").write("\n".join(lines))
    layers = max(len(plan) for _, _, plan in spans)
    turns = max(len(t) for _, _, plan in spans for _, t in plan)
    told.insert(0, "%d recordings, %s to %s, %d layer%s, %d round robin%s, %d MB in memory" % (
        len(used), first_name(max(0, low + shift)), first_name(min(127, high + shift)), layers, "" if layers == 1 else "s",
        turns, "" if turns == 1 else "s", frames * 4 // 1048576))
    if looped:
        told.append("%d looped" % looped)
    if missing:
        told.append("%d samples missing or damaged" % missing)
    return os.path.join(out, entry["name"] + ".sfz"), "; ".join(told)


def octave(file):
    """Whether the recordings sound at the keys they are on: "", or what is wrong.

    A bass guitar is written an octave over where it sounds, a glockenspiel two under, and a pack
    mapped as written plays every note in the wrong octave. A note repeats every period of its
    own and every two; one an octave down repeats every two and not every one.
    """
    from check_tour import likeness
    text = open(file).read()
    votes, seen = {"at": 0, "under": 0, "over": 0}, set()
    for region in re.split(r"(?=<region>)", text)[1:]:
        sample = re.search(r"sample=(.+)", region).group(1).strip()
        if sample in seen:
            continue
        seen.add(sample)
        if len(seen) % 5:
            continue
        centre = int(re.search(r"pitch_keycenter=(\d+)", region).group(1))
        tuned = re.search(r"\btune=(-?\d+)", region)
        try:
            audio, rate = load(os.path.join(os.path.dirname(file), sample))
        except Exception:
            continue
        mono = audio.mean(axis=1)
        peak = int(np.argmax(np.abs(mono)))
        piece = mono[peak + int(0.1 * rate): peak + int(0.9 * rate)]
        if len(piece) < rate // 4:
            continue
        key = centre - (int(tuned.group(1)) / 100.0 if tuned else 0.0)
        period = rate / (440.0 * 2 ** ((key - 69) / 12.0))

        def best(lag):
            return max(likeness(piece, lag * 2 ** (cents / 1200.0)) for cents in range(-60, 61, 10))

        half, at, double = best(period / 2), best(period), best(period * 2)
        if at > 0.8 and half > 0.85 * at:
            votes["over"] += 1
        elif at > 0.8:
            votes["at"] += 1
        elif double > 0.8 and at < 0.7:
            votes["under"] += 1
    if votes["under"] > votes["at"] and votes["under"] >= votes["over"]:
        return "SOUNDS AN OCTAVE UNDER ITS KEYS (%d of %d read)" % (votes["under"], sum(votes.values()))
    if votes["over"] > votes["at"]:
        return "SOUNDS AN OCTAVE OVER ITS KEYS (%d of %d read)" % (votes["over"], sum(votes.values()))
    return ""


def first_name(key):
    return "%s%d" % (["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"][key % 12], key // 12 - 1)


def main():
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    manifest, packs, out = arguments[:3]
    only = None
    if "--only" in sys.argv:
        only = {name.strip() for name in sys.argv[sys.argv.index("--only") + 1].split(";")}
    os.makedirs(out, exist_ok=True)
    entries = json.load(open(manifest))
    index = os.path.join(out, "instruments.json")
    listed = json.load(open(index)) if os.path.exists(index) else []
    for entry in entries:
        if only is not None and entry["name"] not in only:
            continue
        file, told = flatten(entry, packs, out)
        print("%-30s %s" % (entry["name"][:30], told))
        if file is None:
            continue
        if entry.get("tune", True):
            from tune_sfz import tune
            found = tune(file, write=True)
            if "corrected" in found:
                print("    tuning: " + found[35:])
        wrong = octave(file)
        if wrong:
            print("    " + wrong)
        listed = [e for e in listed if e["name"] != entry["name"]]
        listed.append({"name": entry["name"], "family": entry["family"], "file": entry["name"] + ".sfz",
                       "credit": entry["credit"], "licence": entry["licence"]})
        json.dump(sorted(listed, key=lambda e: (e["family"], e["name"])), open(index, "w"), indent=1, ensure_ascii=False)
    print("%d listed in %s" % (len(listed), index))


if __name__ == "__main__":
    main()
