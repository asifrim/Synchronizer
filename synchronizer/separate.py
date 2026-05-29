"""Stem separation via Demucs.

This is the only module that depends on demucs/torch. Import it lazily — the
rest of the pipeline must work without demucs installed.

Two modes:

* ``extract_drums`` runs Demucs with ``--two-stems=drums`` — fastest path when
  the drum stem is all we need.
* ``extract_stems`` runs the full 4-stem model (drums / bass / other / vocals),
  needed for melodic analyses that key off non-drum stems.

Both use the same on-disk cache layout (``<stems_dir>/<model>/<basename>/<stem>.wav``)
so the drum stem from either mode is interchangeable.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


DEFAULT_STEMS_DIR = Path("stems")
MODEL = "htdemucs"
ALL_STEMS = ("drums", "bass", "other", "vocals")


def stem_path(audio_path: Path, stem: str, stems_dir: Path) -> Path:
    """Demucs writes to ``<stems_dir>/<model>/<basename>/<stem>.wav`` — mirror
    that layout so the cache lookup matches what Demucs produces."""
    return stems_dir / MODEL / audio_path.stem / f"{stem}.wav"


def _run_demucs(audio_path: Path, stems_dir: Path, two_stems: str | None) -> None:
    try:
        import demucs  # noqa: F401
    except ImportError as e:
        raise RuntimeError(
            "demucs failed to import — it is a core dependency; reinstall the "
            "package with `pip install -e .`."
        ) from e
    cmd = [sys.executable, "-m", "demucs", "-n", MODEL, "-o", str(stems_dir)]
    if two_stems is not None:
        cmd.insert(3, f"--two-stems={two_stems}")
    cmd.append(str(audio_path))
    mode = f"two-stems={two_stems}" if two_stems else "4-stem"
    print(f"[demucs] separating {audio_path.name} ({mode}, slow on CPU)…", file=sys.stderr)
    subprocess.run(cmd, check=True)


def extract_drums(audio_path: str | Path, stems_dir: Path = DEFAULT_STEMS_DIR) -> Path:
    """Run Demucs in two-stem (drums-only) mode. Cached: returns the existing
    drum-stem WAV if present, otherwise separates and returns the new path."""
    audio_path = Path(audio_path)
    cached = stem_path(audio_path, "drums", stems_dir)
    if cached.exists():
        return cached
    _run_demucs(audio_path, stems_dir, two_stems="drums")
    if not cached.exists():
        raise RuntimeError(f"Demucs ran but did not produce {cached}")
    return cached


def extract_stems(
    audio_path: str | Path,
    stems: tuple[str, ...] | list[str] = ALL_STEMS,
    stems_dir: Path = DEFAULT_STEMS_DIR,
) -> dict[str, Path]:
    """Run full 4-stem Demucs. Returns ``{stem_name: wav_path}`` for each
    requested stem. Cached on a per-stem basis: if *every* requested stem
    already exists, no separation runs. Otherwise we re-run the 4-stem
    extraction (which produces all four stems regardless of what we asked for,
    so the cache fills out for next time)."""
    audio_path = Path(audio_path)
    bad = [s for s in stems if s not in ALL_STEMS]
    if bad:
        raise ValueError(f"unknown stem(s): {bad}; valid stems are {ALL_STEMS}")
    paths = {s: stem_path(audio_path, s, stems_dir) for s in stems}
    if all(p.exists() for p in paths.values()):
        return paths
    _run_demucs(audio_path, stems_dir, two_stems=None)
    missing = [s for s, p in paths.items() if not p.exists()]
    if missing:
        raise RuntimeError(f"Demucs ran but did not produce stems: {missing}")
    return paths
