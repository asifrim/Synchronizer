"""Bucket-style classification of transients relative to the current track."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score

from .features import TransientFeatures


PITCH_CONFIDENCE_FLOOR = 0.5
DEFAULT_N_TIMBRE_CLUSTERS = 6
DEFAULT_CLUSTER_K_MAX = 16
MULTI_K_MIN = 2
MULTI_K_MAX_FIXED = 8   # always computed regardless of silhouette sweep


@dataclass
class ClassifiedTransient:
    features: TransientFeatures
    pitch_bucket: str          # low / mid / high / unpitched
    brightness_bucket: str     # dark / mid / bright
    energy_bucket: str         # soft / medium / loud
    duration_bucket: str       # short / medium / long
    timbre_cluster: int        # k-means cluster id, ordered by ascending mean centroid_hz
    transient_cluster: int     # holistic cluster, k chosen by silhouette score
    transient_cluster_k2: int  # holistic cluster fixed at k=2
    transient_cluster_k3: int
    transient_cluster_k4: int
    transient_cluster_k5: int
    transient_cluster_k6: int
    transient_cluster_k7: int
    transient_cluster_k8: int


def _tercile_bucket(value: float, values: np.ndarray, labels: tuple[str, str, str]) -> str:
    if values.size == 0 or np.isnan(value):
        return labels[1]
    lo, hi = np.quantile(values, [1 / 3, 2 / 3])
    if value <= lo:
        return labels[0]
    if value >= hi:
        return labels[2]
    return labels[1]


def _timbre_clusters(transients: list[TransientFeatures], n_clusters: int) -> np.ndarray:
    """K-means on standardized MFCC vectors. Cluster IDs are remapped so that
    cluster 0 has the lowest mean spectral centroid (darkest timbre group) and
    cluster ``n_clusters-1`` has the highest. K-means itself returns arbitrary
    cluster numbers; the remap gives stable, semantically ordered IDs across
    runs."""
    if len(transients) < n_clusters:
        return np.zeros(len(transients), dtype=int)

    mfcc = np.stack([t.mfcc for t in transients])
    mfcc_norm = (mfcc - mfcc.mean(axis=0)) / (mfcc.std(axis=0) + 1e-9)

    km = KMeans(n_clusters=n_clusters, n_init=10, random_state=0)
    raw = km.fit_predict(mfcc_norm)

    centroids = np.array([t.centroid_hz for t in transients])
    cluster_brightness = np.array([
        centroids[raw == c].mean() if np.any(raw == c) else np.inf
        for c in range(n_clusters)
    ])
    order = np.argsort(cluster_brightness)
    remap = {int(old): new for new, old in enumerate(order)}
    return np.array([remap[int(c)] for c in raw], dtype=int)


def _build_feature_matrix(transients: list[TransientFeatures]) -> np.ndarray:
    """Standardized feature matrix for holistic clustering.

    Uses log-scaled energy and duration (wide dynamic range), plus spectral
    descriptors and MFCCs. Pitch is excluded — too sparse (NaN for unpitched
    transients) to be useful as a clustering dimension.
    """
    rows = []
    for t in transients:
        scalar = [
            np.log1p(t.energy),
            t.centroid_hz,
            t.rolloff_hz,
            t.bandwidth_hz,
            t.zcr,
            np.log1p(t.duration),
        ]
        rows.append(np.concatenate([scalar, t.mfcc]))
    X = np.array(rows, dtype=float)
    X = (X - X.mean(axis=0)) / (X.std(axis=0) + 1e-9)
    return X


def _remap_by_centroid(
    labels: np.ndarray, k: int, centroids: np.ndarray
) -> np.ndarray:
    """Remap cluster IDs so cluster 0 has the lowest mean spectral centroid."""
    cluster_brightness = np.array([
        centroids[labels == c].mean() if np.any(labels == c) else np.inf
        for c in range(k)
    ])
    order = np.argsort(cluster_brightness)
    remap = {int(old): new for new, old in enumerate(order)}
    return np.array([remap[int(c)] for c in labels], dtype=int)


def _holistic_clusters(
    transients: list[TransientFeatures],
    k_max: int,
) -> tuple[np.ndarray, int, float, dict[int, np.ndarray]]:
    """Sweep k=2..max(k_max, MULTI_K_MAX_FIXED), pick the best by silhouette.

    Also caches remapped labels for every k in MULTI_K_MIN..MULTI_K_MAX_FIXED.
    Returns (best_labels, chosen_k, best_silhouette, multi_k_labels) where
    multi_k_labels maps k -> remapped labels array.
    """
    n = len(transients)
    multi_k: dict[int, np.ndarray] = {
        k: np.zeros(n, dtype=int) for k in range(MULTI_K_MIN, MULTI_K_MAX_FIXED + 1)
    }
    if n < 4:
        return np.zeros(n, dtype=int), 1, 0.0, multi_k

    X = _build_feature_matrix(transients)
    centroids = np.array([t.centroid_hz for t in transients])
    # Always compute at least MULTI_K_MAX_FIXED so every panel has data.
    effective_k_hi = min(max(k_max, MULTI_K_MAX_FIXED), n - 1)

    best_labels: np.ndarray = np.zeros(n, dtype=int)
    best_k = MULTI_K_MIN
    best_score = -1.0

    for k in range(MULTI_K_MIN, effective_k_hi + 1):
        km = KMeans(n_clusters=k, n_init=10, random_state=0)
        raw = km.fit_predict(X)
        remapped = _remap_by_centroid(raw, k, centroids)

        if MULTI_K_MIN <= k <= MULTI_K_MAX_FIXED:
            multi_k[k] = remapped

        if k <= k_max:
            score = float(
                silhouette_score(X, raw, sample_size=min(n, 2000), random_state=0)
            )
            if score > best_score:
                best_score, best_k, best_labels = score, k, remapped.copy()

    return best_labels, best_k, best_score, multi_k


def classify(
    transients: list[TransientFeatures],
    n_timbre_clusters: int = DEFAULT_N_TIMBRE_CLUSTERS,
    cluster_k_max: int = DEFAULT_CLUSTER_K_MAX,
) -> tuple[list[ClassifiedTransient], int, float]:
    if not transients:
        return [], 0, 0.0

    energies = np.array([t.energy for t in transients])
    centroids = np.array([t.centroid_hz for t in transients])
    durations = np.array([t.duration for t in transients])
    pitches = np.array([
        t.pitch_hz for t in transients
        if not np.isnan(t.pitch_hz) and t.pitch_confidence >= PITCH_CONFIDENCE_FLOOR
    ])

    clusters = _timbre_clusters(transients, n_timbre_clusters)
    holistic, chosen_k, silhouette, multi_k = _holistic_clusters(transients, cluster_k_max)

    out = []
    for i, t in enumerate(transients):
        if np.isnan(t.pitch_hz) or t.pitch_confidence < PITCH_CONFIDENCE_FLOOR:
            pitch_bucket = "unpitched"
        else:
            pitch_bucket = _tercile_bucket(t.pitch_hz, pitches, ("low", "mid", "high"))

        out.append(
            ClassifiedTransient(
                features=t,
                pitch_bucket=pitch_bucket,
                brightness_bucket=_tercile_bucket(t.centroid_hz, centroids, ("dark", "mid", "bright")),
                energy_bucket=_tercile_bucket(t.energy, energies, ("soft", "medium", "loud")),
                duration_bucket=_tercile_bucket(t.duration, durations, ("short", "medium", "long")),
                timbre_cluster=int(clusters[i]),
                transient_cluster=int(holistic[i]),
                transient_cluster_k2=int(multi_k[2][i]),
                transient_cluster_k3=int(multi_k[3][i]),
                transient_cluster_k4=int(multi_k[4][i]),
                transient_cluster_k5=int(multi_k[5][i]),
                transient_cluster_k6=int(multi_k[6][i]),
                transient_cluster_k7=int(multi_k[7][i]),
                transient_cluster_k8=int(multi_k[8][i]),
            )
        )
    return out, chosen_k, silhouette
