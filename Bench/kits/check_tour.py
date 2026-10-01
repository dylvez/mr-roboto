"""Checks a sound tour: that every instrument sounds, how loud, and whether its first note is in tune.

    python check_tour.py <tour folder> [--mp3 <file>]

The tour is what `zzSoundTour` wrote: a WAV an instrument and `tour.json`. Each phrase is a note
held a beat and a half at 100 bpm, five more up and down its arpeggio, and a chord. The first note's
pitch is read from its spectrum and set against the key that was played; a recording mapped an
octave out, or a semitone, shows here. With --mp3 the phrases are joined, in the order of the
table, into one file to listen to (needs lameenc).
"""
import json
import os
import sys
import wave

import numpy as np


def load(path):
    with wave.open(path, "rb") as file:
        rate, channels, frames = file.getframerate(), file.getnchannels(), file.getnframes()
        raw = np.frombuffer(file.readframes(frames), dtype=np.uint8).reshape(-1, 3)
    data = (raw[:, 0].astype(np.int32) | (raw[:, 1].astype(np.int32) << 8) | (raw[:, 2].astype(np.int8).astype(np.int32) << 16)) / 8388608.0
    return data.reshape(-1, channels), rate


def db(value):
    return 20 * np.log10(max(value, 1e-9))


def likeness(signal, lag):
    """How like itself the signal is a lag later, -1 to 1. The lag need not be whole samples: at
    the top of a glockenspiel a period is under thirty of them, and a sample either way is a
    third of a semitone."""
    count = len(signal) - int(np.ceil(lag)) - 1
    if lag < 1 or count < 16:
        return 0.0
    early = signal[:count]
    late = np.interp(np.arange(count) + lag, np.arange(len(signal)), signal)
    return float(np.dot(early, late) / np.sqrt(np.dot(early, early) * np.dot(late, late) + 1e-18))


def pitch(signal, rate, expected):
    """Where the note is against the key played: cents, and "up" or "down" when it is an octave out.

    A note repeats every period whatever its harmonics weigh, so it is looked for by its period
    and not its loudest partial: a horn's second harmonic is louder than its first and the note
    is still where the first is. A note an octave up repeats every half period as well.
    """
    if len(signal) < rate // 10:
        return None, ""
    period = rate / expected
    # The lag near the period where it is most like itself, within a semitone and a half.
    lags = [period * 2 ** (cents / 1200.0) for cents in range(-150, 151, 5)]
    scores = [likeness(signal, lag) for lag in lags]
    best = int(np.argmax(scores))
    cents = -(best * 5 - 150)
    at, half, double = scores[best], likeness(signal, lags[best] / 2), likeness(signal, lags[best] * 2)
    if at > 0.8 and half > 0.9 * at:
        return cents, "up"
    # An octave down repeats every two periods and not every one; looked for at the key's own
    # period, since nothing near it was found to be like.
    if likeness(signal, period) < 0.5 and likeness(signal, period * 2) > 0.8:
        return 0, "down"
    if at < 0.6:
        return cents, "unsure"
    return cents, ""


def main():
    folder = sys.argv[1]
    tour = json.load(open(os.path.join(folder, "tour.json")))
    tour.sort(key=lambda entry: (entry["family"], entry["name"]))
    beat = 0.6
    joined = []
    print("%-34s %-8s %5s %6s %6s %7s %7s  %s" % ("instrument", "family", "zones", "rms", "peak", "chord", "cents", "notes"))
    troubles = 0
    for entry in tour:
        audio, rate = load(os.path.join(folder, entry["file"]))
        mono = audio.mean(axis=1)
        first = mono[int(0.12 * rate):int(1.5 * beat * rate)]
        chord = mono[int(8 * beat * rate):int(11 * beat * rate)]
        expected = 440.0 * 2 ** ((entry["root"] - 69) / 12.0)
        cents, octave = pitch(first, rate, expected)
        cents = float("nan") if cents is None else cents
        level = db(float(np.sqrt(np.mean(mono ** 2))))
        peak = db(float(np.max(np.abs(audio))))
        held = db(float(np.sqrt(np.mean(chord ** 2)))) if len(chord) else -180.0
        said = []
        if peak < -40:
            said.append("SILENT")
        if octave in ("up", "down"):
            said.append("AN OCTAVE %s" % octave.upper())
        elif octave == "unsure":
            said.append("pitch not clear (struck or inharmonic)")
        elif abs(cents) > 40:
            said.append("OUT OF TUNE")
        if held < level - 25:
            said.append("the chord has died away")
        if peak > -0.2:
            said.append("clips")
        # The note held long: whether a recording that loops is still sounding at the end of it,
        # and whether the loop meets itself. A seam that does not is one sample's jump far past
        # any the note makes by itself.
        long = mono[int(12 * beat * rate):int(19.5 * beat * rate)]
        if entry.get("looped") and len(long) > 4 * rate:
            early, late = long[int(0.3 * rate):int(1.3 * rate)], long[int(3.2 * rate):int(4.2 * rate)]
            fallen = db(float(np.sqrt(np.mean(late ** 2)))) - db(float(np.sqrt(np.mean(early ** 2))))
            if fallen < -15:
                said.append("THE HELD NOTE DIES (%+.0f dB)" % fallen)
            steps = np.abs(np.diff(long[int(0.3 * rate):int(4.2 * rate)]))
            windows = steps[:len(steps) // 256 * 256].reshape(-1, 256).max(axis=1)
            jump = float(windows.max() / (np.median(windows) + 1e-12))
            if jump > 6:
                said.append("THE LOOP CLICKS (a step %.0f times the usual, at %.2f s)" % (
                    jump, 0.3 + int(np.argmax(windows)) * 256 / float(rate)))
            there, where = pitch(late, rate, expected)
            if there is not None and where == "" and abs(there) > 40:
                said.append("THE LOOP IS OUT OF TUNE (%+d)" % there)
        troubles += 1 if any(word.isupper() for word in said) else 0
        print("%-34s %-8s %5d %6.1f %6.1f %7.1f %7.0f  %s" % (entry["name"][:34], entry["family"], entry["zones"], level, peak, held, cents,
                                                              "; ".join(said)))
        joined.append(audio)
    print("%d instruments, %d with trouble" % (len(tour), troubles))
    if "--mp3" in sys.argv:
        import lameenc
        target = sys.argv[sys.argv.index("--mp3") + 1]
        gap = np.zeros((int(0.4 * rate), 2))
        whole = np.concatenate([part for audio in joined for part in (audio[:, :2], gap)])
        # To 16 bits at the rate it has; one level for the whole tour, so a quiet instrument is heard as quiet.
        whole = whole / max(1.0, float(np.max(np.abs(whole))) / 0.9)
        encoder = lameenc.Encoder()
        encoder.set_bit_rate(192)
        encoder.set_in_sample_rate(rate)
        encoder.set_channels(2)
        encoder.set_quality(2)
        data = encoder.encode((whole * 32767).astype("<i2").tobytes()) + encoder.flush()
        open(target, "wb").write(data)
        at = 0.0
        with open(os.path.splitext(target)[0] + ".txt", "w") as listing:
            for entry, audio in zip(tour, joined):
                listing.write("%d:%02d  %s (%s)\n" % (at // 60, at % 60, entry["name"], entry["family"]))
                at += len(audio) / float(rate) + 0.4
        print("%s: %.0f s, %d KB" % (target, at, len(data) // 1024))


if __name__ == "__main__":
    main()
