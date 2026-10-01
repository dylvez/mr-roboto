"""Mixes a multi-microphone SFZ drum kit down to one stereo recording a hit.

Kits such as Karoryfer's record every hit through several microphones and leave the mix to the
player: each key triggers a region a microphone, levelled and panned by controllers. Mr. Roboto's
sampler plays one zone a hit, so such a kit has to be mixed first. This reads the SFZ as a player
would with its controllers at rest (or where `--cc` puts them), sums what sounds together for
each key, velocity layer and round robin, and writes the result with a plain SFZ in General MIDI
layout beside it, which File > Import Drum Kit reads.

    python bake_sfz_kit.py "<kit>/Programs/Kit.sfz" "<out folder>" --name "Gogodze Phu" \
        [--cc 4=127] [--keys 36,38,42,46] [--move 46:42] [--append --suffix _open --gain-db -1.6]

Honoured: #include and #define, <control> default_path and set_cc, <global> <master> <group>
<region> inheritance, locc/hicc, key and velocity ranges, seq_length and seq_position, amplitude
and volume with their controllers and curves, pan, offset and delay with their controllers and
curves, tune and transpose, and one- and two-pole high- and low-pass filters. Release triggers and
silent muting regions are left out. Needs numpy and scipy.
"""
import argparse
import os
import re
import sys
import subprocess
import tempfile
import wave

import numpy as np
from scipy import signal

HEADERS = ("control", "global", "master", "group", "region", "curve", "effect", "midi", "sample")
LEVELS = ("global", "master", "group", "region")


DIRECTIVE = re.compile(r'#define\s+(\$\w+)\s+(\S+)|#include\s+"([^"]+)"')


def read(path, defines=None, seen=None, root=None):
    """The file as text with its includes in place and its defines applied.

    A directive may stand anywhere, several to a line, and a define holds from where it stands
    until it is made again. An include is looked for beside the file that names it and beside the
    main file: packs do both.
    """
    defines = {} if defines is None else defines
    seen = set() if seen is None else seen
    root = os.path.dirname(path) if root is None else root
    text = open(path, encoding="utf-8", errors="replace").read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\r\n]*", "", text)
    text = re.sub(r"\r\n?", "\n", text)

    def applied(piece):
        for name in sorted(defines, key=len, reverse=True):
            piece = piece.replace(name, defines[name])
        return piece

    out, at = [], 0
    for found in DIRECTIVE.finditer(text):
        out.append(applied(text[at:found.start()]))
        at = found.end()
        if found.group(1):
            defines[found.group(1)] = applied(found.group(2))
            continue
        named = applied(found.group(3)).replace("\\", "/")
        places = [os.path.normpath(os.path.join(folder, named)) for folder in (os.path.dirname(path), root)]
        target = next((place for place in places if os.path.exists(place)), None)
        if target is not None and target not in seen:
            out.append("\n" + read(target, defines, seen | {path}, root) + "\n")
    out.append(applied(text[at:]))
    return "".join(out)


def opcodes(body):
    """Opcodes of one header's body. A path may hold spaces; nothing else does."""
    found = {}
    pattern = re.compile(r"(\w+)=")
    matches = list(pattern.finditer(body))
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        value = body[match.end():end].strip()
        name = match.group(1)
        found[name] = value if name in ("sample", "default_path") else value.split()[0] if value else ""
    return found


def parse(path, defines=None):
    text = read(path, dict(defines or {}))
    pieces = re.split(r"<(%s)>" % "|".join(HEADERS), text)
    control, curves, regions = {}, {}, []
    scope = {level: {} for level in LEVELS}
    for index in range(1, len(pieces), 2):
        kind, found = pieces[index], opcodes(pieces[index + 1])
        if kind == "control":
            control.update(found)
        elif kind == "curve":
            number = int(found.get("curve_index", -1))
            points = sorted((int(key[1:]), float(value)) for key, value in found.items() if re.fullmatch(r"v\d{3}", key))
            if number >= 0 and points:
                curves[number] = points
        elif kind in LEVELS:
            scope[kind] = found
            for lower in LEVELS[LEVELS.index(kind) + 1:]:
                scope[lower] = {}
            if kind == "region":
                merged = {}
                for level in LEVELS:
                    merged.update(scope[level])
                regions.append(merged)
    return control, curves, regions


NOTES = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


def note(value):
    try:
        return int(value)
    except ValueError:
        match = re.fullmatch(r"([a-gA-G])([#b]?)(-?\d+)", value)
        if not match:
            raise ValueError("not a key: %r" % value)
        step = NOTES[match.group(1).lower()] + {"#": 1, "b": -1, "": 0}[match.group(2)]
        return step + 12 * (int(match.group(3)) + 1)


