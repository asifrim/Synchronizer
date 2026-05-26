"""Song structure + tempo segmentation.

Two analyses, both run off the original mix:

* **Structural segments** (`detect_segments`): beat-synchronous MFCC features
  through librosa's agglomerative segmentation, then k-means over the
  segment-level features so repeated sections share a label (all choruses get
  the same id). Each segment is annotated with its tempo (`tempo_bpm`).
* **Tempo segments** (`detect_tempo_segments`): agglomerative segmentation on
  the *tempogram* so boundaries land where the rhythmic content changes, giving
  a tempo-homogeneous segmentation independent of the (timbral) structure above.

Both estimate BPM with `librosa.feature.tempo` and fold octave errors toward a
global tempo. `analyze_mix` loads the audio, onset envelope and global tempo
once so the two analyses share the work.
"""
from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path

import librosa
import numpy as np
from sklearn.cluster import KMeans

HOP_LENGTH = 512
# Tempo estimation needs a few bars of signal; below this a slice's autocorr
# peak is too noisy to trust, so we emit no BPM (empty CSV cell) instead.
MIN_TEMPO_SECONDS = 4.0
# Adjacent tempo segments whose BPMs differ by less than this fraction of the
# global tempo are merged — they're the same tempo split by clustering noise.
TEMPO_MERGE_TOLERANCE = 0.04


@dataclass
class Segment:
    start_time: float
    end_time: float
    label: int   # structural: cluster id (first segment = 0). tempo: ordinal.
    tempo_bpm: float | None = None  # None when the span is too short to estimate


@dataclass
class MixAnalysis:
    """Everything the segmenters + grid need, computed once off the original mix."""
    y: np.ndarray
    sr: int
    oenv: np.ndarray          # onset strength envelope (hop = self.hop)
    global_bpm: float         # whole-track tempo; octave-fold reference
    beats: np.ndarray         # beat frame indices (hop-based)
    beat_times: np.ndarray    # beat positions in seconds (the metronome anchor)
    hop: int = HOP_LENGTH


def analyze_mix(audio_path: str | Path, hop: int = HOP_LENGTH) -> MixAnalysis:
    y, sr = librosa.load(str(Path(audio_path)), sr=None, mono=True)
    oenv = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
    bpm = librosa.feature.tempo(
        onset_envelope=oenv, sr=sr, hop_length=hop, aggregate=np.median
    )
    _, beats = librosa.beat.beat_track(
        onset_envelope=oenv, sr=sr, hop_length=hop, trim=False
    )
    beat_times = librosa.frames_to_time(beats, sr=sr, hop_length=hop)
    return MixAnalysis(
        y=y, sr=sr, oenv=oenv, global_bpm=float(bpm[0]),
        beats=beats, beat_times=beat_times, hop=hop,
    )


def _fold_tempo(bpm: float, ref: float) -> float:
    """Move bpm to within a factor of sqrt(2) of ref by halving/doubling.

    Autocorrelation tempo estimation routinely lands an octave off (half- or
    double-time). Folding toward the track's global tempo fixes that: a segment
    read at double time snaps back, and genuine sub-octave differences (e.g. a
    140-BPM section in a 120-BPM track) sit inside the sqrt(2) band and are left
    untouched, so real tempo shifts survive. Triplet 2/3, 3/2 errors are not
    handled — they're rare in the 4/4 material this tool targets.
    """
    if bpm <= 0 or ref <= 0:
        return bpm
    while bpm < ref / 1.4142:
        bpm *= 2.0
    while bpm > ref * 1.4142:
        bpm /= 2.0
    return bpm


def _segment_bpm(
    oenv: np.ndarray, sr: int, hop: int, s: int, e: int, ref_bpm: float
) -> float | None:
    """Tempo of one onset-envelope frame slice, octave-folded toward ref_bpm.

    Returns None when the slice is shorter than MIN_TEMPO_SECONDS. ref_bpm is
    passed as the estimator's prior (start_bpm); librosa's default octave-wide
    prior disambiguates half/double without suppressing real sub-octave shifts.
    """
    if (e - s) * hop / sr < MIN_TEMPO_SECONDS:
        return None
    start = ref_bpm if ref_bpm and ref_bpm > 0 else 120.0
    bpm = float(librosa.feature.tempo(
        onset_envelope=oenv[s:e], sr=sr, hop_length=hop,
        start_bpm=start, aggregate=np.median,
    )[0])
    return _fold_tempo(bpm, ref_bpm) if ref_bpm and ref_bpm > 0 else bpm


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
    mix: MixAnalysis,
    n_segments: int = 12,
    n_labels: int = 4,
) -> list[Segment]:
    y, sr, hop = mix.y, mix.sr, mix.hop
    duration = len(y) / sr
    ref = mix.global_bpm or None

    beats = mix.beats
    if len(beats) < 4:
        return [Segment(0.0, duration, 0, ref)]

    mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
    mfcc_sync = librosa.util.sync(mfcc, beats, aggregate=np.median)
    n_cols = mfcc_sync.shape[1]
    n_beats = len(beats)

    k = min(n_segments, n_cols)
    if k < 2:
        return [Segment(0.0, duration, 0, ref)]

    # agglomerative returns boundary indices in [0, n_cols], where the
    # past-the-end value (n_cols) and any index >= len(beats) are treated
    # as "end of track" rather than a real beat.
    bounds_idx = np.sort(np.unique(librosa.segment.agglomerative(mfcc_sync, k=k)))
    if bounds_idx[0] > 0:
        bounds_idx = np.concatenate(([0], bounds_idx))

    beat_times = mix.beat_times

    def idx_to_time(i: int) -> float:
        if i <= 0:
            return 0.0
        if i >= n_beats:
            return float(duration)
        return float(beat_times[i])

    n_seg = len(bounds_idx) - 1
    if n_seg < 1:
        return [Segment(0.0, duration, 0, ref)]

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
    segments = _merge_consecutive(segments)

    # Annotate each (merged) segment with its tempo.
    for seg in segments:
        s = int(librosa.time_to_frames(seg.start_time, sr=sr, hop_length=hop))
        e = int(librosa.time_to_frames(seg.end_time, sr=sr, hop_length=hop))
        seg.tempo_bpm = _segment_bpm(mix.oenv, sr, hop, s, e, mix.global_bpm)
    return segments


