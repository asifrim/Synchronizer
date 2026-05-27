# Synchronizer

A CLI tool that ingests an audio file, detects transients (onsets), extracts per-transient features, classifies each transient with bucket labels relative to the track, and writes CSVs consumed by a Processing 4 visualizer and TouchDesigner patches.

## Installation

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

Optional extras:

```bash
pip install -e ".[demucs]"   # Demucs stem separation for --drums and --melody
```

## Usage

```bash
synchronizer path/to/track.flac -o out/track_name
```

Passing a directory as `-o` (no `.csv` extension) writes all output files inside it with canonical names (`events.csv`, `waveform.csv`, etc.). The old form `-o out/track.csv` is still accepted and uses the `<stem>_<sidecar>.csv` naming convention.

Or without installing the entry point:

```bash
python -m synchronizer.cli path/to/track.flac -o out/track_name
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-o` | required | Output CSV path |
| `--percussive` | off | Run HPSS first and detect onsets on the percussive component |
| `--drums` | off | Separate drum stem via Demucs before detection (requires `[demucs]`) |
| `--delta` | — | Onset peak-pick threshold (lower = more onsets) |
| `--wait` | — | Minimum gap between onsets in frames, within a band |
| `--no-multi-band` | off | Disable multi-band detection (single wideband envelope) |
| `--merge-tolerance-ms` | 30 | Cross-band merge window in milliseconds |
| `--timbre-clusters` | 6 | k for k-means MFCC timbre clustering |
| `--n-segments` | 12 | Target structural segments |
| `--n-segment-labels` | 4 | Distinct section labels (repeated sections share one) |
| `--no-segments` | off | Skip structural segmentation |
| `--n-tempo-segments` | 8 | Target tempo plateaus |
| `--no-tempo-segments` | off | Skip tempo-shift detection |
| `--no-grid` | off | Skip metronome grid |
| `--melody` | off | Run pyin note detection on separated melodic stems |
| `--melody-stems` | vocals,bass,other | Comma-separated Demucs stems to analyze for melody |

## Pipeline

Four stages with no shared state — each takes the previous stage's output:

1. **Onset detection** (`detect.py`) — SuperFlux onset detection on the mel-spectrogram spectral flux with a frequency-direction max filter (`max_size=3`). Multi-band by default: splits mel bins into lows/mids/highs, runs independent peak picking per band, then merges hits within `merge_tolerance_ms`. Catches quiet hi-hats masked by simultaneous loud kicks.

2. **Feature extraction** (`features.py`) — for each onset, slices a window (onset to next onset, 50 ms–1 s) and computes RMS, spectral centroid/rolloff/bandwidth, ZCR, MFCCs, and a pyin-based pitch estimate with confidence.

3. **Classification** (`classify.py`) — bucket labels computed as per-track terciles (low/mid/high, dark/mid/bright, soft/medium/loud, short/medium/long). Labels describe a transient *relative to its track*. Timbre clusters from k-means on standardized MFCC vectors, remapped by ascending mean spectral centroid so cluster 0 = darkest. Holistic transient clusters are computed for every k from 2 to 8 simultaneously; the silhouette-optimal result is stored in `transient_cluster` and all fixed-k results in `transient_cluster_k2`..`transient_cluster_k8`.

4. **CSV output** (`output.py`) — flat CSV, one row per transient. The column schema is a downstream contract — append columns rather than reordering.

Sidecar analyses run off the original mix (not the four-stage pipeline):

- **Waveform peaks** — `<stem>_waveform.csv` for the visualizer thumbnail
- **Structural segments** — `<stem>_segments.csv` (beat-sync MFCCs → agglomerative segmentation → k-means section labels; columns: `start_time, end_time, label, tempo_bpm`)
- **Tempo plateaus** — `<stem>_tempo.csv` (tempogram → agglomerative segmentation → merge adjacent regions within 4% BPM; columns: `start_time, end_time, tempo_bpm`)
- **Metronome grid** — `<stem>_grid.csv` (beat-anchored quarter/8th/16th/32nd subdivisions; columns: `time, division, beat, phase`)
- **Melody notes** — `<stem>_<voice>_melody.csv` per stem, from pyin on separated Demucs stems (requires `--melody` and `[demucs]`; columns: `start_time, end_time, pitch_hz, pitch_midi, note_name, confidence`)

## Output files

Given `-o out/my_track` (directory form), the pipeline writes:

```
out/my_track/events.csv         # per-transient events (required)
out/my_track/waveform.csv       # time, peak  (waveform thumbnail)
out/my_track/segments.csv       # song structure sections
out/my_track/grid.csv           # metronome grid ticks
out/my_track/tempo.csv          # tempo plateaus
out/my_track/vocals_melody.csv  # melody notes, vocals stem (--melody)
out/my_track/bass_melody.csv    # melody notes, bass stem   (--melody)
out/my_track/other_melody.csv   # melody notes, other stem  (--melody)
```

