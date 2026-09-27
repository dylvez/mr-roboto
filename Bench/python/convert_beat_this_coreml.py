"""Convert Beat This! (`final0`) to a Core ML program the app runs on the GPU.

The app runs the ONNX export on ONNX Runtime's CPU kernels, about 350 ms a 30 s chunk on an M5.
Converted from the PyTorch source with Apple's own converter, at a fixed 1500-frame input (the
reference chunk length, which is every chunk of a piece longer than 30 s) and in float16, the model
runs in about 75 ms a chunk on the GPU and picks the same beats and downbeats.

Not the Neural Engine: its compiler was still compiling this model after two hours (the attention
over all 1500 frames seems too much for it at this length). Not the CPU in float16 either, which is
only 1.5× faster and moved a downbeat on Arrival by a frame; nor the CPU in float32, which is slower
than ONNX Runtime.

Checks before it installs anything: every full chunk of `--audio`, run on the compiled model on the
GPU, against PyTorch, peak-picked the reference's way; the beats and downbeats must be the same.

    uv run convert_beat_this_coreml.py [--audio PATH] [--out DIR]

Installs `beat_this_1500.mlmodelc` (compiled, so the app does not compile it at launch) into
`~/Library/Application Support/MrRoboto/models` by default, beside `beat_this.onnx`, which the app
keeps for pieces shorter than one chunk and as the fallback.
"""

import argparse
import shutil
import sys
import tempfile
import time
from pathlib import Path

import coremltools as ct
import librosa
import numpy as np
import torch
from beat_this.inference import load_model
from beat_this.preprocessing import LogMelSpect

FRAMES = 1500
MODELS = Path.home() / "Library/Application Support/MrRoboto/models"


# coremltools 9.0 casts a folded one-element shape with `int(array)`, which NumPy 2 refuses ("only
# 0-dimensional arrays can be converted to Python scalars"). The same conversion, taking `.item()`.
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil import register_torch_op
from coremltools.converters.mil.frontend.torch.ops import _get_inputs


def _cast(context, node, dtype, dtype_name):
    x = _get_inputs(context, node, expected=1)[0]
    if not (len(x.shape) == 0 or all(d == 1 for d in x.shape)):
        raise ValueError("input to cast must be either a scalar or a length 1 tensor")
    if x.can_be_folded_to_const():
        value = x.val.item() if isinstance(x.val, np.ndarray) else x.val
        res = x if isinstance(value, dtype) and not isinstance(x.val, np.ndarray) else mb.const(val=dtype(value), name=node.name)
    elif len(x.shape) > 0:
        res = mb.cast(x=mb.squeeze(x=x, name=node.name + "_item"), dtype=dtype_name, name=node.name)
    else:
        res = mb.cast(x=x, dtype=dtype_name, name=node.name)
    context.add(res, node.name)


# The rotary embeddings take positions × frequencies as `einsum("..., f -> ... f")`, which the
# converter's einsum cannot build ("perm should have the same length as rank(x)"). The same outer
# product as a broadcast multiply, for tracing only.
import rotary_embedding_torch.rotary_embedding_torch as rotary

_einsum = rotary.einsum


def _outer_einsum(equation, *operands):
    if equation.replace(" ", "") == "...,f->...f":
        positions, frequencies = operands
        return positions[..., None] * frequencies
    return _einsum(equation, *operands)


rotary.einsum = _outer_einsum


@register_torch_op(torch_alias=["int"], override=True)
def _int(context, node):
    _cast(context, node, int, "int32")


@register_torch_op(torch_alias=["bool"], override=True)
def _bool(context, node):
    _cast(context, node, bool, "bool")


class Logits(torch.nn.Module):
    """The model with its dict of heads as a tuple, which tracing needs."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        out = self.model(x)
        return out["beat"], out["downbeat"]


def spectrogram(path: Path) -> torch.Tensor:
    signal, rate = librosa.load(path, sr=22050, mono=True)
    return LogMelSpect(device="cpu")(torch.tensor(signal, dtype=torch.float32))


def peaks(logits: np.ndarray) -> np.ndarray:
    """The reference's minimal peak picking: local maxima over ±3 frames above 0."""
    padded = np.pad(logits, 3, constant_values=-np.inf)
    windows = np.lib.stride_tricks.sliding_window_view(padded, 7)
    return np.flatnonzero((logits > 0) & (logits == windows.max(axis=1)))


def full_chunks(spect: torch.Tensor) -> list[torch.Tensor]:
    """The piece's 1500-frame chunks as the app cuts them, without the edge padding: every 1488
    frames, the last moved left to end at the end."""
    starts = list(range(0, spect.shape[0] - FRAMES, FRAMES - 12)) + [spect.shape[0] - FRAMES]
    return [spect[start:start + FRAMES][None] for start in starts]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", type=Path,
                        default=Path("/Users/dylanfulmer/Documents/projects/vessel/public/assets/audio/interiorseason/Arrival.mp3"))
    parser.add_argument("--out", type=Path, default=MODELS)
    args = parser.parse_args()

    spect = spectrogram(args.audio)
    if spect.shape[0] < FRAMES:
        print(f"{args.audio.name} is shorter than one chunk; pick a longer track", file=sys.stderr)
        return 1

    model = Logits(load_model("final0", "cpu").eval())
    with torch.no_grad():
        traced = torch.jit.trace(model, torch.zeros(1, FRAMES, 128), check_trace=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_spectrogram", shape=(1, FRAMES, 128), dtype=np.float32)],
        outputs=[ct.TensorType(name="beat", dtype=np.float32), ct.TensorType(name="downbeat", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = "Beat This! final0 (Foscarin, Schlüter, Widmer, ISMIR 2024), 1500-frame chunks, float16"
    mlmodel.version = "final0-1500"

    with tempfile.TemporaryDirectory() as scratch:
        package = Path(scratch) / "beat_this_1500.mlpackage"
        mlmodel.save(str(package))
        compiled = Path(ct.utils.compile_model(str(package), str(Path(scratch) / "beat_this_1500.mlmodelc")))
        loaded = ct.models.CompiledMLModel(str(compiled), compute_units=ct.ComputeUnit.CPU_AND_GPU)
        chunks = full_chunks(spect)
        loaded.predict({"input_spectrogram": chunks[0].numpy()})  # warm
        worst, elapsed = 0.0, 0.0
        for index, chunk in enumerate(chunks):
            with torch.no_grad():
                reference = [t.numpy()[0] for t in model(chunk)]
            start = time.perf_counter()
            out = loaded.predict({"input_spectrogram": chunk.numpy().astype(np.float32)})
            elapsed += time.perf_counter() - start
            for name, ref in zip(("beat", "downbeat"), reference):
                got = out[name].reshape(-1)
                worst = max(worst, float(np.abs(got - ref).max()))
                if not np.array_equal(peaks(got), peaks(ref)):
                    print(f"chunk {index}: the converted model's {name}s differ from PyTorch's "
                          f"({sorted(set(peaks(got)) ^ set(peaks(ref)))}); not installing it", file=sys.stderr)
                    return 1
        print(f"{len(chunks)} chunks of {args.audio.name} on the GPU: {elapsed / len(chunks) * 1000:.1f} ms a chunk, "
              f"max |logit diff| {worst:.4f}, same beats and downbeats as PyTorch")

        args.out.mkdir(parents=True, exist_ok=True)
        destination = args.out / "beat_this_1500.mlmodelc"
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(compiled, destination)
    print(f"installed {destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
