"""Transient (onset) detection."""
from __future__ import annotations

from dataclasses import dataclass

import librosa
import numpy as np


@dataclass(frozen=True)
class DetectionConfig:
    sr: int | None = None
    hop_length: int = 512
    n_mels: int = 138
    fmax: float = 11025.0
    # SuperFlux novelty parameters
    lag: int = 2                       # spectral-flux lag in frames
    max_size: int = 3                  # frequency-direction max filter; >1 suppresses vibrato/decay-tail peaks
    # Peak picker
    pre_max: int = 20
    post_max: int = 20
    pre_avg: int = 100
    post_avg: int = 100
    delta: float = 0.07
    wait: int = 5                      # min frames between onsets within a band
    backtrack: bool = True
    # Multi-band detection
    multi_band: bool = True
    merge_tolerance_ms: float = 30.0   # cross-band hits within this window collapse to one
    # Per-band wait (lows / mids / highs) in milliseconds. Lows need a long
    # wait because kicks have a slow body that re-crosses the peak threshold
    # ~100ms after the click; hats need a short wait for fast roll/16th patterns.
    band_wait_ms: tuple[float, float, float] = (200.0, 100.0, 50.0)
    # Optional HPSS pre-step
    use_percussive: bool = False


def load_audio(path: str, sr: int | None = None) -> tuple[np.ndarray, int]:
    y, sr_out = librosa.load(path, sr=sr, mono=True)
    return y, sr_out


def _peak_pick(env: np.ndarray, sr: int, cfg: DetectionConfig, wait: int | None = None) -> np.ndarray:
    frames = librosa.onset.onset_detect(
        onset_envelope=env, sr=sr, hop_length=cfg.hop_length,
        backtrack=cfg.backtrack,
        pre_max=cfg.pre_max, post_max=cfg.post_max,
        pre_avg=cfg.pre_avg, post_avg=cfg.post_avg,
        delta=cfg.delta, wait=cfg.wait if wait is None else wait,
    )
    return librosa.frames_to_time(frames, sr=sr, hop_length=cfg.hop_length)


def _ms_to_frames(ms: float, sr: int, hop_length: int) -> int:
    return max(1, int(round(ms * sr / (1000.0 * hop_length))))


def _merge_onsets(times: np.ndarray, tolerance_s: float) -> np.ndarray:
    """Collapse onsets that fall within tolerance_s of each other (keeping the
    earlier). Used to merge cross-band detections of the same event."""
    if times.size == 0:
        return times
    times = np.sort(times)
    merged = [times[0]]
    for t in times[1:]:
        if t - merged[-1] > tolerance_s:
            merged.append(t)
    return np.asarray(merged)


def detect_onsets(y: np.ndarray, sr: int, cfg: DetectionConfig = DetectionConfig()) -> np.ndarray:
    """Return onset times in seconds.

    Uses a SuperFlux-style novelty function (mel-spectrogram spectral flux with a
    frequency-direction max filter of size ``max_size``) which produces sharper
    peaks and suppresses decay-tail double-triggers. With ``multi_band=True``
    (default), runs detection independently on three mel-band ranges
    (lows / mids / highs) and merges hits across bands within
    ``merge_tolerance_ms`` — this prevents a loud kick from masking a quiet
    hi-hat at the same moment while collapsing the same event reported in
    multiple bands into a single onset.
    """
    signal = y
    if cfg.use_percussive:
        _, signal = librosa.effects.hpss(y)

    fmax = min(cfg.fmax, sr / 2.0)

    if not cfg.multi_band:
        env = librosa.onset.onset_strength(
            y=signal, sr=sr, hop_length=cfg.hop_length,
            n_mels=cfg.n_mels, fmax=fmax,
            lag=cfg.lag, max_size=cfg.max_size,
        )
        return _peak_pick(env, sr, cfg)

    # Lows (kicks/sub) / mids (snare/body) / highs (hats/cymbals).
    n = cfg.n_mels
    channels = [slice(0, n // 3), slice(n // 3, 2 * n // 3), slice(2 * n // 3, n)]
    envs = librosa.onset.onset_strength_multi(
        y=signal, sr=sr, hop_length=cfg.hop_length,
        n_mels=cfg.n_mels, fmax=fmax,
        lag=cfg.lag, max_size=cfg.max_size,
        channels=channels,
    )

    band_waits = [_ms_to_frames(ms, sr, cfg.hop_length) for ms in cfg.band_wait_ms]
    band_times = [_peak_pick(env, sr, cfg, wait=w) for env, w in zip(envs, band_waits)]
    if not band_times:
        return np.array([])
    return _merge_onsets(np.concatenate(band_times), tolerance_s=cfg.merge_tolerance_ms / 1000.0)
