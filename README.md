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
synchronizer path/to/track.flac -o out/track.csv
```

Or without installing the entry point:

```bash
python -m synchronizer.cli path/to/track.flac -o out/track.csv
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
| `--n-transient-clusters` | — | k for holistic k-means clustering |
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

3. **Classification** (`classify.py`) — bucket labels computed as per-track terciles (low/mid/high, dark/mid/bright, soft/medium/loud, short/medium/long). Labels describe a transient *relative to its track*. Timbre clusters from k-means on standardized MFCC vectors, remapped by ascending mean spectral centroid so cluster 0 = darkest, k-1 = brightest.

4. **CSV output** (`output.py`) — flat CSV, one row per transient. The column schema is a downstream contract — append columns rather than reordering.

Sidecar analyses run off the original mix (not the four-stage pipeline):

- **Waveform peaks** — `<stem>_waveform.csv` for the visualizer thumbnail
- **Structural segments** — `<stem>_segments.csv` (beat-sync MFCCs → agglomerative segmentation → k-means section labels; columns: `start_time, end_time, label, tempo_bpm`)
- **Tempo plateaus** — `<stem>_tempo.csv` (tempogram → agglomerative segmentation → merge adjacent regions within 4% BPM; columns: `start_time, end_time, tempo_bpm`)
- **Metronome grid** — `<stem>_grid.csv` (beat-anchored quarter/8th/16th/32nd subdivisions; columns: `time, division, beat, phase`)
- **Melody notes** — `<stem>_<voice>_melody.csv` per stem, from pyin on separated Demucs stems (requires `--melody` and `[demucs]`; columns: `start_time, end_time, pitch_hz, pitch_midi, note_name, confidence`)

## Output files

Given `-o out/track.csv`, the pipeline writes:

```
out/track.csv               # per-transient events (required)
out/track_waveform.csv      # time, peak  (waveform thumbnail)
out/track_segments.csv      # song structure sections
out/track_grid.csv          # metronome grid ticks
out/track_tempo.csv         # tempo plateaus
out/track_vocals_melody.csv # melody notes, vocals stem (--melody)
out/track_bass_melody.csv   # melody notes, bass stem   (--melody)
out/track_other_melody.csv  # melody notes, other stem  (--melody)
```

## Processing 4 visualizer

`processing/SynchronizerVis/` is a Processing 4 sketch that plays the audio and shows:

- **Event grid** — 5 rows (pitch / brightness / energy / duration / timbre cluster), events positioned by `start_time` within the current page window, cells brightening on playhead hit
- **Melody panel** — per-stem piano roll rows with chroma-colored note bars
- **Metronome panel** — 1/4, 1/8, 1/16, 1/32 rows; each tick flashes as the playhead crosses it
- **Waveform strip** — full-track peak envelope, current page highlighted, segment color bands
- **ADSR panel** (right side) — per-cluster envelope curves with A/D/S/R sliders, LIN/EXP shape toggles, and a live CC level meter

### Setup

1. Copy output files to `processing/SynchronizerVis/data/`
2. Convert audio to WAV (Processing Sound does not support FLAC or MP3):
   ```bash
   /analyze-track path/to/track.flac
   ```
   or manually:
   ```python
   import librosa, soundfile as sf
   y, sr = librosa.load("track.flac", sr=None, mono=False)
   sf.write("processing/SynchronizerVis/data/track.wav",
            y.T if y.ndim == 2 else y, sr, subtype="PCM_16")
   ```
3. Update constants at the top of `SynchronizerVis.pde`:
   ```processing
   final String AUDIO_FILE  = "track.wav";
   final String CSV_FILE    = "track.csv";
   // ...
   final int N_TIMBRE_CLUSTERS    = 6;
   final int N_TRANSIENT_CLUSTERS = 2;
   ```
   Or use the skill: `/configure-sketch track`
4. Open the sketch in Processing 4 IDE and run. On first run, install the Sound library via Sketch → Import Library → Add Library.

### Controls

| Key | Action |
|-----|--------|
| `Space` | Play / pause |
| `←` / `→` | Seek one page |
| `r` | Seek to start |
| `q` | Toggle grid snap |
| `-` / `=` | Decrease / increase playback speed |
| `m` | Toggle MIDI output |
| `Ctrl/Cmd+S` | Save edited events to versioned CSV |
| `0`–`9` | Reassign hovered event's transient cluster |
| Left-click event | Toggle disabled |
| Shift+left-click | Play from event |
| Right-drag event | Reassign bucket in dragged row |

## MIDI output

The sketch sends per-cluster ADSR envelopes as 7-bit CC values via `javax.sound.midi`. Create a loopMIDI virtual port named `loopMIDI` (or update `MIDI_PORT_NAME` in `SynchronizerVis.pde`). Cluster `i` maps to CC `BASE_CC + i` on channel `MIDI_CHANNEL`. ADSR settings are saved to `<stem>_adsr.csv` in the sketch `data/` folder and loaded on the next run.

## Claude Code project skills

Two slash commands are available inside Claude Code:

### `/analyze-track <audio_file> [flags]`

Runs the full pipeline on an audio file, converts it to WAV, and copies all output CSVs to `processing/SynchronizerVis/data/`. Reports transient count and detected cluster dimensions.

```
/analyze-track audio/my_track.flac --timbre-clusters 8 --melody
```

### `/configure-sketch <stem>`

Updates the constants at the top of `SynchronizerVis.pde` to point at the given track and auto-detects cluster counts from the CSV.

```
/configure-sketch my_track
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
