# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A CLI tool that ingests an audio file, detects transients (onsets), extracts per-transient features (timbre/pitch/duration/energy), classifies each transient with bucket labels relative to the track, and writes a CSV file (plus sidecar CSVs for the waveform thumbnail and song structure). The CSVs are consumed by Processing sketches and TouchDesigner patches — their schema is a stability contract (see below).

## Common commands

Install in editable mode with dev deps:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

Run the analyzer:

```bash
synchronizer path/to/track.flac -o out/track.csv
# or, without installing the entry point:
python -m synchronizer.cli path/to/track.flac -o out/track.csv
```

Useful flags: `--percussive` (HPSS first, detect on percussive component — good for drum-heavy material), `--delta` (onset peak-pick threshold; lower = more onsets), `--wait` (minimum gap between onsets in frames, *within a band*), `--no-multi-band` (disable multi-band detection), `--merge-tolerance-ms` (cross-band merge window, default 30), `--timbre-clusters` (k for k-means MFCC clustering, default 6), `--n-segments` (target structural segments, default 12), `--n-segment-labels` (distinct section labels — repeated sections share one, default 4), `--no-segments` (skip structural segmentation).

Run tests:

```bash
pytest                          # full suite
pytest tests/test_smoke.py::test_pipeline -v
```

## Architecture

The pipeline is a strict four-stage flow with no shared state — each stage takes the previous stage's output as input:

1. `detect.load_audio` + `detect.detect_onsets` — **SuperFlux + multi-band** onset detection. SuperFlux = mel-spectrogram spectral flux with a frequency-direction max filter (`max_size=3`), which sharpens peaks and suppresses decay-tail double-triggers. Multi-band (`multi_band=True` default) splits mel bins into thirds (lows / mids / highs), runs independent peak picking per band, then merges hits within `merge_tolerance_ms` (default 30 ms). This catches quiet hi-hats that would otherwise be masked by simultaneous loud kicks. `DetectionConfig` exposes all knobs the CLI passes through. `--no-multi-band` reverts to a single wideband envelope for debugging.
2. `features.extract_features` — for each onset, slices a window (from the onset to the next onset, capped at `MAX_SLICE_SECONDS = 1.0s`, floored at `MIN_SLICE_SECONDS = 0.05s`) and computes RMS, spectral centroid/rolloff/bandwidth, ZCR, MFCCs (mean across frames), and a pyin-based pitch estimate with confidence.
3. `classify.classify` — bucket labels (low/mid/high, dark/mid/bright, soft/medium/loud, short/medium/long) computed as **per-track terciles**, not absolute thresholds. Buckets describe a transient *relative to its track*, so "loud" on one file is not comparable to "loud" on another. Pitch bucketing only applies to transients with `pitch_confidence >= PITCH_CONFIDENCE_FLOOR` (0.5); the rest are labeled `unpitched`. **Timbre clusters** are produced by k-means on standardized MFCC vectors (default k=6); raw k-means cluster IDs are arbitrary so they're remapped to be ordered by ascending mean spectral centroid (cluster 0 = darkest group, k-1 = brightest). This gives stable, semantically ordered IDs across runs and across tracks of similar material.
4. `output.write_csv` — flat CSV, one row per transient. `waveform.write_waveform` writes a sibling `<csv_stem>_waveform.csv` (two columns: time, peak) derived from the *original* input file (not the separated stem), used by the Processing visualizer for the full-track thumbnail.

Two independent sidecar analyses run off the *original* input (not the four-stage transient pipeline, and not the separated stem): `waveform.write_waveform` (above) and `segment.detect_segments` (see below). Both key their output filename off the events-CSV stem.

`cli.py` wires the four stages together with argparse; it is the only module that performs I/O on the input path or output path.

### CSV schema is a contract

The header row defined in `output.write_csv` is consumed by external Processing/TouchDesigner patches. **Do not rename or reorder columns** without updating those downstream consumers. If you need to add information, append new columns at the end. Pitch column emits an empty string (not "nan") for unvoiced transients so TouchDesigner Table DATs handle missing values cleanly.

### Adding new features

To add a new per-transient feature: extend `TransientFeatures` in `features.py`, populate it in `extract_features`, and append a column at the end of the header + writer rows in `output.py`. If the feature is bucketable, add a quantile-based bucket in `classify.py` following the existing `_tercile_bucket` pattern.

To add a new classification scheme (e.g. k-means clustering on MFCCs for "timbre groups"), prefer adding a new field to `ClassifiedTransient` and a new column at the end of the CSV — don't replace the existing tercile buckets, since downstream patches may already depend on them.

