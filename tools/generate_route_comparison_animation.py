#!/usr/bin/env python3
"""Generate diesel vs BEV route comparison animations.

Produces two animations:
  1. DRY product: diesel vs BEV (no reefer)
  2. REFRIGERATED product: diesel vs BEV (with reefer)

Each shows two side-by-side Lat/Lng map panels with:
  - Route trace (blue=diesel, gold=BEV)
  - Live text overlay: elapsed time, distance, CO2, traffic delay,
    tractor diesel/elec, reefer diesel/elec, charge/refuel stops
  - Triangle markers for charge stops (green) and refuel stops (red)

Usage:
  python3 tools/generate_route_comparison_animation.py --synthesize
"""

import argparse, os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.animation as animation


def load_track(path):
    df = pd.read_csv(path)
    for c in ["distance_miles_cum","co2_kg_cum","propulsion_kwh_cum","diesel_gal_cum",
              "tru_kwh_cum","tru_gal_cum","traffic_delay_h_cum","trip_duration_h_cum",
              "delay_minutes_cum","charge_count","refuel_count","lat","lng"]:
        if c not in df.columns:
            df[c] = 0.0
    for c in df.columns:
        if c not in ("t","route_id","truck_id","scenario","fuel_type_label"):
            df[c] = pd.to_numeric(df[c], errors="coerce").fillna(0)
    return df


def synthesize_track(route_pts_csv, summary_str, is_bev=False):
    pts = pd.read_csv(route_pts_csv)
    s = {}
    for kv in summary_str.split(","):
        k, v = kv.split("=")
        s[k.strip()] = float(v.strip())

    n = len(pts)
    frac = np.linspace(0, 1, n)
    lng_col = "lon" if "lon" in pts.columns else "lng"

    df = pd.DataFrame({
        "lat": pts["lat"].values,
        "lng": pts[lng_col].values,
        "distance_miles_cum": frac * s.get("dist", 1712),
        "co2_kg_cum": frac * s.get("co2", 1000),
        "trip_duration_h_cum": frac * s.get("trip_h", 24),
        "delay_minutes_cum": frac * s.get("delay_min", 0),
    })

    if is_bev:
        df["propulsion_kwh_cum"] = frac * s.get("kwh", 3800)
        df["tru_kwh_cum"] = frac * s.get("tru_kwh", 0)
        df["diesel_gal_cum"] = 0.0
        df["tru_gal_cum"] = 0.0
        charges = int(s.get("charges", 16))
        df["charge_count"] = np.minimum(np.floor(frac * (charges + 0.5)).astype(int), charges)
        df["refuel_count"] = 0
    else:
        df["diesel_gal_cum"] = frac * s.get("diesel_gal", 260)
        df["tru_gal_cum"] = frac * s.get("tru_gal", 0)
        df["propulsion_kwh_cum"] = 0.0
        df["tru_kwh_cum"] = 0.0
        df["charge_count"] = 0
        refuels = int(s.get("refuels", 0))
        df["refuel_count"] = np.minimum(np.floor(frac * (refuels + 0.5)).astype(int), refuels) if refuels > 0 else np.zeros(n, dtype=int)

    return df


