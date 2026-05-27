---
description: Copy Demucs stem WAVs for a track into the Processing sketch data folder. Usage: /copy-stems <stem_or_audio_path>
---

Copy pre-separated Demucs stem WAVs to `processing/SynchronizerVis/data/<stem>/`. Arguments: $ARGUMENTS

## Steps

### 1. Determine the stem name
Accept any of these forms and strip to the bare stem:
- Bare stem: `04_Krib`
- Audio path: `audio/04_Krib.flac`, `04_Krib.wav`
- CSV path: `out/04_Krib/events.csv`

Strip directory and extension. If the path ends in `events.csv`, use the parent directory name.

### 2. Locate the Demucs output directory
Stems live at `stems/htdemucs/<stem>/`. Verify this directory exists; if not, tell the user to run the separator first (e.g. `synchronizer <audio> --drums` or `synchronizer <audio> --melody`).

### 3. Copy each stem WAV that exists
For each of `drums`, `vocals`, `bass`, `other`:
- Source: `stems/htdemucs/<stem>/<name>.wav`
- Destination: `processing/SynchronizerVis/data/<stem>/<name>.wav`

Use `cp` for each. Skip silently if source absent. Show which files were copied.

### 4. Report
List the copied files. Remind the user to reload the Processing sketch if they haven't already.
