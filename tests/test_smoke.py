"""End-to-end smoke test on a synthetic click-track."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import soundfile as sf

from synchronizer.classify import classify
from synchronizer.detect import detect_onsets
from synchronizer.features import extract_features
from synchronizer.output import write_csv


def _click_track(sr: int = 22050, n_clicks: int = 8, spacing_s: float = 1.5) -> np.ndarray:
    y = np.zeros(int(sr * (spacing_s * n_clicks + 0.5)), dtype=np.float32)
    for i in range(n_clicks):
        start = int(i * spacing_s * sr)
        # short decaying sine burst — different pitches to exercise classifier
        freq = 220.0 * (2 ** ((i % 4) / 12.0))
        t = np.arange(int(0.08 * sr)) / sr
        env = np.exp(-30 * t)
        y[start:start + t.size] += (0.6 * env * np.sin(2 * np.pi * freq * t)).astype(np.float32)
    return y


def test_pipeline(tmp_path: Path) -> None:
    sr = 22050
    y = _click_track(sr=sr)
    onsets = detect_onsets(y, sr)
    assert len(onsets) >= 6, f"expected ~8 onsets, got {len(onsets)}"

    feats = extract_features(y, sr, onsets)
    assert len(feats) == len(onsets)

    out = classify(feats)
    csv_path = tmp_path / "out.csv"
    write_csv(out, csv_path)

    text = csv_path.read_text()
    assert text.startswith("index,start_time,duration,")
    header = text.splitlines()[0]
    assert header.endswith("timbre_cluster")
    assert text.count("\n") == len(out) + 1  # header + rows
