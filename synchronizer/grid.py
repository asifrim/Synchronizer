"""Metronome grid: beat-anchored note-subdivision ticks.

Given the beat positions detected for the mix, emit a regular pulse grid at
several note values (quarter / 8th / 16th / 32nd). Each beat interval is
subdivided evenly, so the grid follows the track's tempo — the beats are spaced
by the actual local tempo, so tempo shifts are absorbed for free — and stays
phase-locked to the music rather than drifting off a single fixed BPM.
Consumed by the Processing visualizer as a metronome display.
"""
from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path

import numpy as np

DEFAULT_DIVISIONS = (4, 8, 16, 32)


@dataclass
class GridTick:
    time: float
    division: int    # note value: 4 = quarter, 8 = eighth, 16, 32
    beat: int         # index of the beat interval this tick falls in
    phase: int        # subdivision index within the beat; 0 = on the beat


def build_grid(beat_times, divisions=DEFAULT_DIVISIONS) -> list[GridTick]:
    """Subdivide each beat interval into `divisions` pulses.

    For division d, there are d/4 evenly-spaced ticks per beat (quarter = 1,
    8th = 2, 16th = 4, 32nd = 8); phase 0 of each lands on the beat, so each
    coarser grid is a subset of the finer ones. The final beat has no following
    interval to subdivide, so it contributes only an on-beat tick per division.
    """
    bt = np.asarray(list(beat_times), dtype=float)
    ticks: list[GridTick] = []
    if bt.size < 2:
        return ticks
    for bi in range(bt.size - 1):
        t0, t1 = float(bt[bi]), float(bt[bi + 1])
        span = t1 - t0
        if span <= 0:
            continue
        for d in divisions:
            subs = d // 4
            for j in range(subs):
                ticks.append(GridTick(t0 + span * j / subs, d, bi, j))
    last = float(bt[-1])
    for d in divisions:
        ticks.append(GridTick(last, d, int(bt.size - 1), 0))
    ticks.sort(key=lambda t: (t.time, t.division))
    return ticks


def write_grid(ticks, out_path) -> None:
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "division", "beat", "phase"])
        for t in ticks:
            w.writerow([f"{t.time:.6f}", t.division, t.beat, t.phase])
