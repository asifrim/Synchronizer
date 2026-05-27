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


@dataclass
class ClassifiedTransient:
    features: TransientFeatures
    pitch_bucket: str          # low / mid / high / unpitched
    brightness_bucket: str     # dark / mid / bright
    energy_bucket: str         # soft / medium / loud
    duration_bucket: str       # short / medium / long
    timbre_cluster: int        # k-means cluster id, ordered by ascending mean centroid_hz
    transient_cluster: int     # holistic cluster across all features, k chosen by silhouette


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


def _holistic_clusters(
    transients: list[TransientFeatures],
    k_max: int,
) -> tuple[np.ndarray, int, float]:
    """Sweep k=2..k_max, pick the clustering with the highest silhouette score.

    Cluster IDs are remapped by ascending mean spectral centroid so that
    cluster 0 = darkest/lowest-energy group and the ordering is stable across
    runs.  Returns (labels, chosen_k, best_silhouette).
    """
    n = len(transients)
    if n < 4:
        return np.zeros(n, dtype=int), 1, 0.0

    X = _build_feature_matrix(transients)
    k_hi = min(k_max, n - 1)

    best_labels: np.ndarray = np.zeros(n, dtype=int)
    best_k = 2
    best_score = -1.0

    for k in range(2, k_hi + 1):
        km = KMeans(n_clusters=k, n_init=10, random_state=0)
        labels = km.fit_predict(X)
        score = float(silhouette_score(X, labels, sample_size=min(n, 2000), random_state=0))
        if score > best_score:
            best_score, best_k, best_labels = score, k, labels.copy()

    # Remap IDs by ascending mean centroid_hz for deterministic, ordered labels.
    centroids = np.array([t.centroid_hz for t in transients])
    cluster_brightness = np.array([
        centroids[best_labels == c].mean() if np.any(best_labels == c) else np.inf
        for c in range(best_k)
    ])
    order = np.argsort(cluster_brightness)
    remap = {int(old): new for new, old in enumerate(order)}
    return np.array([remap[int(c)] for c in best_labels], dtype=int), best_k, best_score


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
    holistic, chosen_k, silhouette = _holistic_clusters(transients, cluster_k_max)

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
            )
        )
    return out, chosen_k, silhouette
