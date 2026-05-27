---
description: Update the Processing sketch constants to use an analyzed track. Usage: /configure-sketch <stem_or_path>
---

Update `processing/SynchronizerVis/SynchronizerVis.pde` to point at a different track. Arguments: $ARGUMENTS

## Steps

### 1. Determine the stem
Accept any of these argument forms and strip to just the bare stem:
- Bare stem: `04_Krib`
- CSV path: `out/04_Krib/events.csv` or `processing/SynchronizerVis/data/04_Krib/events.csv`
- Audio path: `audio/04_Krib.flac` or `04_Krib.wav`

Strip the directory and extension to get the stem (e.g. `04_Krib`). If the path contains `events.csv` as the filename, use the parent directory name as the stem.

### 2. Verify required files exist in `processing/SynchronizerVis/data/<stem>/`
Check for:
- `<stem>/track.wav` — audio for Processing Sound
- `<stem>/events.csv` — events CSV

If either is missing, stop and tell the user. Suggest running `/analyze-track <audio_file>` first.

### 3. Detect N_TIMBRE_CLUSTERS from the events CSV
```
python -c "
import csv
rows = list(csv.DictReader(open('processing/SynchronizerVis/data/<stem>/events.csv')))
ti = max(int(r['timbre_cluster']) for r in rows if r.get('timbre_cluster','').strip()) + 1
print(ti)
"
```

`N_TRANSIENT_CLUSTERS` is always 8 — never change it.

### 4. Edit `processing/SynchronizerVis/SynchronizerVis.pde`
Only two constants ever need changing — use targeted Edit calls:

```processing
final String TRACK            = "<stem>";
final int    N_TIMBRE_CLUSTERS = <detected>;
```

Do not change any other lines.

### 5. Report
List each constant that changed (old → new value). Remind the user to reload the Processing sketch.
