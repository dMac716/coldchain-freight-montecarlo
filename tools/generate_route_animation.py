#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pandas as pd

# Make matplotlib/fontconfig cache writable in restricted shells/CI.
_cache_root = Path(os.environ.get("XDG_CACHE_HOME", tempfile.gettempdir()))
_mpl_cfg = _cache_root / "matplotlib"
_font_cfg = _cache_root / "fontconfig"
_mpl_cfg.mkdir(parents=True, exist_ok=True)
_font_cfg.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("MPLCONFIGDIR", str(_mpl_cfg))
os.environ.setdefault("XDG_CACHE_HOME", str(_cache_root))
os.environ.setdefault("FONTCONFIG_PATH", str(_font_cfg))
os.environ.setdefault("MPLBACKEND", "Agg")

import matplotlib.pyplot as plt

DIESEL_COLOR = "#1F77D0"
BEV_COLOR = "#D4A017"
ROUTE_BG_COLOR = "#CFCFCF"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--representative_csv", default="outputs/presentation/representative_runs.csv")
    p.add_argument("--tracks_dir", default="outputs/sim_tracks")
    p.add_argument("--outdir", default="docs/assets/transport/animations")
    p.add_argument("--fps", type=int, default=10)
    p.add_argument("--max_frames", type=int, default=240)
    p.add_argument("--write_gif", default="false")
    return p.parse_args()


def load_track(tracks_dir: Path, run_id: str) -> pd.DataFrame:
    for ext in [".csv", ".csv.gz"]:
        p = tracks_dir / f"{run_id}{ext}"
        if p.exists():
            d = pd.read_csv(p)
            d["run_id"] = run_id
            d["t"] = pd.to_datetime(d.get("t"), errors="coerce", utc=True)
            for c in ["lat","lng","distance_miles_cum","co2_kg_cum","diesel_gal_cum","propulsion_kwh_cum","tru_kwh_cum","tru_gal_cum","delay_minutes_cum","charge_count","refuel_count"]:
                if c not in d.columns:
                    d[c] = np.nan
                d[c] = pd.to_numeric(d[c], errors="coerce")
            return d
    # Fallback: case-insensitive stem match.
    rid = run_id.lower()
    for p in sorted(tracks_dir.glob("*.csv*")):
        stem = p.name.replace(".csv.gz", "").replace(".csv", "").lower()
        if stem == rid:
            d = pd.read_csv(p)
            d["run_id"] = run_id
            d["t"] = pd.to_datetime(d.get("t"), errors="coerce", utc=True)
            for c in ["lat","lng","distance_miles_cum","co2_kg_cum","diesel_gal_cum","propulsion_kwh_cum","tru_kwh_cum","tru_gal_cum","delay_minutes_cum","charge_count","refuel_count"]:
                if c not in d.columns:
                    d[c] = np.nan
                d[c] = pd.to_numeric(d[c], errors="coerce")
            return d
    raise FileNotFoundError(f"No track file found for run_id={run_id}")


def is_usable_track(df: pd.DataFrame) -> bool:
    if df is None or df.empty:
        return False
    if "lat" not in df.columns or "lng" not in df.columns:
        return False
    keep = np.isfinite(pd.to_numeric(df["lat"], errors="coerce")) & np.isfinite(pd.to_numeric(df["lng"], errors="coerce"))
    return bool(keep.sum() >= 2)


def resolve_track_run_id(tracks_dir: Path, preferred_run_id: str, powertrain: str) -> str:
    try:
        d0 = load_track(tracks_dir, preferred_run_id)
        if is_usable_track(d0):
            return preferred_run_id
    except FileNotFoundError:
        try:
            dd = load_track(tracks_dir, preferred_run_id.lower())
            if is_usable_track(dd):
                return preferred_run_id.lower()
        except FileNotFoundError:
            pass
    raise FileNotFoundError(
        f"Missing usable track for required representative run_id={preferred_run_id} powertrain={powertrain}. "
        "No fallback allowed."
    )


