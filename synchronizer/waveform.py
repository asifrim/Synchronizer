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


DEFAULT_N_PEAKS = 4096


def write_waveform(audio_path: str | Path, out_path: str | Path, n_peaks: int = DEFAULT_N_PEAKS) -> None:
    """Write a two-column CSV (time, peak) with ``n_peaks`` rows uniformly
    spanning the audio file. ``peak`` is max(|sample|) within each window."""
    audio_path = Path(audio_path)
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    y, sr = librosa.load(str(audio_path), sr=None, mono=True)
    duration = len(y) / sr

    if len(y) >= n_peaks:
        per_window = len(y) // n_peaks
        y_trim = y[: per_window * n_peaks]
        windows = y_trim.reshape(n_peaks, per_window)
        peaks = np.abs(windows).max(axis=1)
    else:
        peaks = np.abs(y)
        n_peaks = len(peaks)

    # Normalize to 0..1 for a stable visual scale regardless of source gain.
    peak_max = float(peaks.max()) if peaks.size else 1.0
    if peak_max > 0:
        peaks = peaks / peak_max

    with out_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "peak"])
        for i, p in enumerate(peaks):
            t = (i + 0.5) * duration / n_peaks
            w.writerow([f"{t:.6f}", f"{p:.6f}"])
