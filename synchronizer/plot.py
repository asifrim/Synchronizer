"""2-D UMAP cluster visualisations saved alongside the events CSV."""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

from .classify import MULTI_K_MAX_FIXED, MULTI_K_MIN, UMAP_N_NEIGHBORS


def write_umap_plots(
    embeddings: np.ndarray,
    classified: list,
    out_path: Path | str,
) -> None:
    """Project PANNs embeddings to 2-D via UMAP and save k=2..8 + best-k scatter plots."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from umap import UMAP

    out_path = Path(out_path)
    n = embeddings.shape[0]
    if n < 4:
        return

    print(f"[plot] computing 2-D UMAP for {n} embeddings…", file=sys.stderr)
    n_neighbors = min(UMAP_N_NEIGHBORS, n - 1)
    X2 = UMAP(
        n_components=2, min_dist=0.0, n_neighbors=n_neighbors, random_state=0,
    ).fit_transform(embeddings)

    # k=2..8 panels + best-k panel
    panels: list[tuple[str, np.ndarray]] = []
    for k in range(MULTI_K_MIN, MULTI_K_MAX_FIXED + 1):
        labels = np.array([getattr(c, f"transient_cluster_k{k}") for c in classified])
        panels.append((f"k={k}", labels))
    best = np.array([c.transient_cluster for c in classified])
    panels.append((f"best (k={int(best.max()) + 1})", best))

    ncols = 4
    nrows = 2
    fig, axes = plt.subplots(nrows, ncols, figsize=(16, 8))
    fig.patch.set_facecolor("#111")
    palette = plt.cm.tab10.colors

    for ax, (title, labels) in zip(axes.flat, panels):
        ax.set_facecolor("#111")
        for c in range(int(labels.max()) + 1):
            mask = labels == c
            ax.scatter(
                X2[mask, 0], X2[mask, 1],
                c=[palette[c % len(palette)]], s=12, alpha=0.8, linewidths=0,
                label=str(c),
            )
        ax.set_title(title, color="white", fontsize=10)
        ax.tick_params(colors="#666", labelsize=7)
        for spine in ax.spines.values():
            spine.set_edgecolor("#333")
        ax.legend(
            fontsize=6, framealpha=0.3, labelcolor="white",
            facecolor="#222", edgecolor="#444", markerscale=1.2, ncol=2,
        )

    for ax in axes.flat[len(panels):]:
        ax.set_visible(False)

    fig.suptitle("PANNs embeddings — 2-D UMAP by cluster", color="white", fontsize=12)
    plt.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="#111")
    plt.close(fig)
    print(f"[plot] saved {out_path}", file=sys.stderr)
