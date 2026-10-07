"""Copies researched genre profiles (a directory of <id>.json written to BRIEF.md) into the app, with the fixes the app's method needs.

- Ranges on features that are the same in every genre (machine limits, sample cutting, process)
  are dropped: GenreLens never moves them, and GenreMethod refuses them.
- Notes filed under an area the app does not have are refiled.
- Feels a profile should claim but the research did not list are added (the app's own library is
  not something the researchers could see).
"""
import json, glob, os, sys
SRC = sys.argv[1]
DST = sys.argv[2]
STYLE = ("tempo.", "swing.", "pocket.", "ghost.", "humanize.", "form.", "harmony.", "melody.", "lyric.", "bass.")
MIX = {"mix.lufs.integrated", "mix.crest.db", "mix.tilt.db", "mix.bandwidth.hz", "mix.lowend.separation.db", "mix.master.target.lufs"}
AREAS = {"groove", "form", "harmony", "bass", "arrangement", "sound", "mix", "melody", "lyrics"}
REFILE = {"tempo": "groove", "rhythm": "groove", "drums": "groove", "production": "sound", "instrumentation": "sound", "structure": "form", "vocals": "lyrics"}
# Feels a profile listed that do not belong to it in this app: Bossa Nova is straight eighths,
# and judged by jazz's swing it would be called wrong for being bossa nova.
DROP_FEELS = {"jazz": ["Bossa Nova"]}
# Ranges that measure something other than what the app's feature measures. Blues' harmonic rhythm
# was counted as chord *changes* per bar (0.5-0.75); the app counts chords a bar carries, which is
# 1 for a twelve-bar blues written a chord a bar.
DROP_RANGES = {"blues": ["harmony.changes.per.bar"]}
EXTRA_FEELS = {
    "salsa": ["Cha-Cha-Chá", "Rumba Clave", "Afro-Cuban 6/8"],
    # Written once the kits had a güiro and a cajón to play them on.
    "cumbia": ["Cumbia"],
    "folk": ["Cajón Groove"],
}
def judged(f): return (f.startswith(STYLE) and not f.startswith("form.album.")) or f in MIX
for path in sorted(glob.glob(SRC + "/*.json")):
    p = json.load(open(path))
    dropped = [r["feature"] for r in p.get("ranges", []) if not judged(r["feature"])]
    p["ranges"] = [r for r in p.get("ranges", []) if judged(r["feature"])]
    for n in p.get("notes", []):
        if n["area"] not in AREAS: n["area"] = REFILE.get(n["area"], "arrangement")
    p["feels"] = [f for f in p["feels"] if f not in DROP_FEELS.get(p["id"], [])]
    p["ranges"] = [r for r in p["ranges"] if r["feature"] not in DROP_RANGES.get(p["id"], [])]
    for f in EXTRA_FEELS.get(p["id"], []):
        if f not in p["feels"]: p["feels"].append(f)
    with open(os.path.join(DST, p["id"] + ".json"), "w") as out:
        json.dump(p, out, indent=2, sort_keys=True, ensure_ascii=False); out.write("\n")
    if dropped: print(p["id"], "dropped", dropped)
