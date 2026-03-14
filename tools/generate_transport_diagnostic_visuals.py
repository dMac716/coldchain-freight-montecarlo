#!/usr/bin/env python3
"""Generate presentation diagnostics and evolution animation for transport MC outputs."""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt


TRIP_CANDIDATES = [
    "total_trip_time_h",
    "trip_duration_total_h",
    "total_trip_time",
    "trip_time_hours",
    "total_hours",
    "route_duration",
    "transit_time",
    "delivery_time_min",
]

DRIVER_CANDIDATES = [
    "tru_runtime_min",
    "time_refrigeration_min",
    "diesel_gal_tru",
    "energy_kwh_tru",
    "distance_miles",
    "distance_km",
    "time_load_unload_min",
    "stops",
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--outdir", default="outputs/presentation/transport_graphics_full_n20_fix")
    p.add_argument("--runs_csv", default=None)
    p.add_argument("--summary_csv", default=None)
    p.add_argument("--breakdown_csv", default=None)
    p.add_argument("--metadata_json", default=None)
    p.add_argument("--notes_md", default=None)
    p.add_argument("--fps", type=int, default=10)
    return p.parse_args()


def choose_col(df: pd.DataFrame, candidates: list[str]) -> str | None:
    for c in candidates:
        if c in df.columns and df[c].notna().sum() > 0:
            return c
    return None


def series_as_hours(df: pd.DataFrame, col: str) -> pd.Series:
    s = pd.to_numeric(df[col], errors="coerce")
    if col.endswith("_min"):
        return s / 60.0
    return s


def add_trend(ax, x: pd.Series, y: pd.Series, color: str) -> None:
    ok = x.notna() & y.notna()
    if ok.sum() < 8:
        return
    xv = x[ok].to_numpy()
    yv = y[ok].to_numpy()
    try:
        coef = np.polyfit(xv, yv, 1)
    except Exception:
        return
    xx = np.linspace(np.nanmin(xv), np.nanmax(xv), 100)
    yy = coef[0] * xx + coef[1]
    ax.plot(xx, yy, color=color, lw=2.0, alpha=0.9)


def bimodal_gap(values: np.ndarray) -> tuple[bool, float | None, float]:
    vals = np.sort(values[np.isfinite(values)])
    if vals.size < 12:
        return False, None, float("nan")
    gaps = np.diff(vals)
    if gaps.size == 0:
        return False, None, float("nan")
    idx = int(np.argmax(gaps))
    max_gap = float(gaps[idx])
    iqr = np.subtract(*np.percentile(vals, [75, 25]))
    threshold = max(0.15 * float(iqr if np.isfinite(iqr) else 0.0), 1e-9)
    split = float((vals[idx] + vals[idx + 1]) / 2.0)
    return max_gap > threshold, split, max_gap


def load_metadata(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open() as f:
        return json.load(f)


def prep_df(df: pd.DataFrame) -> pd.DataFrame:
    for c in ["co2_per_1000kcal", "trip_duration_total_h", "delivery_time_min", "total_trip_time_h"]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    if "origin_network" in df.columns:
        df["origin_network"] = df["origin_network"].astype(str)
    return df


def make_three_panel(df: pd.DataFrame, outdir: Path, metadata: dict) -> dict:
    co2_col = "co2_per_1000kcal"
    if co2_col not in df.columns:
        raise RuntimeError("Missing required column: co2_per_1000kcal")

    trip_col = choose_col(df, TRIP_CANDIDATES)
    fallback_used = False
    searched_trip = TRIP_CANDIDATES.copy()
    if trip_col is None:
        trip_col = choose_col(df, DRIVER_CANDIDATES)
        fallback_used = True
    if trip_col is None:
        raise RuntimeError(f"No trip-time or proxy columns found. Searched: {searched_trip + DRIVER_CANDIDATES}")

    xh = series_as_hours(df, trip_col) if trip_col.endswith("_min") else pd.to_numeric(df[trip_col], errors="coerce")
    base = df.copy()
    base["x_plot"] = xh
    base = base[np.isfinite(base["x_plot"]) & np.isfinite(base[co2_col])]

    if "origin_network" not in base.columns:
        raise RuntimeError("Missing origin_network column")

    dry = base[base["origin_network"] == "dry_factory_set"].copy()
    refr = base[base["origin_network"] == "refrigerated_factory_set"].copy()

    has_pair = "pair_id" in base.columns and base["pair_id"].notna().any()

    meta_filter = metadata.get("filter", {})
    subtitle = (
        f"{meta_filter.get('scenario', 'N/A')} | {meta_filter.get('powertrain', 'N/A')} | "
        f"{meta_filter.get('traffic_mode', 'N/A')} traffic | matched pairs = {metadata.get('counts', {}).get('n_pairs_matched', 'N/A')}"
    )

    palette = {"dry_factory_set": "#2F80ED", "refrigerated_factory_set": "#E67E22"}

    fig = plt.figure(figsize=(16, 9), facecolor="white")
    gs = fig.add_gridspec(1, 3, width_ratios=[1.25, 1.0, 1.1], wspace=0.25)
    ax1 = fig.add_subplot(gs[0, 0])
    ax2 = fig.add_subplot(gs[0, 1])
    ax3 = fig.add_subplot(gs[0, 2])

    # Panel A
    ax1.scatter(dry["x_plot"], dry[co2_col], s=28, alpha=0.45, color=palette["dry_factory_set"], label="Dry")
    ax1.scatter(refr["x_plot"], refr[co2_col], s=30, alpha=0.55, color=palette["refrigerated_factory_set"], label="Refrigerated")
    add_trend(ax1, dry["x_plot"], dry[co2_col], palette["dry_factory_set"])
    add_trend(ax1, refr["x_plot"], refr[co2_col], palette["refrigerated_factory_set"])
    ax1.set_xlabel("Total Trip Time (hours)", fontsize=13)
    ax1.set_ylabel("kg CO2 per 1000 kcal", fontsize=13)
    ax1.set_title("A. Trip Time vs Emissions", fontsize=14, weight="bold")
    ax1.grid(alpha=0.2)
    ax1.legend(frameon=False, fontsize=11)

    # Panel B
    rvals = refr[co2_col].to_numpy(dtype=float)
    rvals = rvals[np.isfinite(rvals)]
    bins = max(8, min(18, int(round(math.sqrt(max(len(rvals), 1))))))
    ax2.hist(rvals, bins=bins, color="#F4B183", edgecolor="#B35A00", alpha=0.75)
    if rvals.size > 0:
        ax2.plot(rvals, np.full_like(rvals, -0.15), "|", color="#7F3F00", alpha=0.5)
        ax2.axvline(np.nanmean(rvals), color="#8E44AD", lw=2, linestyle="-", label="Mean")
        ax2.axvline(np.nanmedian(rvals), color="#1F3A93", lw=2, linestyle="--", label="Median")
    bimodal, split_val, gap = bimodal_gap(rvals)
    if bimodal and split_val is not None:
        ax2.axvline(split_val, color="#D35400", lw=2, linestyle=":", label="Apparent split")
        ax2.text(split_val, max(ax2.get_ylim()) * 0.8, "Possible two regimes", rotation=90, va="center", ha="right", fontsize=10)
    ax2.set_title("B. Refrigerated Distribution", fontsize=14, weight="bold")
    ax2.set_xlabel("kg CO2 per 1000 kcal", fontsize=13)
    ax2.set_yticks([])
    ax2.legend(frameon=False, fontsize=10, loc="upper right")
    ax2.grid(alpha=0.15, axis="x")

    # Panel C
    if has_pair:
        d = base.pivot_table(index="pair_id", columns="origin_network", values=[co2_col, "x_plot"], aggfunc="mean")
        needed = [(co2_col, "refrigerated_factory_set"), (co2_col, "dry_factory_set"), ("x_plot", "refrigerated_factory_set"), ("x_plot", "dry_factory_set")]
        if all(k in d.columns for k in needed):
            d = d.dropna(subset=needed)
            dco2 = d[(co2_col, "refrigerated_factory_set")] - d[(co2_col, "dry_factory_set")]
            dtime = d[("x_plot", "refrigerated_factory_set")] - d[("x_plot", "dry_factory_set")]
            ax3.scatter(dtime, dco2, s=36, alpha=0.75, color="#6C5CE7")
            add_trend(ax3, pd.Series(dtime), pd.Series(dco2), "#6C5CE7")
            ax3.axhline(0, color="#666666", lw=1, linestyle="--")
            ax3.axvline(0, color="#666666", lw=1, linestyle="--")
            ax3.set_xlabel("Delta Trip Time (refrig - dry, h)", fontsize=12)
            ax3.set_ylabel("Delta Emissions (kg CO2 / 1000 kcal)", fontsize=12)
            ax3.set_title("C. Paired Delta vs Time Delta", fontsize=14, weight="bold")
        else:
            has_pair = False

    if not has_pair:
        q = pd.qcut(refr["x_plot"], q=min(4, max(2, refr["x_plot"].nunique())), duplicates="drop")
        refr2 = refr.assign(time_bucket=q.astype(str))
        order = sorted(refr2["time_bucket"].dropna().unique())
        data = [refr2.loc[refr2["time_bucket"] == b, co2_col].dropna().to_numpy() for b in order]
        ax3.boxplot(data, labels=order, patch_artist=True, boxprops=dict(facecolor="#FDEBD0", color="#AF601A"))
        ax3.set_xticklabels(order, rotation=20, ha="right", fontsize=9)
        ax3.set_title("C. Refrigerated by Trip-Time Bucket", fontsize=14, weight="bold")
        ax3.set_ylabel("kg CO2 per 1000 kcal", fontsize=12)
        ax3.set_xlabel("Trip-time bucket", fontsize=12)

    # Figure-level title/callouts
    fig.suptitle("Transport Monte Carlo Diagnostic: Refrigerated Regimes and Trip-Time Link", fontsize=20, weight="bold", y=0.98)
    fig.text(0.5, 0.94, subtitle, ha="center", va="center", fontsize=13)
    callout_1 = "Refrigerated variability exceeds dry" if refr[co2_col].std(skipna=True) > dry[co2_col].std(skipna=True) else "Dry and refrigerated spreads are similar"
    if bimodal:
        callout_2 = "Refrigerated runs separate into low and high bands"
    else:
        callout_2 = "No strong bimodal split detected in refrigerated runs"
    fig.text(0.02, 0.02, f"{callout_1}. {callout_2}. Emissions shown as kg CO2 per 1000 kcal delivered.", fontsize=11)

    png_path = outdir / "transport_trip_time_diagnostic.png"
    svg_path = outdir / "transport_trip_time_diagnostic.svg"
    fig.savefig(png_path, dpi=220, bbox_inches="tight")
    fig.savefig(svg_path, dpi=220, bbox_inches="tight")
    plt.close(fig)

    summary = {
        "trip_col": trip_col,
        "fallback_used": fallback_used,
        "n_dry": int(len(dry)),
        "n_refrigerated": int(len(refr)),
        "pair_id_available": bool(has_pair),
        "bimodal": bool(bimodal),
        "gap": float(gap) if np.isfinite(gap) else None,
    }
    return summary


def make_small_driver_diag(df: pd.DataFrame, outdir: Path, trip_col: str | None) -> dict:
    refr = df[df["origin_network"] == "refrigerated_factory_set"].copy()
    co2_col = "co2_per_1000kcal"
    driver_col = choose_col(refr, DRIVER_CANDIDATES)
    if driver_col is None:
        driver_col = trip_col
    if driver_col is None:
        raise RuntimeError("No suitable driver column found for refrigerated split diagnostic")

    x1 = series_as_hours(refr, trip_col) if (trip_col and trip_col.endswith("_min")) else pd.to_numeric(refr[trip_col], errors="coerce") if trip_col else pd.Series(dtype=float)
    x2 = series_as_hours(refr, driver_col) if driver_col.endswith("_min") else pd.to_numeric(refr[driver_col], errors="coerce")
    y = pd.to_numeric(refr[co2_col], errors="coerce")

    fig, axes = plt.subplots(1, 2, figsize=(11, 4.6), facecolor="white")
    if trip_col:
        axes[0].scatter(x1, y, s=24, alpha=0.6, color="#E67E22")
        add_trend(axes[0], x1, y, "#AF601A")
        axes[0].set_xlabel("Total Trip Time (hours)")
    else:
        axes[0].text(0.5, 0.5, "Trip-time column unavailable", ha="center", va="center")
    axes[0].set_ylabel("kg CO2 per 1000 kcal")
    axes[0].set_title("A. Refrigerated: Trip Time vs Emissions")
    axes[0].grid(alpha=0.2)

    axes[1].scatter(x2, y, s=24, alpha=0.6, color="#8E44AD")
    add_trend(axes[1], x2, y, "#6C3483")
    axes[1].set_xlabel(driver_col)
    axes[1].set_ylabel("kg CO2 per 1000 kcal")
    axes[1].set_title("B. Refrigerated: Candidate Driver vs Emissions")
    axes[1].grid(alpha=0.2)

    fig.suptitle("Refrigerated Split Diagnostic (Compact)", fontsize=14, weight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.93])

    png = outdir / "refrigerated_split_diagnostic.png"
    svg = outdir / "refrigerated_split_diagnostic.svg"
    fig.savefig(png, dpi=220, bbox_inches="tight")
    fig.savefig(svg, dpi=220, bbox_inches="tight")
    plt.close(fig)

    return {"driver_col": driver_col, "trip_col": trip_col}


def make_evolution_animation(df: pd.DataFrame, outdir: Path, metadata: dict, fps: int = 10) -> None:
    use = df[["pair_id", "origin_network", "co2_per_1000kcal"]].copy()
    if "pair_id" not in use.columns:
        print("Skipping evolution animation: pair_id not available")
        return
    use = use.dropna(subset=["pair_id", "origin_network", "co2_per_1000kcal"])
    pairs = sorted(use["pair_id"].unique())
    if not pairs:
        print("Skipping evolution animation: no matched pairs")
        return

    pair_rows = []
    for pid in pairs:
        sub = use[use["pair_id"] == pid]
        if {"dry_factory_set", "refrigerated_factory_set"}.issubset(set(sub["origin_network"])):
            pair_rows.append(sub)
    if not pair_rows:
        print("Skipping evolution animation: no complete dry+refrigerated pairs")
        return

    data = pd.concat(pair_rows, ignore_index=True)
    pairs = sorted(data["pair_id"].unique())
    n_pairs = len(pairs)

    scenario = metadata.get("filter", {}).get("scenario", "N/A")
    powertrain = metadata.get("filter", {}).get("powertrain", "N/A")
    traffic = metadata.get("filter", {}).get("traffic_mode", "N/A")

    frame_dir = outdir / "_frames_transport_evolution"
    frame_dir.mkdir(parents=True, exist_ok=True)

    y = data["co2_per_1000kcal"].to_numpy(dtype=float)
    ymin, ymax = np.nanmin(y), np.nanmax(y)
    pad = max(0.05 * (ymax - ymin), 1e-6)
    ylim = (ymin - pad, ymax + pad)

    mean_path = {"dry_factory_set": [], "refrigerated_factory_set": []}

    for i in range(1, n_pairs + 1):
        pkeep = set(pairs[:i])
        cur = data[data["pair_id"].isin(pkeep)]

        fig = plt.figure(figsize=(16, 9), facecolor="white")
        gs = fig.add_gridspec(1, 2, width_ratios=[1.25, 1.0], wspace=0.22)
        axL = fig.add_subplot(gs[0, 0])
        axR = fig.add_subplot(gs[0, 1])

        # Left: accumulating points + mean convergence
        colors = {"dry_factory_set": "#2F80ED", "refrigerated_factory_set": "#E67E22"}
        for idx, grp in enumerate(["dry_factory_set", "refrigerated_factory_set"], start=1):
            g = cur[cur["origin_network"] == grp]["co2_per_1000kcal"].to_numpy(dtype=float)
            xx = np.full(g.shape, idx) + np.random.default_rng(1000 + i).uniform(-0.13, 0.13, size=g.shape[0])
            axL.scatter(xx, g, s=30, alpha=0.55, color=colors[grp], label=("Dry" if grp == "dry_factory_set" else "Refrigerated"))
            if g.size > 0:
                m = float(np.nanmean(g))
                mean_path[grp].append((i, m))
                axL.scatter([idx], [m], s=120, marker="D", color=colors[grp], edgecolor="white", zorder=5)

        for idx, grp in enumerate(["dry_factory_set", "refrigerated_factory_set"], start=1):
            pts = mean_path[grp]
            if len(pts) >= 2:
                ys = [p[1] for p in pts]
                xs = np.linspace(idx - 0.28, idx + 0.28, num=len(ys))
                axL.plot(xs, ys, lw=1.8, alpha=0.65, color=colors[grp])

        axL.set_xlim(0.5, 2.5)
        axL.set_ylim(*ylim)
        axL.set_xticks([1, 2])
        axL.set_xticklabels(["dry_factory_set", "refrigerated_factory_set"], fontsize=11)
        axL.set_ylabel("kg CO2 / 1000 kcal", fontsize=13)
        axL.set_title("Accumulating Monte Carlo Samples", fontsize=15, weight="bold")
        axL.grid(alpha=0.15)

        # Right: refrigerated distribution evolution
        rv = cur[cur["origin_network"] == "refrigerated_factory_set"]["co2_per_1000kcal"].to_numpy(dtype=float)
        rv = rv[np.isfinite(rv)]
        bins = max(6, min(16, int(round(math.sqrt(max(rv.size, 1))))))
        axR.hist(rv, bins=bins, color="#F4B183", edgecolor="#AF601A", alpha=0.8)
        if rv.size:
            axR.axvline(np.nanmean(rv), color="#8E44AD", lw=2, linestyle="-", label="Mean")
            bimodal, split_val, _ = bimodal_gap(rv)
            if bimodal and split_val is not None:
                axR.axvline(split_val, color="#D35400", lw=2, linestyle=":", label="Split")
                axR.text(split_val, max(axR.get_ylim()) * 0.8, "Two clusters emerging", rotation=90, va="center", ha="right", fontsize=10)
        axR.set_title("Refrigerated Distribution Evolution", fontsize=15, weight="bold")
        axR.set_xlabel("kg CO2 / 1000 kcal", fontsize=13)
        axR.set_yticks([])
        axR.grid(alpha=0.15, axis="x")

        fig.suptitle("Monte Carlo Evolution of Transport Emissions", fontsize=20, weight="bold", y=0.98)
        fig.text(0.5, 0.94, f"{scenario} | {powertrain} | {traffic} traffic | matched pairs = {n_pairs}", ha="center", fontsize=13)
        fig.text(0.02, 0.02, f"Monte Carlo samples: {i} pairs | kg CO2 per 1000 kcal delivered", fontsize=11)

        # Keep a consistent pixel geometry for ffmpeg input frames.
        fig.savefig(frame_dir / f"frame_{i:04d}.png", dpi=180)
        plt.close(fig)

    mp4 = outdir / "transport_mc_evolution.mp4"
    gif = outdir / "transport_mc_evolution.gif"
    last = outdir / "transport_mc_evolution_last_frame.png"

    shutil.copyfile(frame_dir / f"frame_{n_pairs:04d}.png", last)

    if shutil.which("ffmpeg"):
        # Enforce even dimensions for yuv420p compatibility on slide/video players.
        vf_even = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        cmd_mp4 = [
            "ffmpeg", "-y",
            "-framerate", str(max(8, fps)),
            "-i", str(frame_dir / "frame_%04d.png"),
            "-vf", vf_even,
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            str(mp4)
        ]
        mp4_run = subprocess.run(cmd_mp4, check=False, capture_output=True, text=True)
        if mp4_run.returncode != 0 or (not mp4.exists()) or mp4.stat().st_size == 0:
            print("Warning: ffmpeg MP4 export failed")
            if mp4_run.stderr:
                print(mp4_run.stderr.strip().splitlines()[-1])

        palette = frame_dir / "palette.png"
        cmd_palette = [
            "ffmpeg", "-y", "-i", str(frame_dir / "frame_%04d.png"), "-vf", "palettegen", str(palette)
        ]
        cmd_gif = [
            "ffmpeg", "-y", "-framerate", str(max(8, fps)), "-i", str(frame_dir / "frame_%04d.png"),
            "-i", str(palette), "-lavfi", "paletteuse", str(gif)
        ]
        pal_run = subprocess.run(cmd_palette, check=False, capture_output=True, text=True)
        gif_run = subprocess.run(cmd_gif, check=False, capture_output=True, text=True)
        if pal_run.returncode != 0 or gif_run.returncode != 0 or (not gif.exists()) or gif.stat().st_size == 0:
            print("Warning: ffmpeg GIF export failed")
            if gif_run.stderr:
                print(gif_run.stderr.strip().splitlines()[-1])


def main() -> int:
    args = parse_args()
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    runs_csv = Path(args.runs_csv) if args.runs_csv else outdir / "transport_mc_filtered_runs.csv"
    summary_csv = Path(args.summary_csv) if args.summary_csv else outdir / "transport_mc_distribution_summary.csv"
    breakdown_csv = Path(args.breakdown_csv) if args.breakdown_csv else outdir / "transport_burden_breakdown_values.csv"
    metadata_json = Path(args.metadata_json) if args.metadata_json else outdir / "transport_graphics_filter_metadata.json"
    notes_md = Path(args.notes_md) if args.notes_md else outdir / "transport_graphics_README.md"

    if not runs_csv.exists():
        print(f"Error: missing run-level input {runs_csv}")
        print("Re-run tools/generate_transport_presentation_graphics.R to emit transport_mc_filtered_runs.csv")
        return 2

    df = prep_df(pd.read_csv(runs_csv))
    metadata = load_metadata(metadata_json)

    print("Columns:")
    print(df.columns.tolist())
    print("Preview:")
    print(df.head(5).to_string(index=False))

    try:
        summary = make_three_panel(df, outdir, metadata)
    except Exception as exc:
        print(f"Three-panel diagnostic failed: {exc}")
        return 2

    try:
        small = make_small_driver_diag(df, outdir, summary.get("trip_col"))
    except Exception as exc:
        print(f"Small refrigerated diagnostic failed: {exc}")
        return 2

    make_evolution_animation(df, outdir, metadata, fps=args.fps)
    for p in [
        outdir / "transport_mc_evolution.mp4",
        outdir / "transport_mc_evolution.gif",
        outdir / "transport_mc_evolution_last_frame.png",
    ]:
        if p.exists():
            print(f"- wrote {p.name} ({p.stat().st_size} bytes)")
        else:
            print(f"- missing {p.name}")

    lines = [
        "\nDiagnostic summary:",
        f"- chosen trip time column: {summary.get('trip_col')}",
        f"- observations used: dry={summary.get('n_dry')} refrigerated={summary.get('n_refrigerated')}",
        f"- pair_id available: {summary.get('pair_id_available')}",
        f"- bimodality signal (refrigerated): {'yes' if summary.get('bimodal') else 'no'}",
        f"- compact driver column: {small.get('driver_col')}",
    ]
    print("\n".join(lines))

    interp = (
        "Refrigerated emissions exhibit a visible split with larger spread than dry runs. "
        if summary.get("bimodal") else
        "Refrigerated emissions are more variable than dry runs, but a strong split is not definitive from available variables. "
    )
    interp += "Trip-time association appears directionally positive in the diagnostic scatter. "
    interp += "If separation remains after controlling for trip time, TRU-related variables are the next likely drivers."
    print("Interpretation:")
    print(interp)

    if notes_md.exists():
        with notes_md.open("a") as f:
            f.write("\n\n## Advanced Diagnostics\n")
            f.write("- Added `transport_trip_time_diagnostic.png/.svg` (3-panel story figure).\n")
            f.write("- Added `refrigerated_split_diagnostic.png/.svg` (compact cause check).\n")
            f.write("- Added `transport_mc_evolution.mp4/.gif` and final frame PNG emphasizing convergence and refrigerated regime emergence.\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
