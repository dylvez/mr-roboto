"""Merges the second research pass into the shipped genre profiles.

- `loudness.json`: integrated loudness and crest factor per genre, from web research (see
  `loudness-notes.md` for what could not be filled and why).
- `melody_ranges.json`: the Melodist's features measured on Lakh MIDI melodies by tagtraum genre
  (`melody_ranges.py`), mapped onto the profiles below.

A range the profile already states is kept — except crest for pop, rock and trap, whose first-pass
numbers came from a general remark ("5 dB or less") and sit below what those masters measure on the
app's own peak-to-RMS; they are replaced by the fitted relation the loudness pass derived from
lufs.to's per-track data, applied over each genre's measured loudness.

    python3 Bench/genres/merge_ranges.py Sources/MrRobotoApp/Resources/Genres

A feature named after `--again` is measured again rather than kept: what the Melodist counts as a
figure coming back changed on 2026-09-29 (rhythm and shape, everything covered, where it had been
the longest run of intervals), and every range stated on the old measure was restated on the new.

    python3 Bench/genres/merge_ranges.py Sources/MrRobotoApp/Resources/Genres --again melody.motif.ratio
"""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
DST = sys.argv[1]
AGAIN = set(sys.argv[sys.argv.index("--again") + 1:]) if "--again" in sys.argv else set()
LAKH = "https://colinraffel.com/projects/lmd/"
TAGTRAUM = "https://www.tagtraum.com/msd_genre_datasets.html"

# Which tagtraum label measures which profile, and what that mapping gives up.
MELODY = {
    "rock": ("Rock", None),
    "pop": ("Pop", None),
    "country": ("Country", None),
    "jazz": ("Jazz", "the MIDI files are mostly vocal standards, so this is the tune, not the improvised solo"),
    "synth-pop": ("Electronic", "the Million Song Dataset's Electronic label, measured only where a MIDI file has a melody or vocal track, which is mostly vocal dance-pop and synth-pop"),
    "soul": ("RnB", "the dataset's RnB label, which spans soul, Motown, funk and contemporary R&B"),
    "neo-soul": ("RnB", "the dataset's RnB label, which spans soul, Motown, funk and contemporary R&B"),
    "funk": ("RnB", "the dataset's RnB label, which spans soul, Motown, funk and contemporary R&B"),
    "disco": ("RnB", "the dataset's RnB label; disco's vocal lines are filed there and under Pop"),
    "salsa": ("Latin", "the dataset's Latin label, which is mostly Latin pop; no salsa-only corpus of melodies was found"),
    "cumbia": ("Latin", "the dataset's Latin label, which is mostly Latin pop; no cumbia-only corpus of melodies was found"),
}
UNITS = {
    "melody.range.semitones": ("semitones", 0), "melody.leap.max.semitones": ("semitones", 0),
    "melody.stepwise.ratio": ("fraction of moves", 2), "melody.notes.per.bar": ("notes per bar", 1),
    "melody.rest.ratio": ("fraction of the tune", 2), "melody.peak.count": ("strikes of the top note", 0),
    "melody.motif.ratio": ("fraction of the tune", 2),
}

def fitted_crest(lufs_range, genre):
    lo, hi = lufs_range["low"], lufs_range["high"]
    c = lambda l: round(5.28 - 0.743 * l, 1)
    return {"feature": "mix.crest.db", "low": c(hi), "high": c(lo), "unit": "dB",
            "evidence": {"inferred": f"crest = 5.28 - 0.743 x integrated LUFS, the relation fitted across about 2,500 tracks' peak-minus-RMS on lufs.to (the app's own crest measure), applied over {genre}'s measured {lo} to {hi} LUFS; replaces a first-pass range taken from a general remark"}}

loudness = json.load(open(os.path.join(HERE, "loudness.json")))
melody = json.load(open(os.path.join(HERE, "melody_ranges.json")))
for name in sorted(os.listdir(DST)):
    if not name.endswith(".json"): continue
    path = os.path.join(DST, name)
    p = json.load(open(path))
    have = {r["feature"] for r in p["ranges"]}
    added = []
    for r in loudness.get(p["id"], []):
        if r["feature"] not in have:
            p["ranges"].append(r); added.append(r["feature"])
    if p["id"] in ("pop", "rock", "trap"):
        lufs = next(r for r in p["ranges"] if r["feature"] == "mix.lufs.integrated")
        p["ranges"] = [r for r in p["ranges"] if r["feature"] != "mix.crest.db"] + [fitted_crest(lufs, p["name"])]
        added.append("mix.crest.db (replaced)")
    if p["id"] in MELODY:
        label, caveat = MELODY[p["id"]]
        m = melody[label]
        for feature, stats in sorted(m["features"].items()):
            if feature in have and feature not in AGAIN: continue
            if feature in have:
                p["ranges"] = [x for x in p["ranges"] if x["feature"] != feature]
            unit, places = UNITS[feature]
            r = lambda x: round(x, places) if places else int(round(x))
            p["ranges"].append({"feature": feature, "low": r(stats["low"]), "high": r(stats["high"]),
                                "typical": r(stats["typical"]), "unit": unit, "evidence": {"cited": [LAKH, TAGTRAUM]}})
            added.append(feature)
        text = (f"Melody ranges are measured, not recalled: {m['windows']} eight-bar windows from the melody tracks of "
                f"{m['songs']} Lakh MIDI files labelled {label} by tagtraum, each read with the app's own Melodist "
                f"arithmetic; the range is the 10th to 90th percentile, typical the median. Performed MIDI, so note "
                f"lengths are as played. The share of chord tones is not measured: the files carry no chords.")
        if caveat: text += f" The label is {caveat}."
        p["notes"] = [n for n in p["notes"] if not n["text"].startswith("Melody ranges are measured")]
        p["notes"].append({"area": "melody", "text": text,
                           "evidence": {"inferred": f"computed by Bench/genres/melody_ranges.py over {LAKH} and {TAGTRAUM}"}})
    with open(path, "w") as out:
        json.dump(p, out, indent=2, sort_keys=True, ensure_ascii=False); out.write("\n")
    if added: print(p["id"], added)
