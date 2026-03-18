#!/usr/bin/env python3
"""Generate diesel vs BEV route comparison animation.

Two side-by-side map panels (Latitude vs Longitude) showing route trace
with a live text overlay of cumulative metrics:
  elapsed time, distance, CO2, traffic delay,
  tractor diesel/elec, reefer diesel/elec, charge/refuel stops

Usage:
  python3 tools/generate_route_comparison_animation.py \
    --diesel outputs/sim_tracks/ANALYSIS_CORE_diesel_99999.csv \
    --bev outputs/sim_tracks/ANALYSIS_CORE_bev_99999.csv \
    --outdir artifacts/analysis_final_2026-03-17/animations
"""

import argparse
import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.animation as animation


def load_track(path):
    df = pd.read_csv(path)
    for c in ["distance_miles_cum", "co2_kg_cum", "propulsion_kwh_cum",
              "diesel_gal_cum", "tru_kwh_cum", "tru_gal_cum",
              "traffic_delay_h_cum", "trip_duration_h_cum", "delay_minutes_cum",
              "charge_count", "refuel_count", "lat", "lng"]:
        if c not in df.columns:
            df[c] = 0.0
    # Ensure numeric
    for c in df.columns:
        if c not in ("t", "route_id", "truck_id", "scenario", "fuel_type_label"):
            df[c] = pd.to_numeric(df[c], errors="coerce").fillna(0)
    return df


def make_comparison(diesel_df, bev_df, outdir, max_frames=240, fps=24):
    fig, (ax_d, ax_b) = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle("Diesel vs BEV Route Comparison", fontsize=14, fontweight="bold")

    # Compute shared axis limits from both tracks
    all_lng = np.concatenate([diesel_df["lng"].values, bev_df["lng"].values])
    all_lat = np.concatenate([diesel_df["lat"].values, bev_df["lat"].values])
    lng_pad = (all_lng.max() - all_lng.min()) * 0.05
    lat_pad = (all_lat.max() - all_lat.min()) * 0.05
    xlim = (all_lng.min() - lng_pad, all_lng.max() + lng_pad)
    ylim = (all_lat.min() - lat_pad, all_lat.max() + lat_pad)

    for ax, title in [(ax_d, "Diesel representative"), (ax_b, "BEV representative")]:
        ax.set_xlim(xlim)
        ax.set_ylim(ylim)
        ax.set_xlabel("Longitude")
        ax.set_ylabel("Latitude")
        ax.set_title(title, fontweight="bold")
        ax.set_aspect("auto")

    # Pre-draw full route as light gray background
    ax_d.plot(diesel_df["lng"], diesel_df["lat"], color="#d0d0d0", linewidth=1, zorder=1)
    ax_b.plot(bev_df["lng"], bev_df["lat"], color="#d0d0d0", linewidth=1, zorder=1)

    # Animated elements
    line_d, = ax_d.plot([], [], color="#1f77b4", linewidth=2, zorder=2)
    dot_d, = ax_d.plot([], [], "o", color="#1f77b4", markersize=6, zorder=3)
    line_b, = ax_b.plot([], [], color="#d4880f", linewidth=2, zorder=2)
    dot_b, = ax_b.plot([], [], "o", color="#d4880f", markersize=6, zorder=3)

    # Text boxes for live stats
    box_props = dict(boxstyle="round,pad=0.4", facecolor="white", alpha=0.85, edgecolor="#888")
    text_d = ax_d.text(0.02, 0.98, "", transform=ax_d.transAxes, fontsize=7.5,
                       verticalalignment="top", fontfamily="monospace", bbox=box_props, zorder=4)
    text_b = ax_b.text(0.02, 0.98, "", transform=ax_b.transAxes, fontsize=7.5,
                       verticalalignment="top", fontfamily="monospace", bbox=box_props, zorder=4)

    # Sync both tracks by normalized progress (0..1)
    n_d = len(diesel_df)
    n_b = len(bev_df)

    def format_stats(row, is_bev):
        elapsed = row["trip_duration_h_cum"]
        dist = row["distance_miles_cum"]
        co2 = row["co2_kg_cum"]
        delay = row.get("delay_minutes_cum", row.get("traffic_delay_h_cum", 0) * 60)

        if is_bev:
            tract = f"traction elec: {row['propulsion_kwh_cum']:.1f} kWh"
            reefer = f"reefer elec: {row['tru_kwh_cum']:.1f} kWh"
            stops = f"charge stops: {int(row['charge_count'])}"
        else:
            tract = f"tractor diesel: {row['diesel_gal_cum']:.2f} gal"
            reefer = f"reefer diesel: {row['tru_gal_cum']:.2f} gal"
            stops = f"refuel stops: {int(row['refuel_count'])}"

        return (f"elapsed: {elapsed:.2f} h\n"
                f"distance: {dist:.1f} mi\n"
                f"CO2 cum: {co2:.2f} kg\n"
                f"traffic delay: {delay:.1f} min\n"
                f"{tract}\n"
                f"{reefer}\n"
                f"{stops}")

    def update(frame):
        frac = (frame + 1) / max_frames
        id_d = min(int(frac * n_d), n_d - 1)
        id_b = min(int(frac * n_b), n_b - 1)

        # Diesel trace
        line_d.set_data(diesel_df["lng"][:id_d + 1], diesel_df["lat"][:id_d + 1])
        dot_d.set_data([diesel_df["lng"].iloc[id_d]], [diesel_df["lat"].iloc[id_d]])
        text_d.set_text(format_stats(diesel_df.iloc[id_d], is_bev=False))

        # BEV trace
        line_b.set_data(bev_df["lng"][:id_b + 1], bev_df["lat"][:id_b + 1])
        dot_b.set_data([bev_df["lng"].iloc[id_b]], [bev_df["lat"].iloc[id_b]])
        text_b.set_text(format_stats(bev_df.iloc[id_b], is_bev=True))

        return line_d, dot_d, text_d, line_b, dot_b, text_b

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    anim = animation.FuncAnimation(fig, update, frames=max_frames,
                                   interval=1000 // fps, blit=False)

    out_mp4 = os.path.join(outdir, "route_comparison_diesel_vs_bev.mp4")
    anim.save(out_mp4, writer="ffmpeg", fps=fps, dpi=120)
    print(f"  Wrote {out_mp4}")

    # Save last frame
    update(max_frames - 1)
    out_png = os.path.join(outdir, "route_comparison_diesel_vs_bev_last_frame.png")
    fig.savefig(out_png, dpi=150, bbox_inches="tight")
    print(f"  Wrote {out_png}")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--diesel", required=True)
    parser.add_argument("--bev", required=True)
    parser.add_argument("--outdir", default="artifacts/analysis_final_2026-03-17/animations")
    parser.add_argument("--max_frames", type=int, default=240)
    parser.add_argument("--fps", type=int, default=24)
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    print(f"Loading diesel: {args.diesel}")
    diesel_df = load_track(args.diesel)
    print(f"  {len(diesel_df)} segments, {diesel_df['distance_miles_cum'].iloc[-1]:.0f} mi")

    print(f"Loading BEV: {args.bev}")
    bev_df = load_track(args.bev)
    print(f"  {len(bev_df)} segments, {bev_df['distance_miles_cum'].iloc[-1]:.0f} mi")

    print("Generating route comparison animation...")
    make_comparison(diesel_df, bev_df, args.outdir, args.max_frames, args.fps)
    print("DONE")


if __name__ == "__main__":
    main()
