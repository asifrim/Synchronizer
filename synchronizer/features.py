"""Per-transient feature extraction."""
from __future__ import annotations

from dataclasses import dataclass

import librosa
import numpy as np


N_MFCC = 13
MAX_SLICE_SECONDS = 1.0
MIN_SLICE_SECONDS = 0.05


@dataclass
class TransientFeatures:
    index: int
    start_time: float
    duration: float
    energy: float
    centroid_hz: float
    rolloff_hz: float
    bandwidth_hz: float
    zcr: float
    pitch_hz: float            # NaN when unvoiced
    pitch_confidence: float    # 0..1
    mfcc: np.ndarray           # shape (N_MFCC,)


def _slice_bounds(onsets: np.ndarray, total_seconds: float) -> list[tuple[float, float]]:
    bounds = []
    for i, t in enumerate(onsets):
        next_t = onsets[i + 1] if i + 1 < len(onsets) else total_seconds
        end = min(next_t, t + MAX_SLICE_SECONDS)
        end = max(end, t + MIN_SLICE_SECONDS)
        end = min(end, total_seconds)
        if end > t:
            bounds.append((t, end))
    return bounds


def _safe_mean(x: np.ndarray) -> float:
    return float(np.mean(x)) if x.size else float("nan")


def _pitch(slice_y: np.ndarray, sr: int) -> tuple[float, float]:
    """Estimate fundamental frequency over a transient slice with pyin.

    Returns (pitch_hz, confidence). NaN/0 when unvoiced.
    """
    if slice_y.size < 2048:
        return float("nan"), 0.0
    try:
        f0, _, voiced_prob = librosa.pyin(
            slice_y,
            sr=sr,
            fmin=float(librosa.note_to_hz("C2")),
            fmax=float(librosa.note_to_hz("C7")),
        )
    except (ValueError, RuntimeError):
        return float("nan"), 0.0

    voiced = f0[~np.isnan(f0)]
    if voiced.size == 0:
        return float("nan"), 0.0
    return float(np.median(voiced)), float(np.nanmean(voiced_prob))


def extract_features(
    y: np.ndarray,
    sr: int,
    onsets: np.ndarray,
    hop_length: int = 512,
    compute_pitch: bool = True,
    bounds: list[tuple[float, float]] | None = None,
) -> list[TransientFeatures]:
    # Use the caller's canonical bounds when supplied so this stage and the
    # embeddings stage operate on an identical transient set (the CLI computes
    # them once). Fall back to deriving them for direct callers / tests.
    if bounds is None:
        bounds = _slice_bounds(onsets, len(y) / sr)
    out: list[TransientFeatures] = []

    for i, (t0, t1) in enumerate(bounds):
        s0 = int(t0 * sr)
        # Guarantee a non-empty slice so this stage never silently drops a row
        # the embeddings stage keeps (which would misalign the two matrices).
        s1 = max(int(t1 * sr), s0 + 1)
        s = y[s0:s1]

        rms = librosa.feature.rms(y=s, hop_length=hop_length).flatten()
        centroid = librosa.feature.spectral_centroid(y=s, sr=sr, hop_length=hop_length).flatten()
        rolloff = librosa.feature.spectral_rolloff(y=s, sr=sr, hop_length=hop_length).flatten()
        bandwidth = librosa.feature.spectral_bandwidth(y=s, sr=sr, hop_length=hop_length).flatten()
        zcr = librosa.feature.zero_crossing_rate(y=s, hop_length=hop_length).flatten()
        mfcc = librosa.feature.mfcc(y=s, sr=sr, n_mfcc=N_MFCC, hop_length=hop_length)
        pitch_hz, pitch_conf = _pitch(s, sr) if compute_pitch else (float("nan"), 0.0)

        out.append(
            TransientFeatures(
                index=i,
                start_time=float(t0),
                duration=float(t1 - t0),
                energy=_safe_mean(rms),
                centroid_hz=_safe_mean(centroid),
                rolloff_hz=_safe_mean(rolloff),
                bandwidth_hz=_safe_mean(bandwidth),
                zcr=_safe_mean(zcr),
                pitch_hz=pitch_hz,
                pitch_confidence=pitch_conf,
                mfcc=np.mean(mfcc, axis=1),
            )
        )
    return out
