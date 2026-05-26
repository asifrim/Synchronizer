"""Song structure segmentation.

Detects structural segments (verses, choruses, drops, ...) using
beat-synchronous MFCC features fed through librosa's agglomerative
segmentation, then clusters the segment-level features into a smaller number
of labels so repeated sections share a label (e.g. all chorus segments get
the same id).
"""
from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path

import librosa
import numpy as np
from sklearn.cluster import KMeans


@dataclass
class Segment:
    start_time: float
    end_time: float
    label: int   # cluster id; remapped so the track's first segment is label 0


def _merge_consecutive(segments: list[Segment]) -> list[Segment]:
    """Collapse runs of same-label segments into a single contiguous span.

    Agglomerative segmentation often splits one homogeneous section into
    several pieces that k-means then assigns the same label; emitted as
    separate rows they render as adjacent identical-colour bands in the
    visualizer and inflate the segment count. Merging keeps one row per
    contiguous section. Segments are contiguous by construction, so extending
    the previous segment's end_time loses no time.
    """
    if not segments:
        return segments
    merged = [Segment(segments[0].start_time, segments[0].end_time, segments[0].label)]
    for s in segments[1:]:
        if s.label == merged[-1].label:
            merged[-1].end_time = s.end_time
        else:
            merged.append(Segment(s.start_time, s.end_time, s.label))
    return merged


def detect_segments(
    audio_path: str | Path,
    n_segments: int = 12,
    n_labels: int = 4,
) -> list[Segment]:
    audio_path = Path(audio_path)
    y, sr = librosa.load(str(audio_path), sr=None, mono=True)
    duration = len(y) / sr

    tempo, beats = librosa.beat.beat_track(y=y, sr=sr, trim=False)
    if len(beats) < 4:
        return [Segment(0.0, duration, 0)]

    mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
    mfcc_sync = librosa.util.sync(mfcc, beats, aggregate=np.median)
    n_cols = mfcc_sync.shape[1]
    n_beats = len(beats)

    k = min(n_segments, n_cols)
    if k < 2:
        return [Segment(0.0, duration, 0)]

    # agglomerative returns boundary indices in [0, n_cols], where the
    # past-the-end value (n_cols) and any index >= len(beats) are treated
    # as "end of track" rather than a real beat.
    bounds_idx = np.sort(np.unique(librosa.segment.agglomerative(mfcc_sync, k=k)))
    if bounds_idx[0] > 0:
        bounds_idx = np.concatenate(([0], bounds_idx))

    beat_times = librosa.frames_to_time(beats, sr=sr)

    def idx_to_time(i: int) -> float:
        if i <= 0:
            return 0.0
        if i >= n_beats:
            return float(duration)
        return float(beat_times[i])

    n_seg = len(bounds_idx) - 1
    if n_seg < 1:
        return [Segment(0.0, duration, 0)]

    seg_features = []
    for i in range(n_seg):
        s = min(int(bounds_idx[i]), n_cols - 1)
        e = min(int(bounds_idx[i + 1]), n_cols)
        if e > s:
            seg_features.append(mfcc_sync[:, s:e].mean(axis=1))
        else:
            seg_features.append(mfcc_sync[:, s])
    seg_features = np.array(seg_features)

    n_labels_eff = min(n_labels, n_seg)
    if n_labels_eff <= 1:
        raw_labels = np.zeros(n_seg, dtype=int)
    else:
        km = KMeans(n_clusters=n_labels_eff, n_init=10, random_state=0)
        raw_labels = km.fit_predict(seg_features)

    # Stable label ids: first segment is label 0, next new label encountered
    # is 1, etc. Without this remap the section the user thinks of as "the
    # first one" might be cluster 3, which reads as random in the visualizer.
    remap: dict[int, int] = {}
    for c in raw_labels:
        if int(c) not in remap:
            remap[int(c)] = len(remap)
    labels = np.array([remap[int(c)] for c in raw_labels], dtype=int)

    segments: list[Segment] = []
    for i in range(n_seg):
        t0 = idx_to_time(int(bounds_idx[i]))
        t1 = idx_to_time(int(bounds_idx[i + 1]))
        t1 = min(t1, duration)
        if t1 > t0 + 0.05:
            segments.append(Segment(t0, t1, int(labels[i])))
    return _merge_consecutive(segments)


def write_segments(segments: list[Segment], out_path: str | Path) -> None:
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["start_time", "end_time", "label"])
        for s in segments:
            w.writerow([f"{s.start_time:.6f}", f"{s.end_time:.6f}", s.label])
