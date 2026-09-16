"""Produce golden outputs for one corpus track.

Writes, under Bench/goldens/<track-stem>/:
  stems/{drums,bass,other,vocals}.wav   Demucs htdemucs via demucs-mlx
  beats.json                            Beat This! beats and downbeats (seconds)
  key.json                              chroma + Krumhansl key estimate with the full 24-key correlation profile
  info.json                             sample rate, duration, tool versions

Usage: uv run make_goldens.py /path/to/track.mp3 [--model htdemucs]
"""
import argparse, json, subprocess, sys, time
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
GOLDENS = HERE.parent / "goldens"

def load_audio(path: Path, sr: int = 44100):
    import librosa
    y, _ = librosa.load(str(path), sr=sr, mono=False)
    if y.ndim == 1:
        y = np.stack([y, y])
    return y, sr

def separate(path: Path, out: Path, model: str):
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    cmd = [sys.executable, "-m", "demucs_mlx", "-n", model, "-o", str(out), str(path)]
    subprocess.run(cmd, check=True)
    # demucs-mlx writes <out>/<model>/<track>/ or <out>/<track>/ depending on version; gather either.
    stems = {}
    (out / "stems").mkdir(exist_ok=True)
    for wav in list(out.rglob("*.wav")):
        if wav.parent.name == "stems":
            continue
        target = out / "stems" / wav.name
        wav.replace(target)
        stems[wav.stem] = str(target.relative_to(GOLDENS))
    for d in sorted((d for d in out.rglob("*") if d.is_dir() and d.name != "stems"), reverse=True):
        try: d.rmdir()
        except OSError: pass
    return stems, time.time() - t0

def beats(path: Path):
    from beat_this.inference import File2Beats
    f2b = File2Beats(checkpoint_path="final0", device="cpu", dbn=False)
    b, d = f2b(str(path))
    return {"beats": [float(x) for x in b], "downbeats": [float(x) for x in d]}

KRUMHANSL_MAJOR = np.array([6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88])
KRUMHANSL_MINOR = np.array([6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17])
NAMES = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

def key(y, sr):
    import librosa
    chroma = librosa.feature.chroma_cqt(y=y.mean(axis=0), sr=sr).mean(axis=1)
    scores = {}
    for i in range(12):
        scores[f"{NAMES[i]} major"] = float(np.corrcoef(np.roll(KRUMHANSL_MAJOR, i), chroma)[0, 1])
        scores[f"{NAMES[i]} minor"] = float(np.corrcoef(np.roll(KRUMHANSL_MINOR, i), chroma)[0, 1])
    best = max(scores, key=scores.get)
    return {"best": best, "scores": scores, "chroma": [float(c) for c in chroma]}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("track")
    ap.add_argument("--model", default="htdemucs")
    a = ap.parse_args()
    path = Path(a.track).resolve()
    out = GOLDENS / path.stem
    out.mkdir(parents=True, exist_ok=True)
    y, sr = load_audio(path)
    stems, sep_seconds = separate(path, out, a.model)
    (out / "beats.json").write_text(json.dumps(beats(path), indent=1))
    (out / "key.json").write_text(json.dumps(key(y, sr), indent=1))
    import torch, mlx.core as mx
    (out / "info.json").write_text(json.dumps({
        "source": str(path), "sample_rate": sr, "duration_s": y.shape[1] / sr,
        "separation_model": a.model, "separation_seconds": sep_seconds, "stems": stems,
        "versions": {"torch": torch.__version__, "mlx": mx.__version__, "python": sys.version.split()[0]},
    }, indent=1))
    print("goldens written to", out)

if __name__ == "__main__":
    main()
