"""CLI entry point: `synchronizer track.flac -o track.csv`."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .classify import DEFAULT_N_TIMBRE_CLUSTERS, classify
from .detect import DetectionConfig, detect_onsets, load_audio
from .features import extract_features
from .output import write_csv
from .segment import detect_segments, write_segments
from .waveform import write_waveform


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="synchronizer", description=__doc__)
    p.add_argument("input", help="Path to an audio file (wav/flac/mp3/...).")
    p.add_argument("-o", "--output", required=True, help="Path to write CSV output.")
    p.add_argument("--sr", type=int, default=None, help="Resample rate (default: file's native).")
    p.add_argument("--hop", type=int, default=512, help="Hop length in samples (default 512).")
    p.add_argument("--delta", type=float, default=0.07, help="Onset peak-pick threshold (default 0.07).")
    p.add_argument("--wait", type=int, default=5, help="Min frames between onsets within a band (default 5).")
    p.add_argument("--no-multi-band", action="store_true",
                   help="Disable multi-band detection; run a single wideband SuperFlux envelope.")
    p.add_argument("--merge-tolerance-ms", type=float, default=30.0,
                   help="Cross-band onsets within this window collapse to one (default 30 ms).")
    p.add_argument("--band-wait-ms", type=float, nargs=3, metavar=("LOWS", "MIDS", "HIGHS"),
                   default=(200.0, 100.0, 50.0),
                   help="Per-band min spacing in ms (lows mids highs, default 200 100 50).")
    p.add_argument("--percussive", action="store_true",
                   help="Run HPSS and detect on percussive component only.")
    p.add_argument("--drums", action="store_true",
                   help="Separate the drum stem via Demucs and run the whole pipeline on it. "
                        "Cached in --stems-dir, so the slow step only runs once per file. "
                        "Implies --no-pitch since drum stems have no pitched content.")
    p.add_argument("--stems-dir", default="stems",
                   help="Directory for cached Demucs output (default: ./stems).")
    p.add_argument("--no-pitch", action="store_true",
                   help="Skip pyin pitch estimation (~2× faster). All transients get pitch_bucket=unpitched.")
    p.add_argument("--no-backtrack", action="store_true",
                   help="Don't snap onsets to preceding minimum.")
    p.add_argument("--timbre-clusters", type=int, default=DEFAULT_N_TIMBRE_CLUSTERS,
                   help=f"K for k-means timbre clustering (default {DEFAULT_N_TIMBRE_CLUSTERS}).")
    p.add_argument("--n-segments", type=int, default=12,
                   help="Target number of structural segments (default 12).")
    p.add_argument("--n-segment-labels", type=int, default=4,
                   help="Number of distinct segment labels — repeated sections share a label (default 4).")
    p.add_argument("--no-segments", action="store_true",
                   help="Skip structural segmentation.")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    original_input = Path(args.input)
    in_path = original_input
    if not in_path.exists():
        print(f"error: {in_path} not found", file=sys.stderr)
        return 2

    if args.drums:
        from .separate import extract_drums
        in_path = extract_drums(in_path, stems_dir=Path(args.stems_dir))
        args.no_pitch = True

    cfg = DetectionConfig(
        sr=args.sr,
        hop_length=args.hop,
        backtrack=not args.no_backtrack,
        delta=args.delta,
        wait=args.wait,
        multi_band=not args.no_multi_band,
        merge_tolerance_ms=args.merge_tolerance_ms,
        band_wait_ms=tuple(args.band_wait_ms),
        use_percussive=args.percussive,
    )

    y, sr = load_audio(str(in_path), sr=cfg.sr)
    onsets = detect_onsets(y, sr, cfg)
    feats = extract_features(y, sr, onsets, hop_length=cfg.hop_length, compute_pitch=not args.no_pitch)
    classified = classify(feats, n_timbre_clusters=args.timbre_clusters)
    write_csv(classified, args.output)

    # Waveform peaks for the Processing visualizer — always derived from the
    # original input (the audio the user actually plays in the sketch), not
    # the separated stem.
    csv_path = Path(args.output)
    waveform_path = csv_path.with_name(csv_path.stem + "_waveform.csv")
    write_waveform(original_input, waveform_path)

    print(f"{in_path.name}: {len(classified)} transients -> {args.output}")
    print(f"waveform -> {waveform_path}")

    # Structural segments — always computed from the original mix (harmonic
    # changes that define verse/chorus are visible there, not in the drum stem).
    if not args.no_segments:
        segments = detect_segments(
            original_input,
            n_segments=args.n_segments,
            n_labels=args.n_segment_labels,
        )
        seg_path = csv_path.with_name(csv_path.stem + "_segments.csv")
        write_segments(segments, seg_path)
        print(f"segments -> {seg_path} ({len(segments)} segments, "
              f"{len({s.label for s in segments})} distinct labels)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
