"""Melodic note detection on a separated stem.

The drum pipeline detects energy onsets and bucket-classifies each. This module
is its melodic counterpart: track frame-wise pitch on a melodic stem, then cut
the contour at *pitch gradients* (pitch jumps + voiced/unvoiced edges) to give
discrete note events with explicit pitch labels (Hz / MIDI / note name).

The pipeline:

1. Load the stem (downsampled to ``LOAD_SR`` — pyin is slow, and 22 kHz keeps
   pitch detection accurate well past any musical fundamental).
2. ``librosa.pyin`` with a stem-appropriate ``fmin/fmax`` range. Narrowing the
   range speeds pyin up significantly and suppresses octave errors.
3. ``_segment_notes`` groups voiced frames into notes: a new frame extends the
   current note if its pitch sits within ``SEMITONE_TOLERANCE`` semitones of the
   note's running pitch, otherwise it starts a new note. Unvoiced gaps shorter
   than ``UNVOICED_FRAME_TOLERANCE`` are bridged so pyin's brief flicker doesn't
   chop sustained notes; longer gaps end the note.
4. Drop notes shorter than ``MIN_NOTE_DURATION`` — those are pyin glitches, not
   musical events.
5. For each surviving note, emit ``start_time, end_time, pitch_hz, pitch_midi,
   note_name, confidence``. The CSV schema is a downstream contract; append
   columns rather than reordering.
"""
from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path

import librosa
import numpy as np


LOAD_SR = 22050           # pyin scales with sample rate; 22 kHz is plenty for F0
HOP_LENGTH = 512          # ~23 ms per frame at 22 kHz
SEMITONE_TOLERANCE = 0.5  # half a semitone — frames within this of the running pitch stay in the note
MIN_NOTE_DURATION = 0.07  # drop sub-70 ms notes (pyin flicker, not musical)
UNVOICED_FRAME_TOLERANCE = 2   # bridge gaps of up to N unvoiced frames inside a note
VOICED_PROB_FLOOR = 0.30  # treat pyin probabilities below this as effectively unvoiced

# Per-stem pitch search ranges. Narrowing pyin to the stem's plausible range is
# the single biggest accuracy + speed win — wide ranges invite octave errors,
# especially on noisy "other" content.
PITCH_RANGES = {
    "bass":   ("C1", "C5"),    # 33 - 523 Hz; covers bass guitar, sub bass
    "vocals": ("E2", "C6"),    # 82 - 1047 Hz; covers bass to soprano
    "other":  ("C2", "C7"),    # full melodic range; "other" varies wildly
}


@dataclass
class Note:
    start_time: float
    end_time: float
    pitch_hz: float
    pitch_midi: int
    note_name: str         # e.g. "C4", "F#3"
    confidence: float      # mean voiced probability across the note's frames


def detect_notes(audio_path: str | Path, stem_name: str) -> list[Note]:
    if stem_name not in PITCH_RANGES:
        raise ValueError(f"unknown stem '{stem_name}'; expected one of {list(PITCH_RANGES)}")
    fmin_note, fmax_note = PITCH_RANGES[stem_name]
    fmin = float(librosa.note_to_hz(fmin_note))
    fmax = float(librosa.note_to_hz(fmax_note))

    y, sr = librosa.load(str(Path(audio_path)), sr=LOAD_SR, mono=True)
    f0, _voiced_flag, voiced_prob = librosa.pyin(
        y, sr=sr, hop_length=HOP_LENGTH, fmin=fmin, fmax=fmax,
    )
    times = librosa.frames_to_time(np.arange(len(f0)), sr=sr, hop_length=HOP_LENGTH)
    frame_dur = HOP_LENGTH / sr
    return _segment_notes(f0, voiced_prob, times, frame_dur)


def _segment_notes(
    f0: np.ndarray, voiced_prob: np.ndarray, times: np.ndarray, frame_dur: float
) -> list[Note]:
    notes: list[Note] = []

    # State for the in-progress note.
    start_idx: int | None = None
    pitches: list[float] = []
    probs: list[float] = []
    ref_midi: float = 0.0      # running pitch reference for the gradient test
    last_voiced_idx: int = -1
    unvoiced_run: int = 0

    def midi_of(hz: float) -> float:
        return 69.0 + 12.0 * np.log2(hz / 440.0)

    def flush(end_idx: int) -> None:
        nonlocal start_idx, pitches, probs, ref_midi
        if start_idx is None or not pitches:
            return
        t0 = float(times[start_idx])
        t1 = float(times[end_idx]) + frame_dur
        if t1 - t0 >= MIN_NOTE_DURATION:
            median_hz = float(np.median(pitches))
            midi = int(round(librosa.hz_to_midi(median_hz)))
            notes.append(Note(
                start_time=t0,
                end_time=t1,
                pitch_hz=median_hz,
                pitch_midi=midi,
                # unicode=False emits ASCII '#' instead of '♯' so Processing's
                # default font (no Unicode sharp glyph) renders the name cleanly.
                note_name=str(librosa.midi_to_note(midi, unicode=False)),
                confidence=float(np.mean(probs)),
            ))
        start_idx = None
        pitches = []
        probs = []

    for i in range(len(f0)):
        hz = f0[i]
        prob = float(voiced_prob[i]) if not np.isnan(voiced_prob[i]) else 0.0
        is_voiced = not np.isnan(hz) and prob >= VOICED_PROB_FLOOR

        if is_voiced:
            unvoiced_run = 0
            this_midi = midi_of(float(hz))
            if start_idx is None:
                start_idx = i
                ref_midi = this_midi
                pitches = [float(hz)]
                probs = [prob]
            elif abs(this_midi - ref_midi) > SEMITONE_TOLERANCE:
                # Pitch gradient too large — end the old note (at the last
                # voiced frame), start a new one here.
                flush(last_voiced_idx)
                start_idx = i
                ref_midi = this_midi
                pitches = [float(hz)]
                probs = [prob]
            else:
                pitches.append(float(hz))
                probs.append(prob)
                # Refresh the reference over the first few frames so a slightly
                # mis-detected attack frame doesn't anchor the whole note.
                if 2 <= len(pitches) <= 6:
                    ref_midi = float(np.median([midi_of(p) for p in pitches]))
            last_voiced_idx = i
        else:
            unvoiced_run += 1
            # Bridge brief unvoiced flicker; longer gaps close the note.
            if start_idx is not None and unvoiced_run > UNVOICED_FRAME_TOLERANCE:
                flush(last_voiced_idx)

    # Close any note still in progress at end-of-track.
    if start_idx is not None:
        flush(last_voiced_idx if last_voiced_idx >= start_idx else start_idx)
    return notes


def write_notes(notes: list[Note], out_path: str | Path) -> None:
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["start_time", "end_time", "pitch_hz", "pitch_midi", "note_name", "confidence"])
        for n in notes:
            w.writerow([
                f"{n.start_time:.6f}",
                f"{n.end_time:.6f}",
                f"{n.pitch_hz:.4f}",
                n.pitch_midi,
                n.note_name,
                f"{n.confidence:.4f}",
            ])
