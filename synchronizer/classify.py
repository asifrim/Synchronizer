"""Bucket-style classification of transients relative to the current track."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from sklearn.cluster import AgglomerativeClustering
from sklearn.metrics import silhouette_score
from umap import UMAP

from .features import TransientFeatures


PITCH_CONFIDENCE_FLOOR = 0.5
DEFAULT_CLUSTER_K_MAX = 16
MULTI_K_MIN = 2
MULTI_K_MAX_FIXED = 8   # always computed regardless of best-k selection

# UMAP hyperparameters (see Clustering_strategy.md)
UMAP_N_COMPONENTS = 10
UMAP_MIN_DIST = 0.0
UMAP_N_NEIGHBORS = 30

# HDBSCAN min cluster size as a fraction of total transients (floor at 3)
HDBSCAN_MIN_CLUSTER_SIZE_FRAC = 0.05


@dataclass
class ClassifiedTransient:
    features: TransientFeatures
    pitch_bucket: str          # low / mid / high / unpitched
    brightness_bucket: str     # dark / mid / bright
    energy_bucket: str         # soft / medium / loud
    duration_bucket: str       # short / medium / long
    transient_cluster: int     # holistic cluster: UMAP→HDBSCAN→agglomerative cap at k_max
    transient_cluster_k2: int  # HDBSCAN clusters agglomeratively merged to k=2
    transient_cluster_k3: int
    transient_cluster_k4: int
    transient_cluster_k5: int
    transient_cluster_k6: int
    transient_cluster_k7: int
    transient_cluster_k8: int


def _tercile_thresholds(values: np.ndarray) -> tuple[float, float] | None:
    if values.size == 0:
        return None
    lo, hi = np.quantile(values, [1 / 3, 2 / 3])
    return float(lo), float(hi)


def _tercile_bucket(
    value: float,
    thresholds: tuple[float, float] | None,
    labels: tuple[str, str, str],
) -> str:
    if thresholds is None or np.isnan(value):
        return labels[1]
    lo, hi = thresholds
    if value <= lo:
        return labels[0]
    if value >= hi:
        return labels[2]
    return labels[1]


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
    embeddings: np.ndarray,
    centroids: np.ndarray,
    k_max: int,
) -> tuple[np.ndarray, int, float, dict[int, np.ndarray]]:
    """UMAP compression → HDBSCAN density clustering → agglomerative cap at k_max.

    Multi-k panels (k=2..8) are produced by agglomerative merging of the HDBSCAN
    cluster centroids down to each target k. For panels where k ≥ n_raw the full
    HDBSCAN result is used as-is.

    Returns (best_labels, chosen_k, silhouette, multi_k_labels).
    """
    from sklearn.cluster import HDBSCAN

    n = embeddings.shape[0]
    multi_k: dict[int, np.ndarray] = {
        k: np.zeros(n, dtype=int) for k in range(MULTI_K_MIN, MULTI_K_MAX_FIXED + 1)
    }
    if n < 4:
        return np.zeros(n, dtype=int), 1, 0.0, multi_k

    # Step 1: compress 2048-d PANNs embeddings to a dense low-d manifold.
    # Clamp hyperparams so they stay valid on small datasets.
    n_neighbors = min(UMAP_N_NEIGHBORS, n - 1)
    n_components = min(UMAP_N_COMPONENTS, n - 1)
    X = UMAP(
        n_components=n_components,
        min_dist=UMAP_MIN_DIST,
        n_neighbors=n_neighbors,
        random_state=0,
    ).fit_transform(embeddings)

    # Step 2: density-based clustering on the compressed manifold.
    # min_cluster_size scales with the dataset; floor at 3 so small tracks
    # still get meaningful clusters.
    min_cluster_size = max(3, int(n * HDBSCAN_MIN_CLUSTER_SIZE_FRAC))
    raw_labels: np.ndarray = HDBSCAN(min_cluster_size=min_cluster_size, copy=True).fit_predict(X)

    n_raw = int(raw_labels.max()) + 1  # clusters are 0..n_raw-1; -1 = noise

    # Degenerate: HDBSCAN found no clusters (all noise). Return a single cluster.
    if n_raw < 1:
        return np.zeros(n, dtype=int), 1, 0.0, multi_k

    # Assign noise points to the nearest HDBSCAN cluster centroid (UMAP space).
    cluster_centers = np.array([
        X[raw_labels == c].mean(axis=0) for c in range(n_raw)
    ])
    labels = raw_labels.copy()
    noise_mask = raw_labels == -1
    if noise_mask.any():
        dists = np.linalg.norm(
            X[noise_mask, np.newaxis, :] - cluster_centers[np.newaxis, :, :], axis=2
        )
        labels[noise_mask] = dists.argmin(axis=1)

    # Step 3: post-hoc agglomerative merge to respect k_max.
    # [HDBSCAN → n_raw clusters] → [Agglomerative on centroids → k_max] → [map back]
    if n_raw > k_max:
        agg_map = AgglomerativeClustering(n_clusters=k_max).fit_predict(cluster_centers)
        labels = np.array([agg_map[int(l)] for l in labels], dtype=int)
        final_k = k_max
    else:
        final_k = n_raw

    best_labels = _remap_by_centroid(labels, final_k, centroids)

    score = 0.0
    if final_k >= 2:
        score = float(
            silhouette_score(X, best_labels, sample_size=min(n, 2000), random_state=0)
        )

    # Multi-k panels: agglomerative merge from the HDBSCAN cluster centroids.
    # For k < n_raw: merge to k. For k >= n_raw: HDBSCAN already has ≤ k
    # clusters, so use the full result as-is (can't split without a new algorithm).
    for k in range(MULTI_K_MIN, MULTI_K_MAX_FIXED + 1):
        if k < n_raw:
            agg_labels = AgglomerativeClustering(n_clusters=k).fit_predict(cluster_centers)
            k_labels = np.array([agg_labels[int(l)] for l in labels], dtype=int)
            multi_k[k] = _remap_by_centroid(k_labels, k, centroids)
        else:
            multi_k[k] = _remap_by_centroid(labels.copy(), n_raw, centroids)

    return best_labels, final_k, score, multi_k


def classify(
    transients: list[TransientFeatures],
    embeddings: np.ndarray,
    cluster_k_max: int = DEFAULT_CLUSTER_K_MAX,
) -> tuple[list[ClassifiedTransient], int, float]:
    if not transients:
        return [], 0, 0.0

    if embeddings.shape[0] != len(transients):
        raise ValueError(
            f"embeddings rows ({embeddings.shape[0]}) must match "
            f"number of transients ({len(transients)})"
        )

    energies = np.array([t.energy for t in transients])
    centroids = np.array([t.centroid_hz for t in transients])
    durations = np.array([t.duration for t in transients])
    pitches = np.array([
        t.pitch_hz for t in transients
        if not np.isnan(t.pitch_hz) and t.pitch_confidence >= PITCH_CONFIDENCE_FLOOR
    ])

    holistic, chosen_k, silhouette, multi_k = _holistic_clusters(
        embeddings, centroids, cluster_k_max
    )

    pitch_thresh    = _tercile_thresholds(pitches)
    centroid_thresh = _tercile_thresholds(centroids)
    energy_thresh   = _tercile_thresholds(energies)
    duration_thresh = _tercile_thresholds(durations)

    out = []
    for i, t in enumerate(transients):
        if np.isnan(t.pitch_hz) or t.pitch_confidence < PITCH_CONFIDENCE_FLOOR:
            pitch_bucket = "unpitched"
        else:
            pitch_bucket = _tercile_bucket(t.pitch_hz, pitch_thresh, ("low", "mid", "high"))

        out.append(
            ClassifiedTransient(
                features=t,
                pitch_bucket=pitch_bucket,
                brightness_bucket=_tercile_bucket(t.centroid_hz, centroid_thresh, ("dark", "mid", "bright")),
                energy_bucket=_tercile_bucket(t.energy, energy_thresh, ("soft", "medium", "loud")),
                duration_bucket=_tercile_bucket(t.duration, duration_thresh, ("short", "medium", "long")),
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