class Player:
    """The controllers, where they rest."""

    def __init__(self, control, curves, overrides):
        self.cc = {}
        for key, value in control.items():
            match = re.fullmatch(r"set_(hd)?cc(\d+)", key)
            if match:
                self.cc[int(match.group(2))] = float(value) * (127.0 if match.group(1) else 1.0)
        self.cc.update(overrides)
        self.curves = curves

    def value(self, number):
        return self.cc.get(number, 0.0)

    def shaped(self, number, curve=None):
        """The controller as 0...1, through a curve when the opcode names one."""
        at = self.value(number)
        if curve is None or curve not in self.curves:
            # The built-in curves: 0 is linear; 1 is bipolar; 2 and 3 are their inverses.
            builtin = {1: lambda x: 2 * x - 1, 2: lambda x: 1 - x, 3: lambda x: 1 - 2 * x}
            return builtin.get(curve, lambda x: x)(at / 127.0)
        points = self.curves[curve]
        return float(np.interp(at, [p[0] for p in points], [p[1] for p in points]))

    def sounds(self, region):
        for key, value in region.items():
            low = re.fullmatch(r"locc(\d+)", key)
            high = re.fullmatch(r"hicc(\d+)", key)
            if low and self.value(int(low.group(1))) < float(value):
                return False
            if high and self.value(int(high.group(1))) > float(value):
                return False
        return True

    def modulated(self, region, name, scale=1.0):
        """The sum of `name`'s controller terms: name_ccN and name_onccN, each through its curve."""
        total = 0.0
        for key, value in region.items():
            match = re.fullmatch(r"%s_(?:on)?cc(\d+)" % name, key)
            if not match:
                continue
            number = int(match.group(1))
            curve = region.get("%s_curvecc%d" % (name, number))
            total += float(value) * scale * self.shaped(number, int(curve) if curve is not None else None)
        return total

    def amplitude(self, region):
        """Linear gain: amplitude and its controllers multiply, volume and its controllers add in dB."""
        gain = float(region.get("amplitude", 100)) / 100.0
        for key, value in region.items():
            match = re.fullmatch(r"amplitude_(?:on)?cc(\d+)", key)
            if match:
                number = int(match.group(1))
                curve = region.get("amplitude_curvecc%d" % number)
                gain *= float(value) / 100.0 * self.shaped(number, int(curve) if curve is not None else None)
        decibels = float(region.get("volume", 0)) + self.modulated(region, "volume") + self.modulated(region, "gain")
        return gain * 10 ** (decibels / 20.0)


def decoded(path):
    """A WAV as the `wave` module reads it; anything else (FLAC, a float WAV) through afconvert."""
    try:
        with wave.open(path, "rb") as file:
            return (file.getframerate(), file.getnchannels(), file.getsampwidth(),
                    file.readframes(file.getnframes()))
    except (wave.Error, EOFError):
        pass
    handle, plain = tempfile.mkstemp(suffix=".wav")
    os.close(handle)
    try:
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI24", path, plain], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with wave.open(plain, "rb") as file:
            return (file.getframerate(), file.getnchannels(), file.getsampwidth(),
                    file.readframes(file.getnframes()))
    finally:
        os.remove(plain)


def load(path, cache={}):
    if path not in cache:
        if len(cache) > 400:  # a pack of thousands of recordings is not held all at once
            cache.clear()
        rate, channels, width, raw = decoded(path)
        if width == 2:
            data = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
        elif width == 3:
            bytes_ = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
            data = (bytes_[:, 0].astype(np.int32) | (bytes_[:, 1].astype(np.int32) << 8)
                    | (bytes_[:, 2].astype(np.int8).astype(np.int32) << 16)).astype(np.float64) / 8388608.0
        else:
            raise ValueError("%s: %d-bit audio is not read" % (path, width * 8))
        cache[path] = (data.reshape(-1, channels), rate)
    return cache[path]


def filtered(audio, rate, region, player):
    kind = region.get("fil_type", "lpf_2p") if "cutoff" in region else None
    if kind is None:
        return audio
    cutoff = float(region["cutoff"]) * 2 ** (player.modulated(region, "cutoff") / 1200.0)
    cutoff = min(max(cutoff, 10.0), rate / 2 - 100)
    order = 1 if kind.endswith("1p") else 2
    shape = "highpass" if kind.startswith("hpf") else "lowpass" if kind.startswith("lpf") else None
    if shape is None:
        return audio
    b, a = signal.butter(order, cutoff, btype=shape, fs=rate)
    return signal.lfilter(b, a, audio, axis=0)


