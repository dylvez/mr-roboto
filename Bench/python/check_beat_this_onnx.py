"""Check that Bench/models/beat_this.onnx is the Beat This! `final0` checkpoint.

Runs the torch model and the ONNX model on the same log-mel spectrogram of a track, with the
package's own chunking (1500 frames, 6-frame border, keep_first), and compares the framewise
logits and the `dbn=False` post-processed beats. With no track argument it uses the Arrival
corpus track and also checks against Bench/goldens/Arrival/beats.json.

Optionally dumps the reference spectrogram and logits as .npy for debugging a port.

Usage:  uv run --with onnxruntime check_beat_this_onnx.py [track] [--dump DIR]
"""
import argparse, json, time
from pathlib import Path
import numpy as np, torch, soxr
from beat_this.inference import load_model, split_predict_aggregate
from beat_this.preprocessing import load_audio, LogMelSpect
from beat_this.model.postprocessor import Postprocessor
import onnxruntime as ort

HERE = Path(__file__).resolve().parent
MODEL = HERE.parent / "models" / "beat_this.onnx"
ARRIVAL = Path("/Users/dylanfulmer/Documents/projects/vessel/public/assets/audio/interiorseason/Arrival.mp3")
GOLDEN = HERE.parent / "goldens" / "Arrival" / "beats.json"


class OnnxModel:
    def __init__(self, path):
        self.sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])

    def __call__(self, x):
        beat, downbeat = self.sess.run(None, {"input_spectrogram": x.numpy()})
        return {"beat": torch.from_numpy(beat), "downbeat": torch.from_numpy(downbeat)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("track", nargs="?", type=Path, default=ARRIVAL)
    ap.add_argument("--dump", type=Path, help="directory for spect.npy and *_logits_*.npy")
    a = ap.parse_args()

    signal, sr = load_audio(str(a.track))
    if signal.ndim == 2:
        signal = signal.mean(1)
    if sr != 22050:
        signal = soxr.resample(signal, sr, 22050)
    spect = LogMelSpect()(torch.tensor(signal, dtype=torch.float32))
    print(f"spect {tuple(spect.shape)} min {spect.min():.4g} max {spect.max():.4g} mean {spect.mean():.4g}")

    results = {}
    for name, model in (("torch", load_model("final0", "cpu")), ("onnx", OnnxModel(MODEL))):
        t0 = time.time()
        with torch.inference_mode():
            pred = split_predict_aggregate(spect, 1500, 6, "keep_first", model)
        results[name] = (pred["beat"].float(), pred["downbeat"].float())
        print(f"{name}: {time.time() - t0:.1f}s")

    (bt, dt), (bo, do) = results["torch"], results["onnx"]
    print(f"max |beat logit diff| {(bt - bo).abs().max():.3g}, max |downbeat logit diff| {(dt - do).abs().max():.3g}")

    pp = Postprocessor("minimal")
    golden = json.load(open(GOLDEN)) if a.track == ARRIVAL and GOLDEN.exists() else None
    for name, (b, d) in results.items():
        beats, downs = pp(b, d)
        line = f"{name}: {len(beats)} beats, {len(downs)} downbeats"
        if golden:
            line += f", equals golden: {np.array_equal(beats, golden['beats']) and np.array_equal(downs, golden['downbeats'])}"
        print(line)

    if a.dump:
        a.dump.mkdir(parents=True, exist_ok=True)
        np.save(a.dump / "spect.npy", spect.numpy())
        for name, (b, d) in results.items():
            np.save(a.dump / f"beat_logits_{name}.npy", b.numpy())
            np.save(a.dump / f"downbeat_logits_{name}.npy", d.numpy())
        print("dumped to", a.dump)


if __name__ == "__main__":
    main()
