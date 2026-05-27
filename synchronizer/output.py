"""CSV output for Processing / TouchDesigner."""
from __future__ import annotations

import csv
from pathlib import Path

from .classify import ClassifiedTransient
from .features import N_MFCC


def write_csv(rows: list[ClassifiedTransient], path: str | Path) -> None:
    """Write one row per transient. Column order is stable and is the contract
    consumed by downstream Processing/TouchDesigner patches — do not rename or
    reorder columns without updating those patches."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    mfcc_cols = [f"mfcc_{i + 1}" for i in range(N_MFCC)]
    header = [
        "index", "start_time", "duration",
        "energy", "centroid_hz", "rolloff_hz", "bandwidth_hz", "zcr",
        "pitch_hz", "pitch_confidence",
        *mfcc_cols,
        "pitch_bucket", "brightness_bucket", "energy_bucket", "duration_bucket",
        "timbre_cluster",
        "transient_cluster",
    ]

    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for c in rows:
            t = c.features
            w.writerow([
                t.index,
                f"{t.start_time:.6f}",
                f"{t.duration:.6f}",
                f"{t.energy:.6f}",
                f"{t.centroid_hz:.3f}",
                f"{t.rolloff_hz:.3f}",
                f"{t.bandwidth_hz:.3f}",
                f"{t.zcr:.6f}",
                "" if t.pitch_hz != t.pitch_hz else f"{t.pitch_hz:.3f}",  # NaN -> empty
                f"{t.pitch_confidence:.4f}",
                *[f"{v:.6f}" for v in t.mfcc],
                c.pitch_bucket,
                c.brightness_bucket,
                c.energy_bucket,
                c.duration_bucket,
                c.timbre_cluster,
                c.transient_cluster,
            ])
