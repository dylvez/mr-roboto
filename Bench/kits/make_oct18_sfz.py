"""Writes the plain SFZs the app imports from the four packs fetched on 2026-10-18.
Usage: make_sfz.py <Mr Roboto SFZ root>  (reads Packs/, writes into Mr Roboto/)"""
import json, os, re, struct, sys

root = sys.argv[1]
packs = os.path.join(root, "Packs")
out = os.path.join(root, "Mr Roboto")
NAMES = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}

def midi(note):
    m = re.fullmatch(r"([a-g])(#|b)?(-?\d)", note.lower())
    if not m: raise ValueError(note)
    n = NAMES[m.group(1)] + {"#": 1, "b": -1, None: 0}[m.group(2)]
    return 12 * (int(m.group(3)) + 1) + n

def smpl_loop(path):
    b = open(path, "rb").read()
    i = 12
    while i + 8 <= len(b):
        cid, size = b[i:i+4], struct.unpack("<I", b[i+4:i+8])[0]
        if cid == b"smpl" and size >= 36:
            n = struct.unpack("<I", b[i+8+28:i+8+32])[0]
            if n:
                loop = struct.unpack("<6I", b[i+8+36:i+8+60])
                return loop[2], loop[3]
        i += 8 + size + (size & 1)
    return None

# 1. The choir: Sonatina's mixed chorus (looped), as its own mapping has it, forward slashes.
sso = os.path.join(packs, "peastman.sso", "Sonatina Symphonic Orchestra")
src = open(os.path.join(sso, "Chorus - Notation", "Mixed Chorus.sfz"), encoding="utf-8", errors="replace").read()
src = src.replace("\\", "/").replace("../Samples-looped/", "../Packs/peastman.sso/Sonatina Symphonic Orchestra/Samples-looped/")
body = src[src.index("<group>"):]
choir = ("// Choir: Sonatina Symphonic Orchestra 4.0's mixed chorus, looped by Signal Experiments,\n"
         "// from SSO 1.0 by Mattias Westlund. Creative Commons Sampling Plus 1.0. Personal use.\n"
         "// Women G4–C6 over men G2–F#4, one vowel, one layer.\n\n" + body)
open(os.path.join(out, "Choir.sfz"), "w", encoding="utf-8").write(choir)

# 2. The transistor organ: the Unitra B-11's stops, a sample a note with its own loop.
organ = os.path.join(packs, "karoryfer.caveman-cosmonaut", "Samples")
for stop, name in [("all_all_all", "Transistor Organ"), ("flutes", "Transistor Organ, Flutes"),
                   ("tremolo", "Transistor Organ, Tremolo"), ("violin", "Transistor Organ, Violin")]:
    files = sorted((midi(f[len(stop) + 1:-4]), f) for f in os.listdir(organ) if f.startswith(stop + "_") and f.endswith(".wav"))
    lines = [f"// {name}: the Unitra B-11 transistor organ's '{stop.replace('_all_all', '')}' stop(s), from Karoryfer's",
             "// Caveman Cosmonaut. CC0.", "", "<group>", "loop_mode=loop_continuous", "ampeg_attack=0.004", "ampeg_release=0.06", ""]
    lowest = files[0][0]
    for index, (key, f) in enumerate(files):
        lo = lowest - 7 if index == 0 else key   # the lowest sample carried down a fifth
        loop = smpl_loop(os.path.join(organ, f))
        lines += ["<region>", f"sample=../Packs/karoryfer.caveman-cosmonaut/Samples/{f}", f"lokey={lo}", f"hikey={key}",
                  f"pitch_keycenter={key}"]
        if loop: lines += [f"loop_start={loop[0]}", f"loop_end={loop[1]}"]
        lines.append("")
    open(os.path.join(out, name + ".sfz"), "w", encoding="utf-8").write("\n".join(lines))