def detect_tempo_segments(
    mix: MixAnalysis,
    n_tempo_segments: int = 8,
    merge_tolerance: float = TEMPO_MERGE_TOLERANCE,
) -> list[Segment]:
    """Segment the track by tempo. Boundaries come from agglomerative
    segmentation of the tempogram (so they land where the rhythmic profile
    shifts); each region's BPM comes from `librosa.feature.tempo`. Adjacent
    regions within `merge_tolerance` of each other (and too-short regions) are
    merged, so the result is one row per distinct tempo plateau. The `label`
    field carries a segment ordinal, not a category.
    """
    sr, hop, oenv, gbpm = mix.sr, mix.hop, mix.oenv, mix.global_bpm
    duration = len(mix.y) / sr

    def bpm_or_global(s: int, e: int) -> float | None:
        b = _segment_bpm(oenv, sr, hop, s, e, gbpm)
        if b is not None:
            return b
        return gbpm if gbpm > 0 else None

    tg = librosa.feature.tempogram(onset_envelope=oenv, sr=sr, hop_length=hop)
    n_frames = tg.shape[1]
    k = min(n_tempo_segments, n_frames)
    if k < 2 or gbpm <= 0:
        return [Segment(0.0, duration, 0, bpm_or_global(0, n_frames))]

    # Normalize per frame so clustering keys on the *shape* of the tempo
    # distribution (where the pulse is), not on raw onset-strength magnitude.
    tg_norm = librosa.util.normalize(tg, axis=0)
    bounds = np.sort(np.unique(librosa.segment.agglomerative(tg_norm, k=k)))
    bounds = bounds[bounds < n_frames]
    if bounds.size == 0 or bounds[0] > 0:
        bounds = np.concatenate(([0], bounds))
    bounds = np.append(bounds, n_frames)  # close the final region at end-of-track

    raw = []
    for i in range(len(bounds) - 1):
        s, e = int(bounds[i]), int(bounds[i + 1])
        if e > s:
            raw.append([s, e, _segment_bpm(oenv, sr, hop, s, e, gbpm)])

    # Merge neighbours within tolerance; absorb too-short regions (bpm None)
    # into the previous one rather than emitting an untrustworthy sliver.
    merged: list[list] = []
    for s, e, bpm in raw:
        prev = merged[-1] if merged else None
        if prev is not None and (
            bpm is None or prev[2] is None
            or abs(bpm - prev[2]) <= merge_tolerance * gbpm
        ):
            prev[1] = e
            if prev[2] is None:
                prev[2] = bpm
        else:
            merged.append([s, e, bpm])

    segments: list[Segment] = []
    for s, e, _ in merged:
        t0 = float(librosa.frames_to_time(s, sr=sr, hop_length=hop))
        t1 = min(float(librosa.frames_to_time(e, sr=sr, hop_length=hop)), duration)
        if t1 > t0 + 0.05:
            # Recompute BPM over the merged span for accuracy.
            segments.append(Segment(t0, t1, len(segments), bpm_or_global(s, e)))
    return segments or [Segment(0.0, duration, 0, bpm_or_global(0, n_frames))]


def _bpm_cell(bpm: float | None) -> str:
    return "" if bpm is None else f"{bpm:.2f}"


def write_segments(segments: list[Segment], out_path: str | Path) -> None:
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["start_time", "end_time", "label", "tempo_bpm"])
        for s in segments:
            w.writerow([f"{s.start_time:.6f}", f"{s.end_time:.6f}", s.label,
                        _bpm_cell(s.tempo_bpm)])


def write_tempo_segments(segments: list[Segment], out_path: str | Path) -> None:
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["start_time", "end_time", "tempo_bpm"])
        for s in segments:
            w.writerow([f"{s.start_time:.6f}", f"{s.end_time:.6f}",
                        _bpm_cell(s.tempo_bpm)])
