"""Drum-stem separation via Demucs.

This is the only module that depends on demucs/torch. Import it lazily — the
rest of the pipeline must work without demucs installed.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


DEFAULT_STEMS_DIR = Path("stems")
MODEL = "htdemucs"


def drum_stem_path(audio_path: Path, stems_dir: Path) -> Path:
    """Demucs writes to ``<stems_dir>/<model>/<basename>/drums.wav`` — mirror
    that layout so the cache lookup matches what Demucs produces."""
    return stems_dir / MODEL / audio_path.stem / "drums.wav"


def extract_drums(audio_path: str | Path, stems_dir: Path = DEFAULT_STEMS_DIR) -> Path:
    """Run Demucs (two-stems=drums) on ``audio_path``. Cached: returns the
    existing drum-stem WAV without re-running if it already exists in
    ``stems_dir``. Returns the path to the drum-stem WAV."""
    audio_path = Path(audio_path)
    cached = drum_stem_path(audio_path, stems_dir)
    if cached.exists():
        return cached

    try:
        import demucs  # noqa: F401
    except ImportError as e:
        raise RuntimeError(
            "Demucs is not installed. Install with `pip install -e '.[demucs]'`."
        ) from e

    cmd = [
        sys.executable, "-m", "demucs",
        "--two-stems=drums",
        "-n", MODEL,
        "-o", str(stems_dir),
        str(audio_path),
    ]
    print(f"[demucs] separating drums from {audio_path.name} (slow on CPU, faster on MPS/CUDA)…",
          file=sys.stderr)
    subprocess.run(cmd, check=True)

    if not cached.exists():
        raise RuntimeError(f"Demucs ran but did not produce {cached}")
    return cached