The old flat form `-o out/my_track.csv` is still accepted; sidecars are then written as `out/my_track_waveform.csv` etc.

## Processing 4 visualizer

`processing/SynchronizerVis/` is a Processing 4 sketch that plays the audio and shows:

- **Event grid** — transient events drawn as ADSR envelope curves, each event's peak height scaled by its quantile-normalized RMS energy within its cluster. The active k-clustering determines which cluster color each event takes.
- **Melody panel** — per-stem piano roll rows with chroma-colored note bars
- **Metronome panel** — 1/4, 1/8, 1/16, 1/32 rows; each tick flashes as the playhead crosses it
- **Waveform strip** — full-track peak envelope drawn upward from baseline, current page highlighted, segment color bands
- **ADSR panel** (right side) — 8 cluster panels in a compact layout. A k-selector strip at the top switches between k=2..8; panels for clusters ≥ active k are greyed out. Each active panel shows an envelope curve, A/D/S/R sliders, and a live CC level meter.

### Setup

1. Run the analyzer and copy output files:
   ```
   /analyze-track path/to/track.flac
   ```
   This runs the pipeline, converts to WAV, and copies everything to `processing/SynchronizerVis/data/`.

2. Update sketch constants (or use `/configure-sketch track`). Only two lines ever change:
   ```processing
   final String TRACK            = "my_track";
   final int    N_TIMBRE_CLUSTERS = 6;   // from --timbre-clusters
   // Everything else is derived from TRACK — do not edit
   ```

3. Open the sketch in Processing 4 IDE and run. On first run, install the Sound library via Sketch → Import Library → Add Library.

### Controls

| Key / gesture | Action |
|---------------|--------|
| `Space` | Play / pause |
| `←` / `→` | Seek one page back / forward |
| `r` | Seek to start |
| `l` | Toggle loop — loops the current 4-second page; press again to continue |
| `q` | Toggle grid snap (snaps events to nearest 1/32 tick within 30 ms) |
| `-` / `=` | Decrease / increase playback speed (0.25× steps, 0.25×–2.0×) |
| `m` | Toggle MIDI output |
| `Ctrl/Cmd+S` | Save edited events to versioned CSV |
| `0`–`9` | Reassign hovered event's transient cluster |
| Click stem label | Switch audio playback to that stem (Mix / Percussion / Vocals / Bass / Other) |
| Left-click event | Toggle disabled (excluded from saved CSV) |
| Shift+left-click | Preview: play from event onset for its duration, then stop |
| Right-drag event cell | Drag up/down to reassign bucket value for that row |
| Click k-selector (panel) | Switch active clustering to k=2..8 |
| Drag A/D/S/R slider | Reshape envelope for that cluster |

### Stem playback

Clickable pill labels above the event grid (Mix / Percussion / Vocals / Bass / Other) switch the audio between the full mix and Demucs-separated stems. Stems must exist in the `data/` folder; `/copy-stems` copies them without re-running the full analysis.

## MIDI output

The sketch sends per-cluster ADSR envelopes as 7-bit CC values via `javax.sound.midi`. Create a loopMIDI virtual port named `loopMIDI` (or update `MIDI_PORT_NAME` in `SynchronizerVis.pde`). Cluster `i` maps to CC `BASE_CC + i` on MIDI channel 1. Only clusters within the active k are sent; the rest hold at 0. ADSR settings are saved to `<stem>_adsr.csv` in the sketch `data/` folder and reloaded on the next run.

## Claude Code project skills

Three slash commands are available inside Claude Code:

### `/analyze-track <audio_file> [flags]`

Runs the full pipeline on an audio file, converts it to WAV, copies all output CSVs and Demucs stems to `processing/SynchronizerVis/data/`, and updates the sketch constants.

```
/analyze-track audio/my_track.flac --timbre-clusters 8 --melody
```

### `/configure-sketch <stem>`

Updates the constants at the top of `SynchronizerVis.pde` to point at the given track and auto-detects `N_TIMBRE_CLUSTERS` from the CSV. `N_TRANSIENT_CLUSTERS` is always 8 and is left unchanged.

```
/configure-sketch my_track
```

### `/copy-stems <stem>`

Copies Demucs stems for an already-analyzed track from the stems cache to `processing/SynchronizerVis/data/` without re-running separation or analysis.

```
/copy-stems 04_Krib
```

## Tests

```bash
pytest                          # full suite
pytest tests/test_smoke.py::test_pipeline -v
```

The smoke test synthesizes a click-track in memory — no audio fixtures required.

## Notes

- `librosa` is the only audio-analysis dependency by design.
- `pyin` is the slowest step; melody analysis adds 30–60 s per stem on CPU on top of multi-minute Demucs separation.
- Demucs is optional (`pip install -e ".[demucs]"`). It is imported lazily so the rest of the pipeline works without PyTorch installed.
- The CSV column order is a downstream contract. Append new columns; never reorder.
