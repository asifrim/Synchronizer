"""CLI entry point: `synchronizer track.flac -o track.csv`."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .classify import DEFAULT_CLUSTER_K_MAX, DEFAULT_N_TIMBRE_CLUSTERS, classify
from .detect import DetectionConfig, detect_onsets, load_audio
from .features import extract_features
from .grid import build_grid, write_grid
from .output import write_csv
from .segment import (
    analyze_mix,
    detect_segments,
    detect_tempo_segments,
    write_segments,
    write_tempo_segments,
)
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
    p.add_argument("--cluster-k-max", type=int, default=DEFAULT_CLUSTER_K_MAX,
                   help=f"Upper bound on k when searching for the best holistic transient "
                        f"clustering (default {DEFAULT_CLUSTER_K_MAX}, chosen by silhouette score).")
    p.add_argument("--n-segments", type=int, default=12,
                   help="Target number of structural segments (default 12).")
    p.add_argument("--n-segment-labels", type=int, default=4,
                   help="Number of distinct segment labels — repeated sections share a label (default 4).")
    p.add_argument("--no-segments", action="store_true",
                   help="Skip structural segmentation.")
    p.add_argument("--n-tempo-segments", type=int, default=8,
                   help="Target number of tempo-homogeneous segments for tempo-shift "
                        "detection (default 8).")
    p.add_argument("--no-tempo-segments", action="store_true",
                   help="Skip tempo-shift detection.")
    p.add_argument("--no-grid", action="store_true",
                   help="Skip the metronome grid (4th/8th/16th/32nd note ticks).")
    p.add_argument("--melody", action="store_true",
                   help="Detect notes on melodic stems (vocals/bass/other) via Demucs. "
                        "Writes <csv_stem>_<stem>_melody.csv per stem. "
                        "Requires the [demucs] extra and a full 4-stem separation.")
    p.add_argument("--melody-stems", default="vocals,bass,other",
                   help="Comma-separated stems for --melody (default vocals,bass,other).")
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
    # The sidecar analyses (waveform, segments, tempo, grid) always run on the
    # original input at its native rate. If that's the same audio we just
    # loaded — no drum stem, no resampling — pass it through instead of
    # re-decoding the file twice.
    share_original_audio = (in_path == original_input) and (cfg.sr is None)
    onsets = detect_onsets(y, sr, cfg)
    feats = extract_features(y, sr, onsets, hop_length=cfg.hop_length, compute_pitch=not args.no_pitch)
    classified, chosen_k, silhouette = classify(
        feats,
        n_timbre_clusters=args.timbre_clusters,
        cluster_k_max=args.cluster_k_max,
    )
    # Resolve the output path. If -o is a directory (no suffix) or explicitly
    # named "events.csv", write canonical sidecar names alongside it.
    # Otherwise keep the old <stem>_<sidecar>.csv convention for compat.
    out_arg = Path(args.output)
    if not out_arg.suffix:
        # Directory form: -o out/04_Krib  →  out/04_Krib/events.csv
        csv_path = out_arg / "events.csv"
    else:
        csv_path = out_arg

    def sidecar(name: str) -> Path:
        if csv_path.name == "events.csv":
            return csv_path.parent / name
        return csv_path.with_name(csv_path.stem + "_" + name)

    write_csv(classified, csv_path)

    # Waveform peaks for the Processing visualizer — always derived from the
    # original input (the audio the user actually plays in the sketch), not
    # the separated stem.
    waveform_path = sidecar("waveform.csv")
    if share_original_audio:
        write_waveform(original_input, waveform_path, y=y, sr=sr)
    else:
        write_waveform(original_input, waveform_path)

    print(f"{in_path.name}: {len(classified)} transients -> {csv_path}")
    print(f"transient clusters: k={chosen_k} (silhouette={silhouette:.3f})")
    print(f"waveform -> {waveform_path}")

    # Structural + tempo analysis, both computed from the original mix (the
    # harmonic and rhythmic changes that define them live there, not in a drum
    # stem). The load + onset envelope + global tempo are computed once and
    # shared between the two.
    if not (args.no_segments and args.no_tempo_segments and args.no_grid):
        if share_original_audio:
            mix = analyze_mix(original_input, y=y, sr=sr)
        else:
            mix = analyze_mix(original_input)
        print(f"global tempo: {mix.global_bpm:.1f} BPM")

        if not args.no_segments:
            segments = detect_segments(
                mix,
                n_segments=args.n_segments,
                n_labels=args.n_segment_labels,
            )
            seg_path = sidecar("segments.csv")
            write_segments(segments, seg_path)
            print(f"segments -> {seg_path} ({len(segments)} segments, "
                  f"{len({s.label for s in segments})} distinct labels)")

        if not args.no_tempo_segments:
            tempo_segments = detect_tempo_segments(
                mix, n_tempo_segments=args.n_tempo_segments
            )
            tempo_path = sidecar("tempo.csv")
            write_tempo_segments(tempo_segments, tempo_path)
            bpms = [s.tempo_bpm for s in tempo_segments if s.tempo_bpm]
            rng = f"{min(bpms):.0f}-{max(bpms):.0f} BPM" if bpms else "n/a"
            print(f"tempo -> {tempo_path} ({len(tempo_segments)} tempo segments, {rng})")

        if not args.no_grid:
            grid = build_grid(mix.beat_times)
            grid_path = sidecar("grid.csv")
            write_grid(grid, grid_path)
            print(f"grid -> {grid_path} ({len(grid)} ticks across {len(mix.beat_times)} beats)")

    if args.melody:
        # Per-stem note detection. Demucs separation is cached; the slow step
        # only runs the first time a given stem is needed. Keep the imports
        # lazy (demucs is an optional extra).
        from .melody import detect_notes, write_notes
        from .separate import extract_stems
        wanted = [s.strip() for s in args.melody_stems.split(",") if s.strip()]
        stem_paths = extract_stems(original_input, wanted, stems_dir=Path(args.stems_dir))
        for stem_name in wanted:
            notes = detect_notes(stem_paths[stem_name], stem_name)
            note_path = sidecar(f"{stem_name}_melody.csv")
            write_notes(notes, note_path)
            print(f"melody/{stem_name} -> {note_path} ({len(notes)} notes)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
