"""Genre melody ranges, measured the way the app's Melodist measures a tune.

The Melodist reads a written tune (`MelodyObservation`, Sources/MrRobotoApp/Personas/MelodyObservation.swift):
its range, its largest leap, the share of moves that are steps, notes a bar, the share that is rest,
how many times the top note is struck, and how much of it is a figure that comes back. No survey
publishes those numbers by genre, so this measures them on melodies that exist: the melody tracks
of the Lakh MIDI "matched" set (Raffel 2016), labelled by the tagtraum CD2 genre annotations of the
Million Song Dataset (Schreiber 2015).

A tune in the app is a section long, so each melody is cut into eight-bar windows on its bar lines,
and each window is measured as the app would measure a part that long. A genre's range runs from
the 10th to the 90th percentile of its windows — the band a rule's line can sit on without calling
one phrase in five of the genre's own melodies wrong — and its typical value is the median. No song contributes more than six windows, so a long MIDI file does
not outvote a short one.

The chord-tone share is not measured: Lakh carries no chords, and guessing them from the other
tracks would be a guess.

    python3 melody_ranges.py <lmd_matched dir> <msd_tagtraum_cd2.cls> > melody_ranges.json
"""
import json, os, re, sys, random
from collections import defaultdict
import mido
import numpy as np

LMD, LABELS = sys.argv[1], sys.argv[2]
WINDOW_BARS, MIN_NOTES, MAX_WINDOWS = 8, 12, 6
NAME = re.compile(r"melod|vocal|voice|vox|sing|lead\s*vox|lead\s*voc", re.I)
LEAD = re.compile(r"\blead\b", re.I)

def genres():
    out = {}
    for line in open(LABELS):
        if line.startswith("#"): continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2: out[parts[0]] = parts[1]
    return out

def tracks(path):
    """Each track's notes as (onset beats, duration beats, pitch), with its name, its channel set,
    the ticks per beat, and the first time signature."""
    mid = mido.MidiFile(path)
    tpb = mid.ticks_per_beat or 480
    signature = None
    out = []
    for track in mid.tracks:
        name, tick, active, notes, channels = track.name or "", 0, {}, [], set()
        for msg in track:
            tick += msg.time
            if msg.type == "time_signature" and signature is None: signature = (msg.numerator, msg.denominator)
            if msg.type == "track_name" and not name: name = msg.name
            if msg.type == "note_on" and msg.velocity > 0:
                channels.add(msg.channel)
                active.setdefault((msg.channel, msg.note), []).append(tick)
            elif msg.type in ("note_off", "note_on"):
                starts = active.get((msg.channel, msg.note))
                if starts:
                    start = starts.pop(0)
                    notes.append((start / tpb, max(1, tick - start) / tpb, msg.note))
        if notes: out.append((name, channels, sorted(notes)))
    return out, signature or (4, 4)

def melody(track_list):
    """The melody track: named as one (a lead only when nothing is named melody or vocal), not the
    drums, mostly one note at a time, in a voice's register, with enough notes to be a tune."""
    best = None
    for name, channels, notes in track_list:
        if 9 in channels or len(notes) < 64: continue
        named = 2 if NAME.search(name) else (1 if LEAD.search(name) else 0)
        if not named: continue
        onsets = [n[0] for n in notes]
        chords = sum(1 for a, b in zip(onsets, onsets[1:]) if abs(a - b) < 1e-3)
        if chords / len(notes) > 0.15: continue
        median = float(np.median([n[2] for n in notes]))
        if not 55 <= median <= 79: continue
        score = (named, len(notes))
        if best is None or score > best[0]: best = (score, notes)
    return best[1] if best else None

def skyline(notes):
    """One note at a time: at a shared onset the highest, and a note cut where the next begins."""
    by_onset = {}
    for start, duration, pitch in notes:
        key = round(start, 3)
        if key not in by_onset or pitch > by_onset[key][2]: by_onset[key] = (start, duration, pitch)
    line = sorted(by_onset.values())
    return [(s, min(d, line[i + 1][0] - s) if i + 1 < len(line) else d, p) for i, (s, d, p) in enumerate(line)]