def rendered(region, player, folder, rate_out):
    """One microphone's part in a hit: stereo, placed in time, at its level."""
    path = os.path.normpath(os.path.join(folder, region["sample"].replace("\\", "/")))
    audio, rate = load(path)
    offset = int(round(float(region.get("offset", 0)) + player.modulated(region, "offset")))
    audio = audio[max(0, offset):]
    cents = float(region.get("tune", 0)) + 100 * float(region.get("transpose", 0)) + player.modulated(region, "tune")
    # A few cents is a controller resting beside its centre, not a change of pitch.
    ratio = 2 ** (cents / 1200.0) if abs(cents) > 15 else 1.0
    ratio *= rate / float(rate_out)
    if abs(ratio - 1) > 1e-6 and len(audio) > 1:
        length = max(1, int(len(audio) / ratio))
        at = np.arange(length) * ratio
        audio = np.stack([np.interp(at, np.arange(len(audio)), audio[:, c]) for c in range(audio.shape[1])], axis=1)
    audio = filtered(audio, rate_out, region, player)
    pan = max(-100.0, min(100.0, float(region.get("pan", 0)) + player.modulated(region, "pan")))
    angle = (pan + 100) / 200.0 * np.pi / 2
    left, right = np.cos(angle) * np.sqrt(2), np.sin(angle) * np.sqrt(2)
    if audio.shape[1] == 1:
        stereo = np.concatenate([audio * left, audio * right], axis=1)
    else:
        stereo = np.stack([audio[:, 0] * min(1.0, left), audio[:, 1] * min(1.0, right)], axis=1)
    delay = float(region.get("delay", 0)) + player.modulated(region, "delay")
    if delay > 0:
        stereo = np.concatenate([np.zeros((int(round(delay * rate_out)), 2)), stereo])
    return stereo * player.amplitude(region)


def write(path, audio, rate):
    clipped = np.clip(audio, -1.0, 1.0 - 1.0 / 8388608.0)
    values = np.round(clipped * 8388608.0).astype(np.int32)
    raw = np.empty((values.size, 3), dtype=np.uint8)
    flat = values.reshape(-1)
    raw[:, 0], raw[:, 1], raw[:, 2] = flat & 0xFF, (flat >> 8) & 0xFF, (flat >> 16) & 0xFF
    with wave.open(path, "wb") as file:
        file.setnchannels(2)
        file.setsampwidth(3)
        file.setframerate(rate)
        file.writeframes(raw.tobytes())


