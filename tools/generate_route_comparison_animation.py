#!/usr/bin/env python3
"""Generate diesel vs BEV route comparison animation.

Shows side-by-side panels plotting cumulative metrics against longitude/latitude:
- Elapsed time, distance, CO2, traffic delay
- Traction electricity / diesel fuel
- Reefer energy, charge/refuel stops

Uses sim track CSVs (one diesel, one BEV) with columns:
  t, lat, lng, distance_miles_cum, co2_kg_cum, propulsion_kwh_cum,
  diesel_gal_cum, tru_kwh_cum, tru_gal_cum, traffic_delay_h_cum,
  charge_count, refuel_count, trip_duration_h_cum

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
from matplotlib.gridspec import GridSpec

def load_track(path):
    df = pd.read_csv(path)
    for c in ["distance_miles_cum", "co2_kg_cum", "propulsion_kwh_cum",
              "diesel_gal_cum", "tru_kwh_cum", "tru_gal_cum",
              "traffic_delay_h_cum", "trip_duration_h_cum",
              "charge_count", "refuel_count", "lat", "lng"]:
        if c not in df.columns:
            df[c] = 0.0
    return df

def make_comparison(diesel_df, bev_df, outdir, max_frames=200):
    fig = plt.figure(figsize=(16, 14))
    fig.suptitle("Diesel vs BEV: Refrigerated Route Comparison\n(Ennis TX → Davis CA, ~1,774 mi)",
                 fontsize=14, fontweight="bold", y=0.98)

    gs = GridSpec(4, 2, figure=fig, hspace=0.35, wspace=0.3,
                  left=0.08, right=0.95, top=0.93, bottom=0.05)

    # 8 subplots: 4 rows x 2 cols
    ax_map = fig.add_subplot(gs[0, :])  # map spans both cols
    ax_time = fig.add_subplot(gs[1, 0])
    ax_dist = fig.add_subplot(gs[1, 1])
    ax_co2 = fig.add_subplot(gs[2, 0])
    ax_delay = fig.add_subplot(gs[2, 1])
    ax_tract = fig.add_subplot(gs[3, 0])
    ax_reefer = fig.add_subplot(gs[3, 1])

    axes = [ax_map, ax_time, ax_dist, ax_co2, ax_delay, ax_tract, ax_reefer]

    # Set up static axis labels
    ax_map.set_xlabel("Longitude")
    ax_map.set_ylabel("Latitude")
    ax_map.set_title("Route Progress")

    panels = [
        (ax_time, "Elapsed Time (h)", "trip_duration_h_cum"),
        (ax_dist, "Distance (mi)", "distance_miles_cum"),
        (ax_co2, "Cumulative CO2 (kg)", "co2_kg_cum"),
        (ax_delay, "Traffic Delay (h)", "traffic_delay_h_cum"),
    ]

    # Determine shared step
    n_d = len(diesel_df)
    n_b = len(bev_df)
    n_max = max(n_d, n_b)
    step = max(1, n_max // max_frames)

    def draw_frame(frame):
        idx = min((frame + 1) * step, n_max)
        id_d = min(idx, n_d - 1)
        id_b = min(idx, n_b - 1)

        for a in axes:
            a.clear()

        # Map
        ax_map.plot(diesel_df["lng"][:id_d], diesel_df["lat"][:id_d],
                    color="coral", linewidth=2, alpha=0.8, label="Diesel")
        ax_map.plot(bev_df["lng"][:id_b], bev_df["lat"][:id_b],
                    color="steelblue", linewidth=2, alpha=0.8, label="BEV")
        ax_map.scatter([diesel_df["lng"].iloc[0]], [diesel_df["lat"].iloc[0]],
                       c="green", s=80, zorder=5, marker="^", label="Origin")
        if id_d > 0:
            ax_map.scatter([diesel_df["lng"].iloc[id_d]],
                          [diesel_df["lat"].iloc[id_d]],
                          c="coral", s=60, zorder=5, marker="o")
        if id_b > 0:
            ax_map.scatter([bev_df["lng"].iloc[id_b]],
                          [bev_df["lat"].iloc[id_b]],
                          c="steelblue", s=60, zorder=5, marker="o")
        ax_map.set_xlabel("Longitude")
        ax_map.set_ylabel("Latitude")
        ax_map.legend(loc="upper left", fontsize=8)
        ax_map.set_title("Route Progress")

        # Metric panels
        for ax, ylabel, col in panels:
            ax.plot(range(id_d), diesel_df[col][:id_d], color="coral", linewidth=1.5)
            ax.plot(range(id_b), bev_df[col][:id_b], color="steelblue", linewidth=1.5)
            ax.set_ylabel(ylabel, fontsize=9)
            ax.set_xlabel("Segment", fontsize=8)
            # Add current value labels
            if id_d > 0:
                val_d = diesel_df[col].iloc[id_d]
                ax.annotate(f"D:{val_d:.1f}", xy=(id_d, val_d),
                           fontsize=7, color="coral", fontweight="bold")
            if id_b > 0:
                val_b = bev_df[col].iloc[id_b]
                ax.annotate(f"B:{val_b:.1f}", xy=(id_b, val_b),
                           fontsize=7, color="steelblue", fontweight="bold")

        # Traction energy
        ax_tract.plot(range(id_d), diesel_df["diesel_gal_cum"][:id_d],
                      color="coral", linewidth=1.5, label="Diesel gal")
        ax_tract.plot(range(id_b), bev_df["propulsion_kwh_cum"][:id_b] / 33.7,
                      color="steelblue", linewidth=1.5, label="BEV kWh/33.7")
        ax_tract.set_ylabel("Traction Energy (gal equiv)", fontsize=9)
        ax_tract.set_xlabel("Segment", fontsize=8)
        ax_tract.legend(fontsize=7, loc="upper left")

        # Reefer + stops
        ax_reefer.plot(range(id_d), diesel_df["tru_gal_cum"][:id_d],
                       color="coral", linewidth=1.5, linestyle="--", label="Diesel TRU gal")
        ax_reefer.plot(range(id_b), bev_df["tru_kwh_cum"][:id_b] / 33.7,
                       color="steelblue", linewidth=1.5, linestyle="--", label="BEV TRU kWh/33.7")
        # Charge/refuel counts as step
        ax_r2 = ax_reefer.twinx()
        ax_r2.step(range(id_d), diesel_df["refuel_count"][:id_d],
                   color="coral", linewidth=1, alpha=0.5, where="post")
        ax_r2.step(range(id_b), bev_df["charge_count"][:id_b],
                   color="steelblue", linewidth=1, alpha=0.5, where="post")
        ax_r2.set_ylabel("Stops", fontsize=8, color="gray")
        ax_reefer.set_ylabel("Reefer Energy (gal equiv)", fontsize=9)
        ax_reefer.set_xlabel("Segment", fontsize=8)
        ax_reefer.legend(fontsize=7, loc="upper left")

    n_frames = min(max_frames, n_max // step)
    anim = animation.FuncAnimation(fig, draw_frame, frames=n_frames,
                                   interval=50, blit=False)

    out_mp4 = os.path.join(outdir, "route_comparison_diesel_vs_bev.mp4")
    anim.save(out_mp4, writer="ffmpeg", fps=24, dpi=100)
    plt.close(fig)
    print(f"  Wrote {out_mp4}")

    # Last frame as PNG
    fig2 = plt.figure(figsize=(16, 14))
    fig2.suptitle("Diesel vs BEV: Refrigerated Route Comparison (Final)",
                  fontsize=14, fontweight="bold", y=0.98)
    draw_frame(n_frames - 1)
    out_png = os.path.join(outdir, "route_comparison_diesel_vs_bev_last_frame.png")
    fig.savefig(out_png, dpi=150, bbox_inches="tight")
    plt.close(fig2)
    print(f"  Wrote {out_png}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--diesel", required=True)
    parser.add_argument("--bev", required=True)
    parser.add_argument("--outdir", default="artifacts/analysis_final_2026-03-17/animations")
    parser.add_argument("--max_frames", type=int, default=200)
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    print(f"Loading diesel: {args.diesel}")
    diesel_df = load_track(args.diesel)
    print(f"  {len(diesel_df)} segments, {diesel_df['distance_miles_cum'].iloc[-1]:.0f} mi")

    print(f"Loading BEV: {args.bev}")
    bev_df = load_track(args.bev)
    print(f"  {len(bev_df)} segments, {bev_df['distance_miles_cum'].iloc[-1]:.0f} mi")

    print("Generating route comparison animation...")
    make_comparison(diesel_df, bev_df, args.outdir, args.max_frames)
    print("DONE")

if __name__ == "__main__":
    main()
