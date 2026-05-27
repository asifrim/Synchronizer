"""Peak-amplitude envelope export for the Processing visualizer.

Processing's Sound library doesn't expose raw samples in a convenient way, so
we precompute a downsampled peak envelope here and ship it alongside the
events CSV.
"""
from __future__ import annotations

import csv
from pathlib import Path

import librosa
import numpy as np


DEFAULT_HOP_LENGTH = 64  # ~1.5 ms windows at 44.1 kHz — fine enough for pixel-level display


def write_waveform(audio_path: str | Path, out_path: str | Path, hop_length: int = DEFAULT_HOP_LENGTH) -> None:
    """Write a two-column CSV (time, peak) at native hop resolution.

    ``peak`` is max(|sample|) within each hop window. With the default hop of
    64 samples at 44.1 kHz this yields ~690 windows/second — enough for the
    Processing sketch to render one or more real peak values per screen pixel
    even when zoomed into a 4-second page window.
    """
    audio_path = Path(audio_path)
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    y, sr = librosa.load(str(audio_path), sr=None, mono=True)
    duration = len(y) / sr

    hop = max(1, hop_length)
    n_frames = max(1, len(y) // hop)
    y_trim = y[: n_frames * hop]
    windows = y_trim.reshape(n_frames, hop)
    peaks = np.abs(windows).max(axis=1)

    # Normalize to 0..1 for a stable visual scale regardless of source gain.
    peak_max = float(peaks.max()) if peaks.size else 1.0
    if peak_max > 0:
        peaks = peaks / peak_max

    with out_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "peak"])
        for i, p in enumerate(peaks):
            t = (i + 0.5) * duration / n_frames
            w.writerow([f"{t:.6f}", f"{p:.6f}"])