def thinned(hits, layers, robins):
    """The hits with no more than `layers` velocity layers a key and `robins` alternatives a layer.

    A kit recorded at thirty-six strengths of snare is thirty-six recordings held in memory for
    one drum; six of them, spread from softest to hardest and widened to meet, play the same part.
    """
    if layers <= 0 and robins <= 0:
        return hits
    by_key = {}
    for (key, low, high, length, position) in hits:
        by_key.setdefault(key, set()).add((low, high))
    out = {}
    for key, spans in by_key.items():
        spans = sorted(spans)
        if 0 < layers < len(spans):
            picks = sorted({int(round(i * (len(spans) - 1) / float(layers - 1))) for i in range(layers)}) if layers > 1 \
                else [len(spans) - 1]
            spans = [spans[i] for i in picks]
        floor = 1
        for index, (low, high) in enumerate(spans):
            ceiling = 127 if index == len(spans) - 1 else high
            turns = sorted((slot for slot in hits if slot[0] == key and slot[1] == low and slot[2] == high), key=lambda s: s[4])
            if robins > 0:
                turns = turns[:robins]
            for turn, slot in enumerate(turns):
                out[(key, floor, ceiling, len(turns), turn + 1)] = hits[slot]
            floor = ceiling + 1
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("sfz")
    parser.add_argument("out")
    parser.add_argument("--name", default=None)
    parser.add_argument("--cc", action="append", default=[], help="a controller put somewhere, as 4=127; may be given more than once")
    parser.add_argument("--keys", default="", help="only these keys, by number, with commas")
    parser.add_argument("--move", action="append", default=[], help="a key written as another, as 46:42")
    parser.add_argument("--rate", type=int, default=44100)
    parser.add_argument("--tail", type=float, default=0.0, help="cut every hit to this many seconds; 0 keeps them whole")
    parser.add_argument("--suffix", default="", help="added to every file name, so two bakes can share a folder")
    parser.add_argument("--append", action="store_true", help="add to the SFZ already in the folder")
    parser.add_argument("--layers", type=int, default=0, help="no more than this many velocity layers a key; 0 keeps them all")
    parser.add_argument("--robins", type=int, default=0, help="no more than this many round robins a hit; 0 keeps them all")
    parser.add_argument("--gain-db", type=float, default=None,
                        help="the kit's gain, as an earlier bake printed it, so a second bake sits at the first one's level")
    arguments = parser.parse_args()

    control, curves, regions = parse(arguments.sfz)
    overrides = {int(k): float(v) for k, v in (pair.split("=") for pair in arguments.cc)}
    player = Player(control, curves, overrides)
    folder = os.path.join(os.path.dirname(arguments.sfz), control.get("default_path", "").replace("\\", "/"))
    wanted = {int(k) for k in arguments.keys.split(",") if k}
    moved = {int(a): int(b) for a, b in (pair.split(":") for pair in arguments.move)}
    name = arguments.name or os.path.splitext(os.path.basename(arguments.sfz))[0]

    hits = {}
    left_out = {"silent": 0, "release": 0, "controller": 0, "missing": 0}
    for region in regions:
        sample = region.get("sample", "")
        if not sample or sample.startswith("*"):
            left_out["silent"] += 1
            continue
        if region.get("trigger", "attack") != "attack":
            left_out["release"] += 1
            continue
        if not player.sounds(region):
            left_out["controller"] += 1
            continue
        if not os.path.exists(os.path.normpath(os.path.join(folder, sample.replace("\\", "/")))):
            left_out["missing"] += 1
            continue
        low = note(region.get("lokey", region.get("key", "0")))
        high = note(region.get("hikey", region.get("key", "127")))
        length = int(region.get("seq_length", 1))
        position = int(region.get("seq_position", 1))
        for key in range(low, high + 1):
            if wanted and key not in wanted:
                continue
            slot = (key, int(region.get("lovel", 1)), int(region.get("hivel", 127)), length, position)
            hits.setdefault(slot, []).append(region)

    hits = thinned(hits, arguments.layers, arguments.robins)
    os.makedirs(os.path.join(arguments.out, "samples"), exist_ok=True)
    mixed = {}
    for slot, layers in sorted(hits.items()):
        parts = [rendered(layer, player, folder, arguments.rate) for layer in layers]
        total = np.zeros((max(len(part) for part in parts), 2))
        for part in parts:
            total[:len(part)] += part
        if arguments.tail > 0:
            frames = int(arguments.tail * arguments.rate)
            if len(total) > frames:
                total = total[:frames]
                fade = min(frames, int(0.02 * arguments.rate))
                total[-fade:] *= np.linspace(1, 0, fade)[:, None]
        mixed[slot] = total
    if not mixed:
        sys.exit("nothing sounds: no region is played with the controllers where they are")
    # One gain for the whole kit, so a soft hit stays softer than a hard one and a hat than a kick.
    peak = max(float(np.max(np.abs(audio))) for audio in mixed.values())
    gain = 10 ** (-1 / 20.0) / peak if peak > 0 else 1.0
    if arguments.gain_db is not None:
        gain = min(10 ** (arguments.gain_db / 20.0), 1.0 / peak if peak > 0 else 1.0)

    lines = []
    for (key, low, high, length, position), audio in sorted(mixed.items()):
        written = moved.get(key, key)
        file = "k%03d_v%03d_rr%d%s.wav" % (written, high, position, arguments.suffix)
        write(os.path.join(arguments.out, "samples", file), audio * gain, arguments.rate)
        lines.append("<region> sample=samples/%s key=%d lovel=%d hivel=%d seq_length=%d seq_position=%d"
                     % (file, written, max(1, low), high, length, position))
    target = os.path.join(arguments.out, "%s.sfz" % name)
    header = ["// %s, mixed down from %s" % (name, os.path.basename(arguments.sfz)),
              "// by Bench/kits/bake_sfz_kit.py" + ("".join(" --cc %s" % pair for pair in arguments.cc)),
              "<control>", "<global> loop_mode=one_shot", ""]
    existing = open(target).read().rstrip("\n").split("\n") if arguments.append and os.path.exists(target) else header
    open(target, "w").write("\n".join(existing + lines) + "\n")
    keys = sorted({moved.get(slot[0], slot[0]) for slot in mixed})
    print("%s: %d hits on keys %s, from %d regions; left out: %s; kit gain %+.1f dB"
          % (name, len(mixed), ",".join(map(str, keys)), sum(len(v) for v in hits.values()), left_out, 20 * np.log10(gain)))


if __name__ == "__main__":
    main()
