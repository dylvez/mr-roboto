"""Reads a kit tour: how loud each drum of a recorded kit is, alone, beside the machine it was levelled to.

    python check_kits.py <tour folder> [--mp3 file]

The tour (`zzKitTour`) plays every kit the same four bars at 100 to the minute: a drum a beat for
three bars, then a beat. A recorded kit is levelled drum by drum to the machine it is built on, so
each of its drums should stand about where the machine's does; one that is silent, or far from
the machine's, is said.
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bake_sfz_kit import load  # noqa: E402


def db(value):
    return 20 * np.log10(max(value, 1e-9))


def main():
    folder = sys.argv[1]
    tour = json.load(open(os.path.join(folder, "kits.json")))
    step = 60.0 / 100 / 4
    levels = {}
    for entry in tour:
        audio, rate = load(os.path.join(folder, entry["file"]))
        mono = audio.mean(axis=1)
        found = {}
        for hit in entry["alone"]:
            start = int(hit["step"] * step * rate)
            piece = mono[start:start + int(0.55 * rate)]
            found[hit["voice"]] = (db(float(np.max(np.abs(piece)))), db(float(np.sqrt(np.mean(piece ** 2)))))
        beat = mono[int(48 * step * rate):int(64 * step * rate)]
        levels[entry["id"]] = (found, db(float(np.sqrt(np.mean(beat ** 2)))), db(float(np.max(np.abs(audio)))))
    voices = [hit["voice"] for hit in tour[0]["alone"]]
    print("%-22s %s %7s %6s  %s" % ("kit", " ".join("%9s" % v[:9] for v in voices), "beat", "peak", "notes"))
    troubles = 0
    for entry in tour:
        found, beat, peak = levels[entry["id"]]
        said = []
        base = levels.get(entry["base"], (None,))[0] if entry["base"] else None
        for voice in voices:
            if found[voice][0] < -50:
                said.append("%s IS SILENT" % voice)
            elif base and abs(found[voice][1] - base[voice][1]) > 8:
                said.append("%s is %+.0f dB from the machine's" % (voice, found[voice][1] - base[voice][1]))
        if peak > -0.2:
            said.append("CLIPS")
        troubles += 1 if any(word.isupper() and len(word) > 2 for line in said for word in line.split()) else 0
        print("%-22s %s %7.1f %6.1f  %s" % (entry["name"][:22], " ".join("%9.1f" % found[v][1] for v in voices), beat, peak,
                                            "; ".join(said)))
    print("%d kits and machines, %d with trouble" % (len(tour), troubles))
    if "--mp3" in sys.argv:
        import lameenc
        target = sys.argv[sys.argv.index("--mp3") + 1]
        kits = [entry for entry in tour if entry["base"]]
        parts, at, lines = [], 0.0, []
        for entry in kits:
            audio, rate = load(os.path.join(folder, entry["file"]))
            lines.append("%d:%02d  %s" % (at // 60, at % 60, entry["name"]))
            parts += [audio[:, :2], np.zeros((int(0.4 * rate), 2))]
            at += len(audio) / float(rate) + 0.4
        whole = np.concatenate(parts)
        whole = whole / max(1.0, float(np.max(np.abs(whole))) / 0.9)
        encoder = lameenc.Encoder()
        encoder.set_bit_rate(192)
        encoder.set_in_sample_rate(rate)
        encoder.set_channels(2)
        encoder.set_quality(2)
        data = encoder.encode((whole * 32767).astype("<i2").tobytes()) + encoder.flush()
        open(target, "wb").write(data)
        open(os.path.splitext(target)[0] + ".txt", "w").write("\n".join(lines) + "\n")
        print("%s: %.0f s, %d KB" % (target, at, len(data) // 1024))


if __name__ == "__main__":
    main()
