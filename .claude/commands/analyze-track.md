---
description: Run the synchronizer audio analysis pipeline on a track and copy all outputs to the Processing sketch data folder. Usage: /analyze-track <audio_file> [extra flags]
---

Run the synchronizer audio analysis pipeline. Arguments: $ARGUMENTS

## Steps

### 1. Parse arguments
The first argument is the path to the audio file (required). Everything after it is passed through verbatim as extra flags to the synchronizer CLI (e.g. `--timbre-clusters 8 --percussive`).

Verify the audio file exists. Derive two name forms from the file:
- **`audio_basename`** — filename without extension, spaces preserved (e.g. `08 Julie and Candy`). Used for the Demucs cache path.
- **`stem`** — same but spaces replaced by underscores (e.g. `08_Julie_and_Candy`). Used for output folders and the sketch constant.

### 2. Activate the virtual environment
```
source /mnt/e/Synchronizer/.venv/bin/activate
```

### 3. Run the synchronizer pipeline
Always include `--melody` so Demucs stem separation and per-stem melody detection run for every track.

```
synchronizer "<audio_file>" -o "out/<stem>" --melody [extra_flags]
```

Using a directory as `-o` writes canonical filenames inside a per-track folder:
- `out/<stem>/events.csv` — per-transient events
- `out/<stem>/waveform.csv`
- `out/<stem>/segments.csv`
- `out/<stem>/grid.csv`
- `out/<stem>/tempo.csv`
- `out/<stem>/vocals_melody.csv`, `out/<stem>/bass_melody.csv`, `out/<stem>/other_melody.csv`
- `out/<stem>/vocals_waveform.csv`, `out/<stem>/bass_waveform.csv`, `out/<stem>/other_waveform.csv`

Stream stdout/stderr so progress is visible. If the pipeline fails, stop here and show the error.

### 3b. Write the drums waveform
`--melody` triggers a full 4-stem Demucs separation (drums included), but only writes waveforms for the melodic stems. Write the drums waveform separately from the cached stem:

```python
from synchronizer.waveform import write_waveform
from pathlib import Path
drum_stem = Path('stems/htdemucs/<audio_basename>/drums.wav')
out_path  = Path('out/<stem>/drums_waveform.csv')
if drum_stem.exists():
    write_waveform(drum_stem, out_path)
    print(f'drums waveform -> {out_path}')
```

Run inline with `python -c "..."` using the activated venv.

### 4. Convert to WAV for Processing
Processing Sound does not support FLAC or MP3. Convert or copy the audio to the track folder:

```python
import librosa, soundfile as sf
y, sr = librosa.load("<audio_file>", sr=None, mono=False)
sf.write("processing/SynchronizerVis/data/<stem>/track.wav",
         y.T if y.ndim == 2 else y, sr, subtype="PCM_16")
```

Run this inline with `python -c "..."` using the activated venv. If the input is already `.wav`, copy it directly instead.

### 5. Copy CSVs and waveforms to the Processing sketch data folder
Create the destination directory if needed:
```
mkdir -p processing/SynchronizerVis/data/<stem>
```

Copy every file that exists (skip silently if absent):
- `out/<stem>/events.csv`
- `out/<stem>/waveform.csv`
- `out/<stem>/segments.csv`
- `out/<stem>/grid.csv`
- `out/<stem>/tempo.csv`
- `out/<stem>/*_melody.csv` (glob)
- `out/<stem>/*_waveform.csv` (glob — includes drums_waveform, stem waveforms)

Destination: `processing/SynchronizerVis/data/<stem>/`

### 5b. Copy Demucs stem WAVs to the Processing sketch data folder
Stems live at `stems/htdemucs/<audio_basename>/` (note: spaces preserved, not underscores).
For each of `drums`, `vocals`, `bass`, `other`, if the source WAV exists copy it:

```
stems/htdemucs/<audio_basename>/drums.wav  →  processing/SynchronizerVis/data/<stem>/drums.wav
stems/htdemucs/<audio_basename>/vocals.wav →  processing/SynchronizerVis/data/<stem>/vocals.wav
stems/htdemucs/<audio_basename>/bass.wav   →  processing/SynchronizerVis/data/<stem>/bass.wav
stems/htdemucs/<audio_basename>/other.wav  →  processing/SynchronizerVis/data/<stem>/other.wav
```

Skip silently if absent.

### 6. Update the sketch constants
Edit `processing/SynchronizerVis/SynchronizerVis.pde`. Only two constants ever need changing:

```processing
final String TRACK            = "<stem>";
final int    N_TIMBRE_CLUSTERS = <detected>;
```

Detect `N_TIMBRE_CLUSTERS` from the CSV:
```
python -c "
import csv
rows = list(csv.DictReader(open('processing/SynchronizerVis/data/<stem>/events.csv')))
ti = max(int(r['timbre_cluster']) for r in rows if r.get('timbre_cluster','').strip()) + 1
print(ti)
"
```

`N_TRANSIENT_CLUSTERS` is always 8 — do not change it.

### 7. Report summary
- How many transient events were detected.
- Which sidecar files were produced.
- Remind the user to reload the Processing sketch.