def counter_text(df: pd.DataFrame, i: int, powertrain: str) -> str:
    r = df.iloc[min(i, len(df)-1)]
    t0 = df["t"].iloc[0]
    t1 = r["t"]
    elapsed_h = (t1 - t0).total_seconds()/3600 if pd.notna(t0) and pd.notna(t1) else i / 10.0
    lines = [
        f"elapsed: {elapsed_h:.2f} h",
        f"distance: {float(r['distance_miles_cum']):.1f} mi",
        f"CO2 cum: {float(r['co2_kg_cum']):.2f} kg",
        f"traffic delay: {float(r['delay_minutes_cum']):.1f} min",
    ]
    if powertrain == "diesel":
        lines.append(f"tractor diesel: {float(r['diesel_gal_cum']):.2f} gal")
        lines.append(f"reefer diesel: {float(r['tru_gal_cum']):.2f} gal")
        lines.append(f"refuel stops: {int(float(r['refuel_count']) if np.isfinite(r['refuel_count']) else 0)}")
    else:
        lines.append(f"traction elec: {float(r['propulsion_kwh_cum']):.1f} kWh")
        lines.append(f"reefer elec: {float(r['tru_kwh_cum']):.1f} kWh")
        lines.append(f"charge stops: {int(float(r['charge_count']) if np.isfinite(r['charge_count']) else 0)}")
    return "\n".join(lines)


def track_identity(df: pd.DataFrame) -> dict:
    d = df.copy()
    d["lat"] = pd.to_numeric(d["lat"], errors="coerce")
    d["lng"] = pd.to_numeric(d["lng"], errors="coerce")
    d["distance_miles_cum"] = pd.to_numeric(d["distance_miles_cum"], errors="coerce")
    d = d[np.isfinite(d["lat"]) & np.isfinite(d["lng"])]
    if d.empty:
        raise ValueError("Track has no finite coordinates")
    start = d.iloc[0]
    end = d.iloc[-1]
    dist = float(pd.to_numeric(df["distance_miles_cum"], errors="coerce").dropna().max()) if "distance_miles_cum" in df.columns else float("nan")
    return {
        "start_lat": float(start["lat"]),
        "start_lng": float(start["lng"]),
        "end_lat": float(end["lat"]),
        "end_lng": float(end["lng"]),
        "distance_miles": dist,
    }