SHORTEST_FIGURE = 3

def motif_ratio(notes):
    """MelodyObservation.motifRatio: the share of the tune's moves that lie in a figure heard twice.
    A move is which way the tune goes to the next note and how long until it, to the sixteenth; a
    figure is three moves or more — four notes — that come again later, in the same rhythm and the
    same shape, at any pitch."""
    direction = lambda d: (d > 0) - (d < 0)
    moves = [(direction(b[2] - a[2]), round((b[0] - a[0]) * 4) / 4) for a, b in zip(notes, notes[1:])]
    n = len(moves)
    if n < 4: return 0.0
    covered = [False] * n
    for a in range(n - SHORTEST_FIGURE + 1):
        for b in range(a + SHORTEST_FIGURE, n - SHORTEST_FIGURE + 1):
            length = 0
            while b + length < n and a + length < b and moves[a + length] == moves[b + length]: length += 1
            if length >= SHORTEST_FIGURE:
                for i in range(length): covered[a + i] = covered[b + i] = True
    return sum(covered) / n

def measure(notes, beats_per_bar):
    """MelodyObservation's arithmetic on one window, notes relative to its start."""
    pitches = [p for _, _, p in notes]
    intervals = [b - a for a, b in zip(pitches, pitches[1:])]
    length = max(s + d for s, d, _ in notes)
    sounding, covered = 0.0, -1.0
    for s, d, _ in notes:
        start, end = max(s, covered), s + d
        if end > start: sounding += end - start
        covered = max(covered, end)
    motif = motif_ratio(notes)
    top = max(pitches)
    return {
        "melody.range.semitones": max(pitches) - min(pitches),
        "melody.leap.max.semitones": max((abs(i) for i in intervals), default=0),
        "melody.stepwise.ratio": sum(1 for i in intervals if abs(i) <= 2) / len(intervals) if intervals else 1,
        "melody.notes.per.bar": len(notes) / (length / beats_per_bar) if length > 0 else 0,
        "melody.rest.ratio": max(0.0, min(1.0, 1 - sounding / length)) if length > 0 else 0,
        "melody.peak.count": pitches.count(top),
        "melody.motif.ratio": motif,
    }

def windows(notes, beats_per_bar):
    span = WINDOW_BARS * beats_per_bar
    out = []
    end = max(s + d for s, d, _ in notes)
    start = 0.0
    while start < end:
        inside = [(s - start, min(d, start + span - s), p) for s, d, p in notes if start <= s < start + span]
        if len(inside) >= MIN_NOTES: out.append(inside)
        start += span
    return out

def main():
    labels = genres()
    rng = random.Random(7)
    per_genre = defaultdict(list)
    songs = defaultdict(int)
    for root, _, files in os.walk(LMD):
        mids = sorted(f for f in files if f.endswith(".mid"))
        if not mids: continue
        track_id = os.path.basename(root)
        genre = labels.get(track_id)
        if not genre: continue
        try:
            listed, (numerator, denominator) = tracks(os.path.join(root, mids[0]))
        except Exception:
            continue
        if denominator != 4 or numerator not in (3, 4): continue
        notes = melody(listed)
        if not notes: continue
        found = windows(skyline(notes), numerator)
        if not found: continue
        songs[genre] += 1
        for window in rng.sample(found, min(MAX_WINDOWS, len(found))):
            per_genre[genre].append(measure(window, numerator))
    out = {}
    for genre, rows in per_genre.items():
        out[genre] = {"songs": songs[genre], "windows": len(rows), "features": {}}
        for feature in rows[0]:
            values = np.array([r[feature] for r in rows], dtype=float)
            q1, med, q3 = np.percentile(values, [10, 50, 90])
            out[genre]["features"][feature] = {"low": float(q1), "typical": float(med), "high": float(q3)}
    json.dump(out, sys.stdout, indent=1, sort_keys=True)

if __name__ == "__main__":
    main()
