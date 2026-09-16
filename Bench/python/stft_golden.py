"""STFT parity golden for Sources/Analysis/DSP/STFT.swift.

Generates the deterministic "sines + clicks" test signal (identical to
`SyntheticSignal.sinesAndClicks` in Swift), runs torch.stft with the PyTorch
convention (center=True, pad_mode="reflect", periodic Hann, n_fft=2048, hop=512),
and writes the magnitudes of the first FRAMES frames to
Bench/goldens/dsp/stft_golden.json.

Usage: cd Bench/python && uv run stft_golden.py
"""
import json
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "goldens" / "dsp" / "stft_golden.json"

SR = 44100
DURATION = 4.0
N_FFT = 2048
HOP = 512
FRAMES = 32

SINE_FREQS = [220.0, 587.33, 2637.02]
SINE_AMPS = [0.25, 0.18, 0.12]
CLICK_AMP = 0.9
FIRST_CLICK = 0.25
CLICK_PERIOD = 0.4735


def synth():
    n = int(round(SR * DURATION))
    x = np.zeros(n, dtype=np.float64)
    i = np.arange(n, dtype=np.float64)
    for f, a in zip(SINE_FREQS, SINE_AMPS):
        x += a * np.sin(2 * np.pi * f / SR * i)
    clicks = []
    k = 0
    while True:
        t = FIRST_CLICK + CLICK_PERIOD * k
        if t >= DURATION:
            break
        idx = int(round(t * SR))
        x[idx] += CLICK_AMP
        clicks.append(idx / SR)
        k += 1
    return x.astype(np.float32), clicks


def stft_torch(x):
    import torch
    sig = torch.from_numpy(x)
    win = torch.hann_window(N_FFT, periodic=True)
    X = torch.stft(sig, n_fft=N_FFT, hop_length=HOP, window=win, center=True,
                   pad_mode="reflect", return_complex=True)
    return X.abs().numpy().T, f"torch.stft {torch.__version__}"  # (frames, bins)


def stft_numpy(x):
    """Fallback with the same convention, used only if torch is unavailable."""
    half = N_FFT // 2
    padded = np.pad(x.astype(np.float64), half, mode="reflect")
    win = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT)
    frames = 1 + len(x) // HOP
    mags = np.empty((frames, half + 1))
    for t in range(frames):
        seg = padded[t * HOP:t * HOP + N_FFT] * win
        mags[t] = np.abs(np.fft.rfft(seg))
    return mags, f"numpy.fft.rfft {np.__version__}"


def main():
    x, clicks = synth()
    try:
        mags, generator = stft_torch(x)
    except ImportError:
        mags, generator = stft_numpy(x)
    mags = mags[:FRAMES]
    golden = {
        "generator": generator,
        "sample_rate": SR,
        "duration": DURATION,
        "n_fft": N_FFT,
        "hop": HOP,
        "window": "hann_periodic",
        "center": True,
        "pad_mode": "reflect",
        "frames": int(mags.shape[0]),
        "bins": int(mags.shape[1]),
        "total_frames": 1 + len(x) // HOP,
        "signal_length": int(len(x)),
        "signal_sum": float(np.sum(x, dtype=np.float64)),
        "signal_abs_sum": float(np.sum(np.abs(x), dtype=np.float64)),
        "signal_head": [float(v) for v in x[:8]],
        "click_times": clicks,
        "magnitudes": [[float(v) for v in row] for row in mags],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(golden, separators=(",", ":")))
    print(f"wrote {OUT} ({generator}; {mags.shape[0]} frames x {mags.shape[1]} bins)")


if __name__ == "__main__":
    main()
