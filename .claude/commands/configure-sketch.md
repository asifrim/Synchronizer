---
description: Update the Processing sketch constants to use an analyzed track. Usage: /configure-sketch <stem_or_path>
---

Update `processing/SynchronizerVis/SynchronizerVis.pde` to point at a different track. Arguments: $ARGUMENTS

## Steps

### 1. Determine the stem
Accept any of these argument forms and strip to just the bare stem:
- Bare stem: `04_Krib`
- CSV path: `out/04_Krib.csv` or `processing/SynchronizerVis/data/04_Krib.csv`
- Audio path: `audio/04_Krib.flac` or `04_Krib.wav`

Strip the directory and extension to get the stem (e.g. `04_Krib`).

### 2. Verify required files exist in `processing/SynchronizerVis/data/`
Check for:
- `<stem>.wav` — audio for Processing Sound
- `<stem>.csv` — events CSV

If either is missing, stop and tell the user. Suggest running `/analyze-track <audio_file>` first if the CSV is missing.

### 3. Detect cluster counts from the events CSV
Read `processing/SynchronizerVis/data/<stem>.csv` and compute:
- `N_TRANSIENT_CLUSTERS` = always **8** (the sketch always shows 8 ADSR panels; `activeK` controls how many are live)
- `N_TIMBRE_CLUSTERS` = max value in the `timbre_cluster` column + 1

Use Python for this (no venv needed — stdlib csv module only):
```
python -c "
import csv
rows = list(csv.DictReader(open('processing/SynchronizerVis/data/<stem>.csv')))
ti = max(int(r['timbre_cluster']) for r in rows if r.get('timbre_cluster','').strip()) + 1
print(ti)
"
```

### 4. Check which optional sidecar files exist
In `processing/SynchronizerVis/data/`, check for:
- `<stem>_segments.csv`
- `<stem>_grid.csv`
- `<stem>_vocals_melody.csv`, `<stem>_bass_melody.csv`, `<stem>_other_melody.csv`
- `<stem>_drums.wav`, `<stem>_vocals.wav`, `<stem>_bass.wav`, `<stem>_other.wav`

### 5. Edit `processing/SynchronizerVis/SynchronizerVis.pde`
Use the Edit tool to update the "Track / file config" block. Change exactly these lines:

```processing
final String AUDIO_FILE     = "<stem>.wav";
final String CSV_FILE       = "<stem>.csv";
final String WAVE_FILE      = "<stem>_waveform.csv";
final String SEGMENTS_FILE  = "<stem>_segments.csv";
final String GRID_FILE      = "<stem>_grid.csv";
final String[] MELODY_FILES = {
  "<stem>_vocals_melody.csv",
  "<stem>_bass_melody.csv",
  "<stem>_other_melody.csv",
};
final String STEM_DRUMS_FILE  = "<stem>_drums.wav";
final String STEM_VOCALS_FILE = "<stem>_vocals.wav";
final String STEM_BASS_FILE   = "<stem>_bass.wav";
final String STEM_OTHER_FILE  = "<stem>_other.wav";
```

And in the "Analysis / display config" block:
```processing
final int   N_TIMBRE_CLUSTERS    = <detected>;
```
`N_TRANSIENT_CLUSTERS` is always 8 — do not change it.

Use targeted Edit calls that match the old strings exactly. Do not change any other lines.

### 6. Report
List every constant that changed (old → new value). Remind the user to reload the Processing sketch for the changes to take effect.