def write_video_from_frames(frame_dir: Path, out_prefix: Path, fps: int, write_gif: bool) -> None:
    if not shutil.which("ffmpeg"):
        print("ffmpeg not found; skipping video export")
        return
    mp4 = out_prefix.with_suffix(".mp4")
    pattern = str(frame_dir / "frame_%04d.png")

    cmd_mp4 = [
        "ffmpeg", "-y", "-framerate", str(max(8, fps)), "-i", pattern,
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(mp4)
    ]
    subprocess.run(cmd_mp4, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if write_gif:
        gif = out_prefix.with_suffix(".gif")
        palette = frame_dir / "palette.png"
        subprocess.run(["ffmpeg", "-y", "-i", pattern, "-vf", "palettegen", str(palette)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["ffmpeg", "-y", "-framerate", str(max(8, fps)), "-i", pattern, "-i", str(palette), "-lavfi", "paletteuse", str(gif)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def frame_steps(n_rows: int, max_frames: int) -> np.ndarray:
    n_rows = int(max(n_rows, 1))
    max_frames = int(max(max_frames, 1))
    if n_rows <= max_frames:
        return np.arange(1, n_rows + 1)
    return np.unique(np.linspace(1, n_rows, num=max_frames).astype(int))


def downsample_df(df: pd.DataFrame, max_points: int) -> pd.DataFrame:
    if df is None or df.empty:
        return df
    if len(df) <= max_points:
        return df
    idx = np.unique(np.linspace(0, len(df) - 1, num=max_points).astype(int))
    return df.iloc[idx]


def render_single(df: pd.DataFrame, label: str, color: str, out_prefix: Path, fps: int, max_frames: int, write_gif: bool) -> None:
    frame_dir = out_prefix.parent / f"_frames_{out_prefix.stem}"
    frame_dir.mkdir(parents=True, exist_ok=True)

    route_full = downsample_df(df, 2000)
    xmin, xmax = float(route_full["lng"].min()), float(route_full["lng"].max())
    ymin, ymax = float(route_full["lat"].min()), float(route_full["lat"].max())
    padx = max(0.02, (xmax - xmin) * 0.05)
    pady = max(0.02, (ymax - ymin) * 0.05)

    steps = frame_steps(len(df), max_frames)
    for frame_i, i in enumerate(steps, start=1):
        cur = df.iloc[:i]
        if cur.empty:
            continue
        cur_plot = downsample_df(cur, 1200)
        fig, ax = plt.subplots(figsize=(12, 7), facecolor="white")
        ax.plot(route_full["lng"], route_full["lat"], color=ROUTE_BG_COLOR, lw=2, alpha=0.7)
        ax.plot(cur_plot["lng"], cur_plot["lat"], color=color, lw=2.5)
        ax.scatter(cur_plot["lng"].iloc[-1], cur_plot["lat"].iloc[-1], s=70, color=color, edgecolor="white", zorder=4)
        ax.set_xlim(xmin - padx, xmax + padx)
        ax.set_ylim(ymin - pady, ymax + pady)
        ax.set_xlabel("Longitude")
        ax.set_ylabel("Latitude")
        ax.set_title(f"Route Animation: {label}")
        ax.grid(alpha=0.15)
        ax.text(0.02, 0.98, counter_text(df, i-1, "bev" if "bev" in label.lower() else "diesel"),
                transform=ax.transAxes, va="top", ha="left",
                bbox=dict(boxstyle="round", facecolor="white", alpha=0.9), fontsize=10)
        fig.savefig(frame_dir / f"frame_{frame_i:04d}.png", dpi=160)
        plt.close(fig)

    shutil.copyfile(frame_dir / f"frame_{len(steps):04d}.png", out_prefix.parent / f"{out_prefix.stem}_last_frame.png")
    write_video_from_frames(frame_dir, out_prefix, fps, write_gif)


def render_side_by_side(diesel: pd.DataFrame, bev: pd.DataFrame, out_prefix: Path, fps: int, max_frames: int, write_gif: bool) -> None:
    frame_dir = out_prefix.parent / f"_frames_{out_prefix.stem}"
    frame_dir.mkdir(parents=True, exist_ok=True)

    n = max(len(diesel), len(bev))
    steps = frame_steps(n, max_frames)
    diesel_route = downsample_df(diesel, 2000)
    bev_route = downsample_df(bev, 2000)

    for frame_i, i in enumerate(steps, start=1):
        idz = min(int(i), len(diesel))
        ibv = min(int(i), len(bev))
        dcur = diesel.iloc[:idz]
        bcur = bev.iloc[:ibv]

        fig, axes = plt.subplots(1, 2, figsize=(16, 7), facecolor="white")
        for ax, full, cur, full_route, col, ttl, pwr in [
            (axes[0], diesel, dcur, diesel_route, DIESEL_COLOR, "Diesel representative", "diesel"),
            (axes[1], bev, bcur, bev_route, BEV_COLOR, "BEV representative", "bev"),
        ]:
            cur_plot = downsample_df(cur, 1200)
            xmin, xmax = float(full["lng"].min()), float(full["lng"].max())
            ymin, ymax = float(full["lat"].min()), float(full["lat"].max())
            padx = max(0.02, (xmax - xmin) * 0.05)
            pady = max(0.02, (ymax - ymin) * 0.05)
            ax.plot(full_route["lng"], full_route["lat"], color=ROUTE_BG_COLOR, lw=2, alpha=0.7)
            ax.plot(cur_plot["lng"], cur_plot["lat"], color=col, lw=2.5)
            if not cur_plot.empty:
                ax.scatter(cur_plot["lng"].iloc[-1], cur_plot["lat"].iloc[-1], s=70, color=col, edgecolor="white", zorder=4)
            ax.set_xlim(xmin - padx, xmax + padx)
            ax.set_ylim(ymin - pady, ymax + pady)
            ax.set_title(ttl)
            ax.set_xlabel("Longitude")
            ax.set_ylabel("Latitude")
            ax.grid(alpha=0.15)
            ax.text(0.02, 0.98, counter_text(full, len(cur)-1, pwr), transform=ax.transAxes,
                    va="top", ha="left", bbox=dict(boxstyle="round", facecolor="white", alpha=0.9), fontsize=9)

        fig.suptitle("Diesel vs BEV Route Comparison", fontsize=16, weight="bold")
        fig.savefig(frame_dir / f"frame_{frame_i:04d}.png", dpi=160)
        plt.close(fig)

    shutil.copyfile(frame_dir / f"frame_{len(steps):04d}.png", out_prefix.parent / f"{out_prefix.stem}_last_frame.png")
    write_video_from_frames(frame_dir, out_prefix, fps, write_gif)


def main() -> int:
    args = parse_args()
    write_gif = str(args.write_gif).strip().lower() in {"1", "true", "yes", "y"}
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    reps = pd.read_csv(args.representative_csv)
    if "run_id" not in reps.columns or "powertrain" not in reps.columns:
      raise SystemExit("representative_csv must include run_id and powertrain")

    tracks_dir = Path(args.tracks_dir)
    diesel_row = reps[reps["powertrain"].str.lower() == "diesel"].head(1)
    bev_row = reps[reps["powertrain"].str.lower() == "bev"].head(1)
    if diesel_row.empty or bev_row.empty:
      raise SystemExit("Need both diesel and bev representative rows")

    diesel_id = str(diesel_row["run_id"].iloc[0])
    bev_id = str(bev_row["run_id"].iloc[0])
    route_id_d = str(diesel_row["route_id"].iloc[0]) if "route_id" in diesel_row.columns else ""
    route_id_b = str(bev_row["route_id"].iloc[0]) if "route_id" in bev_row.columns else ""
    if route_id_d and route_id_b and route_id_d != route_id_b:
      raise SystemExit(f"Representative mismatch: diesel route_id={route_id_d} bev route_id={route_id_b}")

    diesel_id = resolve_track_run_id(tracks_dir, diesel_id, "diesel")
    bev_id = resolve_track_run_id(tracks_dir, bev_id, "bev")
    d = load_track(tracks_dir, diesel_id)
    b = load_track(tracks_dir, bev_id)

    id_d = track_identity(d)
    id_b = track_identity(b)
    print(
        "TRACK_IDENTITY "
        f"diesel_run={diesel_id} bev_run={bev_id} "
        f"diesel_start=({id_d['start_lat']:.5f},{id_d['start_lng']:.5f}) "
        f"bev_start=({id_b['start_lat']:.5f},{id_b['start_lng']:.5f}) "
        f"diesel_end=({id_d['end_lat']:.5f},{id_d['end_lng']:.5f}) "
        f"bev_end=({id_b['end_lat']:.5f},{id_b['end_lng']:.5f}) "
        f"diesel_miles={id_d['distance_miles']:.2f} bev_miles={id_b['distance_miles']:.2f}"
    )

    # Hard sanity checks so we never animate different trips as a comparison pair.
    start_delta = max(abs(id_d["start_lat"] - id_b["start_lat"]), abs(id_d["start_lng"] - id_b["start_lng"]))
    end_delta = max(abs(id_d["end_lat"] - id_b["end_lat"]), abs(id_d["end_lng"] - id_b["end_lng"]))
    dist_ratio = (
        max(id_d["distance_miles"], id_b["distance_miles"]) / max(min(id_d["distance_miles"], id_b["distance_miles"]), 1e-9)
        if np.isfinite(id_d["distance_miles"]) and np.isfinite(id_b["distance_miles"])
        else float("inf")
    )
    if start_delta > 0.25 or end_delta > 0.25 or dist_ratio > 1.2:
      raise SystemExit(
          "Representative tracks do not appear to be the same route geometry: "
          f"start_delta={start_delta:.4f}, end_delta={end_delta:.4f}, dist_ratio={dist_ratio:.3f}"
      )

    render_single(d, f"Diesel ({diesel_id})", DIESEL_COLOR, outdir / "route_animation_diesel", args.fps, args.max_frames, write_gif)
    render_single(b, f"BEV ({bev_id})", BEV_COLOR, outdir / "route_animation_bev", args.fps, args.max_frames, write_gif)
    render_side_by_side(d, b, outdir / "route_animation_diesel_vs_bev", args.fps, args.max_frames, write_gif)

    print(f"Wrote animations to {outdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