# 3. Hand percussion: timbales and cuíca from the GM Bank's standard kit, palmas from body_percussion.
hp = os.path.join(out, "Hand Percussion")
os.makedirs(hp, exist_ok=True)
kit = open(os.path.join(packs, "discord-gm-bank", "001-Standard Kit.sfz"), encoding="utf-8").read()
kept = []
for group in re.split(r"(?=<group>)", kit):
    m = re.search(r"^key=(\d+)", group, re.M)
    if m and int(m.group(1)) in (65, 66, 78, 79):
        kept.append(re.split(r"\n//", group)[0].replace("001-Standard Kit/", "../../Packs/discord-gm-bank/001-Standard Kit/").strip())
open(os.path.join(hp, "Timbales and Cuica.sfz"), "w", encoding="utf-8").write(
    "// Timbales (Orange Tree Samples, freeware) and cuíca (Seidhepriest, CC BY-NC 4.0), from the\n"
    "// Discord SFZ GM Bank's standard kit. Personal use.\n\n" + "\n\n".join(kept) + "\n")
body_dir = os.path.join(packs, "sfzinstruments.body_percussion", "Samples", "body")
lines = ["// Palmas: body_percussion's finger claps (the sharp palmas claras) on 60 and hand claps on 62.",
         "// CC0. Two layers, round robins.", ""]
for key, sound in [(60, "fingerclap"), (62, "handclap")]:
    for layer, (lo, hi) in [("vl1", (1, 63)), ("vl2", (64, 127))]:
        takes = sorted(f for f in os.listdir(body_dir) if f.startswith(f"{sound}_{layer}_rr"))
        lines += ["<group>", f"key={key}", f"lovel={lo}", f"hivel={hi}", "loop_mode=one_shot", ""]
        for k, f in enumerate(takes):
            lines += ["<region>", f"sample=../../Packs/sfzinstruments.body_percussion/Samples/body/{f}",
                      f"lorand={k / len(takes):.4f}", f"hirand={(k + 1) / len(takes):.4f}", ""]
open(os.path.join(hp, "Palmas.sfz"), "w", encoding="utf-8").write("\n".join(lines))
manifest = {"name": "GM Bank and body_percussion", "entries": [
    {"kind": "timbaleHigh", "file": "Timbales and Cuica.sfz", "note": 65, "label": "OTS timbales, high head"},
    {"kind": "timbaleLow", "file": "Timbales and Cuica.sfz", "note": 66, "label": "OTS timbales, low head"},
    {"kind": "cuicaMute", "file": "Timbales and Cuica.sfz", "note": 78, "label": "Seidhepriest cuíca, muted"},
    {"kind": "cuicaOpen", "file": "Timbales and Cuica.sfz", "note": 79, "label": "Seidhepriest cuíca, open"},
    {"kind": "palmas", "file": "Palmas.sfz", "note": 60, "label": "body_percussion finger claps, palmas claras"},
]}
json.dump(manifest, open(os.path.join(hp, "percussion.json"), "w", encoding="utf-8"), indent=2, ensure_ascii=False)

# 4. The instruments list the import reads.
listing = os.path.join(out, "instruments.json")
entries = json.load(open(listing, encoding="utf-8"))
new = [{"name": "Choir", "family": "pad", "file": "Choir.sfz", "credit": "Sonatina Symphonic Orchestra 4.0, Mixed Chorus", "licence": "CC Sampling Plus 1.0"}]
for name in ["Transistor Organ", "Transistor Organ, Flutes", "Transistor Organ, Tremolo", "Transistor Organ, Violin"]:
    new.append({"name": name, "family": "organ", "file": name + ".sfz", "credit": "Karoryfer Samples, Caveman Cosmonaut", "licence": "CC0"})
names = {e["name"] for e in entries}
entries += [e for e in new if e["name"] not in names]
json.dump(entries, open(listing, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("wrote", len(new), "instruments and the hand percussion folder;", len(kept), "GM groups")