## Processing visualizer

`processing/SynchronizerVis/SynchronizerVis.pde` is a Processing 4 sketch that plays the audio and flashes a 4-row grid of squares (pitch / brightness / energy / duration buckets) using the CSV.

- The sketch loads four files from its own `data/` directory: the audio (`AUDIO_FILE`), the events CSV (`CSV_FILE`), the waveform-peaks CSV (`WAVE_FILE`, auto-generated as `<csv_stem>_waveform.csv`), and the segments CSV (`SEGMENTS_FILE`, auto-generated as `<csv_stem>_segments.csv`). The segments file is optional — the sketch skips it gracefully if absent. To visualize a new track: drop all four into `processing/SynchronizerVis/data/` and update the constants at the top of the `.pde`. If you re-run the analyzer with a non-default `--timbre-clusters` or `--n-segment-labels`, also update `N_TIMBRE_CLUSTERS` / `N_SEGMENT_LABELS` to match.
- Layout: rows are annotation dimensions (pitch / brightness / energy / duration / timbre), columns are individual events positioned by `start_time` within an 8-second page window. Pages auto-advance with the playhead; ← / → seek by one page; space pauses. The waveform strip at the bottom shows the full-track peak envelope with the current page window highlighted and the playhead position marked; structural segments are drawn behind it as colored bands (one color per segment label), and the HUD names the current segment.
- **Processing's Sound library does not support FLAC.** Convert to WAV first:
  ```python
  import librosa, soundfile as sf
  y, sr = librosa.load("audio/track.flac", sr=None, mono=False)
  sf.write("processing/SynchronizerVis/data/track.wav", y.T if y.ndim == 2 else y, sr, subtype="PCM_16")
  ```
- First run will prompt to install the Sound library via Processing's Contribution Manager (Sketch → Import Library → Add Library → "Sound").
- Processing 4.x no longer ships `processing-java`, so the sketch can't be compile-checked from the command line — open it in the Processing IDE.

## Notes

- librosa is the only audio-analysis dependency by design. Don't pull in aubio/essentia unless there's a specific feature librosa can't provide.
- `pyin` is slow relative to the rest of the pipeline; if performance becomes an issue on long files, that's the first place to look.
- The smoke test in `tests/test_smoke.py` synthesizes a click-track in-memory so the suite needs no audio fixtures on disk.

## Song-structure segmentation

`segment.detect_segments` analyzes the *original mix* (never the drum stem — the harmonic changes that define verse/chorus live there) and writes a sibling `<csv_stem>_segments.csv` with columns `start_time, end_time, label`. The pipeline:

1. Beat-track the audio, then take **beat-synchronous median MFCCs** (one column per beat).
2. Run librosa's **agglomerative segmentation** to find `--n-segments` boundaries (default 12).
3. **k-means** cluster the per-segment mean-MFCC vectors into `--n-segment-labels` groups (default 4) so repeated sections (e.g. all choruses) share a label.
4. **Remap labels** so the track's first segment is always label 0 — raw cluster ids are arbitrary and would otherwise read as random in the visualizer. (Same rationale as the timbre-cluster remap, but ordered by appearance rather than by centroid.)
5. **Merge consecutive same-label segments** (`_merge_consecutive`) into one contiguous span, so the CSV holds one row per section rather than one per agglomerative boundary.

Short or beatless input (<4 beats, or fewer than 2 sync'd columns) collapses to a single full-length segment. `--no-segments` skips the step entirely.

Caveat: a short segment wedged *between* two same-label neighbors (e.g. a sub-second sliver labeled differently) survives the merge — that's residual clustering noise, not a contiguous run, so consecutive-merge can't reach it. If these become a problem, the fix is a minimum-duration pass that absorbs short segments into a neighbor, *not* a change to the merge logic.

Like the events CSV, this is a downstream contract: the Processing sketch reads it to draw section color bands. Append columns rather than reordering.

## Drum-stem separation (optional)

`--drums` runs Demucs to separate the drum stem before any onset detection, so the whole pipeline operates on a clean drums-only signal. Demucs is an optional dependency — install with `pip install -e ".[demucs]"`. The stem is cached under `stems/<model>/<basename>/drums.wav` (mirroring Demucs's own output layout); subsequent runs on the same file skip separation.

Demucs is heavy (PyTorch, ~1 GB model on first use, slow on CPU). Keep separation isolated in `synchronizer/separate.py` and import lazily — the rest of the pipeline must work without demucs/torch installed.
