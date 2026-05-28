"""PANNs CNN14 embeddings for transient slices.

This module is the only one that depends on torch / panns_inference. Import
lazily where it's called from the CLI so `synchronizer --help` doesn't trigger
a torch import.

The pipeline used to feed a 19-d hand-crafted feature matrix (log-energy +
spectral descriptors + 13 MFCCs) into k-means. PANNs CNN14, trained on
AudioSet, produces 2048-d penultimate-layer features that capture semantic
timbre — sub-kicks cluster with sub-kicks even when their spectral centroids
differ from each other due to mixing.
"""
from __future__ import annotations

import sys

import librosa
import numpy as np

from .features import _slice_bounds


PANNS_SR = 32000          # CNN14 is trained at 32 kHz mono
SLICE_PAD_SECONDS = 1.0   # pad every transient to this length before batching
BATCH_SIZE = 32           # bounded so CPU runs don't blow up memory


def compute_panns_embeddings(
    y: np.ndarray, sr: int, onsets: np.ndarray,
) -> np.ndarray:
    """Return a ``(n_transients, 2048)`` embedding matrix from PANNs CNN14.

    ``y``/``sr`` is the audio the onsets were detected on (the drum stem in
    the default CLI flow). Slices use the same bounds as ``features.extract_features``
    so embeddings line up 1:1 with the feature rows.
    """
    try:
        import torch  # noqa: F401
        from panns_inference import AudioTagging
    except ImportError as e:
        raise RuntimeError(
            "PANNs is not installed. Install with `pip install panns-inference torch`."
        ) from e

    if len(onsets) == 0:
        return np.zeros((0, 2048), dtype=np.float32)

    if sr != PANNS_SR:
        y = librosa.resample(y, orig_sr=sr, target_sr=PANNS_SR)
    total = len(y) / PANNS_SR
    bounds = _slice_bounds(onsets, total)

    pad_samples = int(SLICE_PAD_SECONDS * PANNS_SR)
    batch = np.zeros((len(bounds), pad_samples), dtype=np.float32)
    for i, (t0, t1) in enumerate(bounds):
        s0 = int(t0 * PANNS_SR)
        s1 = min(int(t1 * PANNS_SR), s0 + pad_samples)
        seg = y[s0:s1]
        if seg.size > pad_samples:
            seg = seg[:pad_samples]
        batch[i, :seg.size] = seg

    device = "cuda" if _cuda_available() else "cpu"
    print(f"[panns] computing {len(bounds)} embeddings on {device}…", file=sys.stderr)
    tagger = AudioTagging(checkpoint_path=None, device=device)

    embeddings = np.zeros((len(bounds), 2048), dtype=np.float32)
    for start in range(0, len(bounds), BATCH_SIZE):
        end = min(start + BATCH_SIZE, len(bounds))
        chunk = batch[start:end]
        _, emb = tagger.inference(chunk)
        embeddings[start:end] = np.asarray(emb, dtype=np.float32)
    return embeddings


def _cuda_available() -> bool:
    try:
        import torch
    except ImportError:
        return False
    return bool(torch.cuda.is_available())