def make_animation(diesel_df, bev_df, outdir, label, max_frames=240, fps=24):
    fig, (ax_d, ax_b) = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle(f"Diesel vs BEV Route Comparison — {label}", fontsize=14, fontweight="bold")

    all_lng = np.concatenate([diesel_df["lng"].values, bev_df["lng"].values])
    all_lat = np.concatenate([diesel_df["lat"].values, bev_df["lat"].values])
    pad_x = (all_lng.max() - all_lng.min()) * 0.05
    pad_y = (all_lat.max() - all_lat.min()) * 0.05
    xlim = (all_lng.min() - pad_x, all_lng.max() + pad_x)
    ylim = (all_lat.min() - pad_y, all_lat.max() + pad_y)

    for ax, title in [(ax_d, "Diesel representative"), (ax_b, "BEV representative")]:
        ax.set_xlim(xlim); ax.set_ylim(ylim)
        ax.set_xlabel("Longitude"); ax.set_ylabel("Latitude")
        ax.set_title(title, fontweight="bold")

    ax_d.plot(diesel_df["lng"], diesel_df["lat"], color="#d0d0d0", linewidth=1, zorder=1)
    ax_b.plot(bev_df["lng"], bev_df["lat"], color="#d0d0d0", linewidth=1, zorder=1)

    line_d, = ax_d.plot([], [], color="#1f77b4", linewidth=2, zorder=2)
    dot_d, = ax_d.plot([], [], "o", color="#1f77b4", markersize=6, zorder=3)
    line_b, = ax_b.plot([], [], color="#d4880f", linewidth=2, zorder=2)
    dot_b, = ax_b.plot([], [], "o", color="#d4880f", markersize=6, zorder=3)

    box_props = dict(boxstyle="round,pad=0.4", facecolor="white", alpha=0.85, edgecolor="#888")
    text_d = ax_d.text(0.98, 0.98, "", transform=ax_d.transAxes, fontsize=7.5,
                       verticalalignment="top", horizontalalignment="right",
                       fontfamily="monospace", bbox=box_props, zorder=5)
    text_b = ax_b.text(0.98, 0.98, "", transform=ax_b.transAxes, fontsize=7.5,
                       verticalalignment="top", horizontalalignment="right",
                       fontfamily="monospace", bbox=box_props, zorder=5)

    prev_d_stops = [0]
    prev_b_stops = [0]
    n_d, n_b = len(diesel_df), len(bev_df)

    def fmt(row, is_bev):
        e = row["trip_duration_h_cum"]
        d = row["distance_miles_cum"]
        c = row["co2_kg_cum"]
        dl = row.get("delay_minutes_cum", 0)
        if is_bev:
            return (f"elapsed: {e:.2f} h\ndistance: {d:.1f} mi\n"
                    f"CO2 cum: {c:.2f} kg\ntraffic delay: {dl:.1f} min\n"
                    f"traction elec: {row['propulsion_kwh_cum']:.1f} kWh\n"
                    f"reefer elec: {row['tru_kwh_cum']:.1f} kWh\n"
                    f"charge stops: {int(row['charge_count'])}")
        else:
            return (f"elapsed: {e:.2f} h\ndistance: {d:.1f} mi\n"
                    f"CO2 cum: {c:.2f} kg\ntraffic delay: {dl:.1f} min\n"
                    f"tractor diesel: {row['diesel_gal_cum']:.2f} gal\n"
                    f"reefer diesel: {row['tru_gal_cum']:.2f} gal\n"
                    f"refuel stops: {int(row['refuel_count'])}")

    def update(frame):
        frac = (frame + 1) / max_frames
        id_d = min(int(frac * n_d), n_d - 1)
        id_b = min(int(frac * n_b), n_b - 1)

        line_d.set_data(diesel_df["lng"][:id_d+1], diesel_df["lat"][:id_d+1])
        dot_d.set_data([diesel_df["lng"].iloc[id_d]], [diesel_df["lat"].iloc[id_d]])
        text_d.set_text(fmt(diesel_df.iloc[id_d], False))

        line_b.set_data(bev_df["lng"][:id_b+1], bev_df["lat"][:id_b+1])
        dot_b.set_data([bev_df["lng"].iloc[id_b]], [bev_df["lat"].iloc[id_b]])
        text_b.set_text(fmt(bev_df.iloc[id_b], True))

        cur_d = int(diesel_df["refuel_count"].iloc[id_d])
        if cur_d > prev_d_stops[0]:
            ax_d.plot(diesel_df["lng"].iloc[id_d], diesel_df["lat"].iloc[id_d],
                     "^", color="red", markersize=8, zorder=4)
            prev_d_stops[0] = cur_d

        cur_b = int(bev_df["charge_count"].iloc[id_b])
        if cur_b > prev_b_stops[0]:
            ax_b.plot(bev_df["lng"].iloc[id_b], bev_df["lat"].iloc[id_b],
                     "^", color="limegreen", markersize=8, zorder=4)
            prev_b_stops[0] = cur_b

        return line_d, dot_d, text_d, line_b, dot_b, text_b

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    anim = animation.FuncAnimation(fig, update, frames=max_frames, interval=1000//fps, blit=False)

    safe = label.lower().replace(" ", "_")
    out_mp4 = os.path.join(outdir, f"route_comparison_{safe}.mp4")
    anim.save(out_mp4, writer="ffmpeg", fps=fps, dpi=120)
    print(f"  Wrote {out_mp4}")

    update(max_frames - 1)
    out_png = os.path.join(outdir, f"route_comparison_{safe}_last_frame.png")
    fig.savefig(out_png, dpi=150, bbox_inches="tight")
    print(f"  Wrote {out_png}")
    plt.close(fig)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--diesel", default="")
    p.add_argument("--bev", default="")
    p.add_argument("--synthesize", action="store_true")
    p.add_argument("--outdir", default="artifacts/analysis_final_2026-03-17/animations")
    p.add_argument("--max_frames", type=int, default=240)
    p.add_argument("--fps", type=int, default=24)
    args = p.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    if args.synthesize or (not args.diesel and not args.bev):
        ennis = "/tmp/route_ennis_pts.csv"
        topeka = "/tmp/route_topeka_pts.csv"
        if not os.path.exists(ennis) or not os.path.exists(topeka):
            print("ERROR: Run R route extraction first")
            return

        # REFRIGERATED (Ennis, TRU on)
        # Values from master_validated (75,443 runs): diesel refrig mean + BEV refrig mean
        print("=== Refrigerated: Diesel vs BEV ===")
        d_r = synthesize_track(ennis,
            "dist=617,co2=1015,diesel_gal=88,tru_gal=11.2,refuels=0,trip_h=12.7,delay_min=6", False)
        b_r = synthesize_track(ennis,
            "dist=1743,co2=1947,kwh=4045,tru_kwh=439,charges=17,trip_h=91,delay_min=15", True)
        make_animation(d_r, b_r, args.outdir, "Refrigerated", args.max_frames, args.fps)

        # DRY (Topeka, TRU off)
        print("=== Dry: Diesel vs BEV ===")
        d_d = synthesize_track(topeka,
            "dist=736,co2=1221,diesel_gal=106,tru_gal=0,refuels=0,trip_h=15.2,delay_min=14", False)
        b_d = synthesize_track(topeka,
            "dist=1743,co2=1738,kwh=4025,tru_kwh=0,charges=15,trip_h=86,delay_min=11", True)
        make_animation(d_d, b_d, args.outdir, "Dry", args.max_frames, args.fps)

        # COMBINED diesel vs BEV (Ennis route, refrigerated representative)
        print("=== Diesel vs BEV ===")
        d_c = synthesize_track(ennis,
            "dist=617,co2=1015,diesel_gal=88,tru_gal=11.2,refuels=1,trip_h=12.7,delay_min=6", False)
        b_c = synthesize_track(ennis,
            "dist=1743,co2=1947,kwh=4045,tru_kwh=439,charges=17,trip_h=91,delay_min=15", True)
        make_animation(d_c, b_c, args.outdir, "diesel_vs_bev", args.max_frames, args.fps)
    else:
        diesel_df = load_track(args.diesel)
        bev_df = load_track(args.bev)
        make_animation(diesel_df, bev_df, args.outdir, "diesel_vs_bev", args.max_frames, args.fps)

    print("DONE")


if __name__ == "__main__":
    main()
