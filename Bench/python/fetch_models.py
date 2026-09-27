"""Install the models the Swift analysis providers load at runtime.

The app does not bundle model files. `AnalysisONNX.BeatThisTracker` looks for
`beat_this.onnx` and `beat_this_1500.mlmodelc` at caller-provided URLs or, by default, in
`~/Library/Application Support/MrRoboto/models/`. This script puts them there.

beat_this.onnx
  Beat This! (Foscarin, Schlüter, Widmer, ISMIR 2024) `final0` checkpoint exported to ONNX
  (opset 14, input `input_spectrogram` [1, time, 128] float32, outputs `beat` and
  `downbeat` [1, time] logits, dynamic time axis). Taken from the MIT-licensed
  https://github.com/mosynthkey/beat_this_cpp at the commit below rather than re-exported,
  and checked against the bench's own torch `final0` on the Arrival track
  (`check_beat_this_onnx.py`: max |logit diff| 6e-5, identical beats and downbeats).

beat_this_1500.mlmodelc
  The same checkpoint converted to Core ML for the GPU, built here rather than downloaded, by
  `convert_beat_this_coreml.py`, which checks it against PyTorch on `--check-audio` before
  installing it. Skipped when already installed (unless --force) or with --no-coreml. Without
  it the app runs every chunk on ONNX Runtime, about 12x slower.

Usage:  uv run fetch_models.py [--dest DIR] [--force] [--no-coreml] [--check-audio PATH]
"""
import argparse, hashlib, shutil, sys, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
BENCH_MODELS = HERE.parent / "models"
DEFAULT_DEST = Path.home() / "Library" / "Application Support" / "MrRoboto" / "models"

MODELS = {
    "beat_this.onnx": {
        "url": "https://raw.githubusercontent.com/mosynthkey/beat_this_cpp/"
               "07ab790a9ec2eda8093d52d249e3ec4f0510ee72/onnx/beat_this.onnx",
        "sha256": "c5c1466e08abdb03fdeb50668a06f244b787d564c212490482231a9cfbe9ccbd",
        "size": 83_077_778,
    },
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def ensure_bench_copy(name: str, spec: dict, force: bool) -> Path:
    """The bench keeps its own copy under Bench/models; download it if missing or wrong."""
    BENCH_MODELS.mkdir(parents=True, exist_ok=True)
    local = BENCH_MODELS / name
    if local.exists() and not force and sha256(local) == spec["sha256"]:
        return local
    print(f"downloading {name} ({spec['size'] / 1e6:.1f} MB) from {spec['url']}")
    tmp = local.with_suffix(local.suffix + ".part")
    urllib.request.urlretrieve(spec["url"], tmp)
    digest = sha256(tmp)
    if digest != spec["sha256"]:
        tmp.unlink()
        sys.exit(f"{name}: SHA-256 mismatch: got {digest}, expected {spec['sha256']}")
    tmp.replace(local)
    return local


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dest", type=Path, default=DEFAULT_DEST, help=f"install directory (default: {DEFAULT_DEST})")
    ap.add_argument("--force", action="store_true", help="re-download and overwrite even if hashes match, and convert again")
    ap.add_argument("--no-coreml", action="store_true", help="skip the Core ML conversion")
    ap.add_argument("--check-audio", type=Path, help="a track longer than 30 s to check the conversion on")
    a = ap.parse_args()
    a.dest.mkdir(parents=True, exist_ok=True)
    for name, spec in MODELS.items():
        src = ensure_bench_copy(name, spec, a.force)
        dst = a.dest / name
        if dst.exists() and not a.force and sha256(dst) == spec["sha256"]:
            print(f"{dst}: up to date")
            continue
        shutil.copyfile(src, dst)
        print(f"{dst}: installed ({spec['sha256'][:12]}…)")
    if not a.no_coreml:
        install_coreml(a.dest, a.force, a.check_audio)


def install_coreml(dest: Path, force: bool, audio: Path | None):
    """Builds and installs the Core ML model. A failure here leaves the ONNX install standing: the app
    falls back to ONNX Runtime."""
    import convert_beat_this_coreml as convert  # torch and coremltools: only when converting
    dst = dest / convert.INSTALLED_NAME
    if dst.exists() and not force:
        print(f"{dst}: installed (--force to convert again)")
        return
    print(f"converting Beat This! to Core ML for {dst}")
    if convert.install(audio or convert.DEFAULT_AUDIO, dest) != 0:
        print(f"{dst}: not installed; the app will run Beat This! on ONNX Runtime. "
              "Fix the above and run again, or pass --no-coreml.", file=sys.stderr)


if __name__ == "__main__":
    main()
