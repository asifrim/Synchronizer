---
description: Run the synchronizer audio analysis pipeline on a track and copy all outputs to the Processing sketch data folder. Usage: /analyze-track <audio_file> [extra flags]
---

Run the synchronizer audio analysis pipeline. Arguments: $ARGUMENTS

## Steps

### 1. Parse arguments
The first argument is the path to the audio file (required). Everything after it is passed through verbatim as extra flags to the synchronizer CLI (e.g. `--timbre-clusters 8 --percussive --melody --n-transient-clusters 4`).

Verify the audio file exists. Derive the stem: basename of the file without extension.

### 2. Activate the virtual environment
```
source /mnt/e/Synchronizer/.venv/bin/activate
```

### 3. Run the synchronizer pipeline
```
synchronizer "<audio_file>" -o "out/<stem>.csv" [extra_flags]
```
Stream stdout/stderr so progress is visible. The pipeline produces:
- `out/<stem>.csv` — per-transient events (required)
- `out/<stem>_waveform.csv`
- `out/<stem>_segments.csv`
- `out/<stem>_grid.csv`
- `out/<stem>_tempo.csv`
- `out/<stem>_<stem>_melody.csv` files if `--melody` was passed

If the pipeline fails, stop here and show the error.

### 4. Convert to WAV for Processing
Processing Sound does not support FLAC or MP3. If the input is not already a WAV, convert it:

```python
import librosa, soundfile as sf
y, sr = librosa.load("<audio_file>", sr=None, mono=False)
sf.write("processing/SynchronizerVis/data/<stem>.wav",
         y.T if y.ndim == 2 else y, sr, subtype="PCM_16")
```

Run this inline with `python -c "..."` using the activated venv. If the input is already `.wav`, copy it directly to `processing/SynchronizerVis/data/<stem>.wav` instead.

### 5. Copy generated CSVs to the Processing sketch data folder
Copy every file that exists (skip silently if absent):
- `out/<stem>.csv`
- `out/<stem>_waveform.csv`
- `out/<stem>_segments.csv`
- `out/<stem>_grid.csv`
- `out/<stem>_tempo.csv`
- `out/<stem>_*_melody.csv` (glob — any melody files)

Destination: `processing/SynchronizerVis/data/`

Use `cp` for each file. Show which files were copied.

### 5b. Copy Demucs stem WAVs to the Processing sketch data folder
Demucs stems live under `stems/htdemucs/<stem>/`. For each of the four stems
(`drums`, `vocals`, `bass`, `other`), if the source WAV exists copy it:

```
stems/htdemucs/<stem>/drums.wav  →  processing/SynchronizerVis/data/<stem>_drums.wav
stems/htdemucs/<stem>/vocals.wav →  processing/SynchronizerVis/data/<stem>_vocals.wav
stems/htdemucs/<stem>/bass.wav   →  processing/SynchronizerVis/data/<stem>_bass.wav
stems/htdemucs/<stem>/other.wav  →  processing/SynchronizerVis/data/<stem>_other.wav
```

Skip silently if a source file is absent. Show which files were copied.

### 6. Report summary
- How many transient events were detected (count rows in the CSV, minus the header).
- Which sidecar files were produced.
- The detected `N_TRANSIENT_CLUSTERS` and `N_TIMBRE_CLUSTERS` values (read the max value of `transient_cluster` and `timbre_cluster` columns in the CSV + 1).
- Remind the user to run `/configure-sketch <stem>` to update the Processing sketch constants.
