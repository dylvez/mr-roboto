"""Genre blind sheets: canonical material, read in its own genre, should hold on that genre's style.

For each genre profile, the material the genre is known by — its feels, its bass hands under its
first feel, its typical form, its progressions — is read by the persona that owns it, through the
genre's lens. The sheet expects every reading on a rule whose feature the genre ranges to hold.
The expectation comes from the profile's research (canonical material is what the genre is), not
from what the persona says; a miss means the feel library, the writer, or the profile disagrees
with the genre, and is worth reading.
"""
import json, glob, sys, os
ROOT = sys.argv[1]
bibles = {json.load(open(f))["id"]: json.load(open(f)) for f in glob.glob(ROOT + "/Sources/MrRobotoApp/Resources/Bibles/*.json")}
profiles = [json.load(open(f)) for f in sorted(glob.glob(ROOT + "/Sources/MrRobotoApp/Resources/Genres/*.json"))]
STYLE = ("tempo.", "swing.", "pocket.", "ghost.", "humanize.", "form.", "harmony.", "melody.", "lyric.", "bass.")
def rules(persona, ranged):
    out = []
    for r in bibles[persona]["rules"]:
        t = r.get("threshold")
        if t and r.get("firesWhen", "thresholdFails") == "thresholdFails" and t["feature"] in ranged and t["feature"].startswith(STYLE) and t["comparison"] in ("atMost", "atLeast", "between"):
            out.append(r["id"])
    return out
sheets = {p: [] for p in ("beatmaker", "bassist", "peer", "harmonist")}
for g in profiles:
    ranged = {r["feature"] for r in g["ranges"]}
    typical = next((r.get("typical") or (r["low"] + r["high"]) / 2 for r in g["ranges"] if r["feature"] == "tempo.bpm"), 100)
    bm = rules("beatmaker", ranged)
    for feel in g["feels"][:2]:
        if bm: sheets["beatmaker"].append({"id": f"{g['id']}-{feel}", "label": f"{feel} as {g['name']}", "genre": g["id"],
                                           "material": {"kind": "feel", "name": feel}, "expects": {r: True for r in bm}})
    # The swing a programmed line sits on is judged on a proposal; the Bassist never reads it off a line.
    bs = [r for r in rules("bassist", ranged) if r != "bassist.swing-when-programmed"]
    if g["bassHands"] and g["feels"] and bs:
        hands = g["bassHands"][0]
        sheets["bassist"].append({"id": f"{g['id']}-{hands}", "label": f"{hands} under {g['feels'][0]} as {g['name']}", "genre": g["id"],
                                  "material": {"kind": "bassline", "hands": hands, "lagMS": 40 if hands == "palladino" else 0,
                                               "tempo": typical, "feel": g["feels"][0], "density": 0.5, "seed": 7},
                                  "expects": {r: True for r in bs}})
    # What the Peer reads off a finished form (Peer.read(FormObservation)) that an outline of names
    # and bar counts can show: the hook's arrival, the turns, the repeats. A lift needs the layers,
    # which an outline does not have; the rules for unfinished and short forms are judged on
    # proposals and never read off a form.
    pr = [r for r in rules("peer", ranged) if r in ("peer.hook-inside-thirty", "peer.form-turns", "peer.repetition")]
    form = g.get("form")
    if form and pr:
        # As the Peer hears a hook (FormObservation.isHook): a pre- or post-chorus is not one.
        names = [s["name"].lower() for s in form["sections"]]
        hooks = ("hook", "chorus", "refrain", "drop", "head", "coro", "refrão", "refrao")
        if not any(h in n for n in names if not n.startswith(("pre", "post")) for h in hooks):
            pr = [r for r in pr if r != "peer.hook-inside-thirty"]
        if pr: sheets["peer"].append({"id": f"{g['id']}-form", "label": f"{g['name']} form", "genre": g["id"],
                                      "material": {"kind": "form", "tempo": typical, "sections": form["sections"]},
                                      "expects": {r: True for r in pr}})
    # A profile's progression is a fragment, a chord a bar: how many chords, how fast they change,
    # how the roots move and how phrases land are properties of whole songs, so only what a fragment
    # can show is expected of it — whether it stays in its own mode.
    hr = [r for r in rules("harmonist", ranged) if r in ("harmonist.stays-in-key", "harmonist.voice-leading")]
    for i, prog in enumerate(g["progressions"]):
        if not hr: break
        mode = (prog.get("mode") or "").lower()
        minor = mode in ("aeolian", "dorian", "phrygian", "harmonic minor", "melodic minor", "minor")
        # A church mode, or a scale the key parser knows by name (ScaleColour): read in that, so a
        # freygish cadence is in phrygian dominant rather than in C major.
        colours = ("harmonic minor", "melodic minor", "phrygian dominant", "double harmonic", "hungarian minor", "ukrainian dorian")
        named = mode if mode in ("ionian", "dorian", "phrygian", "lydian", "mixolydian", "aeolian", "locrian") + colours else ("minor" if minor else "major")
        sheets["harmonist"].append({"id": f"{g['id']}-prog{i+1}", "label": f"{prog['roman']} as {g['name']}", "genre": g["id"],
                                    "material": {"kind": "numerals", "roman": prog["roman"], "mode": prog.get("mode"), "key": ("A " if minor else "C ") + named},
                                    "expects": {r: True for r in hr}})
SILENT = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "silent.json"))) if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "silent.json")) else {}
FINDINGS = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "findings.json"))) if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "findings.json")) else {}
for persona, items in sheets.items():
    for item in items:
        for rule in SILENT.get(item["id"], []): item["expects"].pop(rule, None)
        for rule, note in FINDINGS.get(item["id"], {}).items():
            if rule in item["expects"]:
                item["expects"][rule] = False
                item.setdefault("notes", {})[rule] = note
    items[:] = [i for i in items if i["expects"]]
    path = os.path.join(ROOT, "Bench/personas/blind", f"genre-{persona}.json")
    json.dump({"persona": persona, "items": items}, open(path, "w"), indent=1, ensure_ascii=False)
    print(persona, len(items))
