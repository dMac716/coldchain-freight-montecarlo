#!/usr/bin/env python3
"""Generate MP4 animations from the validated analysis dataset.

Produces:
  - transport_mc_evolution.mp4: CO2/1000kcal convergence as sample size grows
  - transport_mc_animation.mp4: animated density of CO2 by scenario
  - transport_diesel_vs_bev.mp4: side-by-side diesel vs BEV CO2 accumulation

Usage:
  python3 tools/generate_analysis_animations.py --csv <dataset.csv> --outdir <dir>
"""

import argparse
import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.animation as animation

def load_data(csv_path):
    df = pd.read_csv(csv_path, low_memory=False)
    # Derive FU if missing
    if df["co2_per_1000kcal"].isna().all():
        df["payload_kg"] = df["payload_max_lb_draw"] * df["load_fraction"] * 0.453592
        df["kcal_delivered"] = df["payload_kg"] * df["kcal_per_kg_product"]
        df["co2_per_1000kcal"] = df["co2_kg_total"] / df["kcal_delivered"] * 1000
    return df

def make_evolution(df, outdir, max_frames=120):
    """CO2/1000kcal running mean convergence as n grows."""
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("Monte Carlo Convergence: CO2 per 1000 kcal", fontsize=14, fontweight="bold")

    scenarios = [
        ("diesel", "dry", "Diesel Dry", "coral"),
        ("bev", "dry", "BEV Dry", "steelblue"),
    ]

    lines = []
    data_arrays = []
    n_texts = []
    for ax, (pw, pt, label, color) in zip(axes, scenarios):
        sub = df[(df["powertrain"] == pw) & (df["product_type"] == pt)]["co2_per_1000kcal"].dropna().values
        sub = sub.copy()
        np.random.seed(42)
        np.random.shuffle(sub)
        data_arrays.append(sub)
        ax.set_xlim(1, len(sub))
        ax.set_ylim(0, max(sub.mean() * 2, 0.001))
        ax.set_xlabel("Sample size")
        ax.set_ylabel("Running mean CO2/1000kcal")
        ax.set_title(label, color=color, fontweight="bold")
        line, = ax.plot([], [], color=color, linewidth=2)
        lines.append(line)
        n_text = ax.text(0.98, 0.95, "", transform=ax.transAxes, fontsize=11,
                         fontweight="bold", ha="right", va="top",
                         bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.85))
        n_texts.append(n_text)

    step = max(1, max(len(a) for a in data_arrays) // max_frames)

    def update(frame):
        n = min((frame + 1) * step, max(len(a) for a in data_arrays))
        for i, (line, arr) in enumerate(zip(lines, data_arrays)):
            k = min(n, len(arr))
            if k > 0:
                cumsum = np.cumsum(arr[:k])
                means = cumsum / np.arange(1, k + 1)
                line.set_data(np.arange(1, k + 1), means)
                axes[i].set_xlim(1, max(k, 2))
                if len(means) > 10:
                    axes[i].set_ylim(means[-1] * 0.5, means[-1] * 1.5)
                n_texts[i].set_text(f"N = {k:,}\nmean = {means[-1]:.4f}")
        return lines + n_texts

    n_frames = min(max_frames, max(len(a) for a in data_arrays) // step)
    anim = animation.FuncAnimation(fig, update, frames=n_frames, interval=50, blit=False)
    out_path = os.path.join(outdir, "transport_mc_evolution.mp4")
    anim.save(out_path, writer="ffmpeg", fps=24, dpi=100)
    plt.close(fig)

    # Save last frame
    fig2, axes2 = plt.subplots(1, 2, figsize=(12, 5))
    fig2.suptitle("Monte Carlo Convergence: CO2 per 1000 kcal (Final)", fontsize=14, fontweight="bold")
    for ax, (pw, pt, label, color) in zip(axes2, scenarios):
        sub = df[(df["powertrain"] == pw) & (df["product_type"] == pt)]["co2_per_1000kcal"].dropna().values
        cumsum = np.cumsum(sub)
        means = cumsum / np.arange(1, len(sub) + 1)
        ax.plot(np.arange(1, len(sub) + 1), means, color=color, linewidth=2)
        ax.set_xlabel("Sample size")
        ax.set_ylabel("Running mean CO2/1000kcal")
        ax.set_title(f"{label} (n={len(sub)})", color=color, fontweight="bold")
        ax.axhline(means[-1], color="gray", linestyle="--", alpha=0.5)
    fig2.tight_layout()
    fig2.savefig(os.path.join(outdir, "transport_mc_evolution_last_frame.png"), dpi=150)
    plt.close(fig2)
    print(f"  Wrote {out_path}")

def make_density_animation(df, outdir, max_frames=80):
    """Animated kernel density of CO2/1000kcal by powertrain."""
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.set_xlabel("CO2 per 1000 kcal")
    ax.set_ylabel("Density")
    ax.set_title("Emissions Distribution: Diesel vs BEV", fontsize=14, fontweight="bold")

    diesel = df[df["powertrain"] == "diesel"]["co2_per_1000kcal"].dropna().values
    bev = df[df["powertrain"] == "bev"]["co2_per_1000kcal"].dropna().values
    all_vals = np.concatenate([diesel, bev])
    xmin, xmax = np.percentile(all_vals, 1), np.percentile(all_vals, 99)
    x = np.linspace(xmin, xmax, 200)

    step_d = max(1, len(diesel) // max_frames)
    step_b = max(1, len(bev) // max_frames)

    def update(frame):
        ax.clear()
        nd = min((frame + 1) * step_d, len(diesel))
        nb = min((frame + 1) * step_b, len(bev))
        if nd > 10:
            from scipy.stats import gaussian_kde
            kde_d = gaussian_kde(diesel[:nd])
            ax.fill_between(x, kde_d(x), alpha=0.5, color="coral", label=f"Diesel (n={nd})")
        if nb > 10:
            from scipy.stats import gaussian_kde
            kde_b = gaussian_kde(bev[:nb])
            ax.fill_between(x, kde_b(x), alpha=0.5, color="steelblue", label=f"BEV (n={nb})")
        ax.set_xlim(xmin, xmax)
        ax.set_xlabel("CO2 per 1000 kcal")
        ax.set_ylabel("Density")
        ax.set_title("Emissions Distribution: Diesel vs BEV", fontsize=14, fontweight="bold")
        ax.legend(loc="upper right")

    n_frames = min(max_frames, max(len(diesel) // step_d, len(bev) // step_b))
    anim = animation.FuncAnimation(fig, update, frames=n_frames, interval=80, blit=False)
    out_path = os.path.join(outdir, "transport_mc_animation.mp4")
    anim.save(out_path, writer="ffmpeg", fps=20, dpi=100)
    plt.close(fig)

    # Last frame
    fig2, ax2 = plt.subplots(figsize=(10, 6))
    from scipy.stats import gaussian_kde
    kde_d = gaussian_kde(diesel)
    kde_b = gaussian_kde(bev)
    ax2.fill_between(x, kde_d(x), alpha=0.5, color="coral", label=f"Diesel (n={len(diesel)})")
    ax2.fill_between(x, kde_b(x), alpha=0.5, color="steelblue", label=f"BEV (n={len(bev)})")
    ax2.set_xlabel("CO2 per 1000 kcal")
    ax2.set_ylabel("Density")
    ax2.set_title("Emissions Distribution: Diesel vs BEV (Final)", fontsize=14, fontweight="bold")
    ax2.legend()
    fig2.tight_layout()
    fig2.savefig(os.path.join(outdir, "transport_mc_animation_last_frame.png"), dpi=150)
    plt.close(fig2)
    print(f"  Wrote {out_path}")

def make_diesel_vs_bev(df, outdir, max_frames=100):
    """Side-by-side CO2 comparison: diesel vs BEV by product type."""
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("Diesel vs BEV: Transport CO2 Comparison", fontsize=14, fontweight="bold")

    for ax, pt in zip(axes, ["refrigerated", "dry"]):
        sub = df[df["product_type"] == pt]
        diesel_co2 = sub[sub["powertrain"] == "diesel"]["co2_per_1000kcal"].dropna().values
        bev_co2 = sub[sub["powertrain"] == "bev"]["co2_per_1000kcal"].dropna().values

        step = max(1, max(len(diesel_co2), len(bev_co2)) // max_frames)
        positions = list(range(0, max(len(diesel_co2), len(bev_co2)), step))

        d_means = [np.mean(diesel_co2[:max(1, p)]) for p in positions] if len(diesel_co2) > 0 else [0] * len(positions)
        b_means = [np.mean(bev_co2[:max(1, p)]) for p in positions] if len(bev_co2) > 0 else [0] * len(positions)

        ax.bar([0, 1], [np.mean(diesel_co2) if len(diesel_co2) > 0 else 0,
                        np.mean(bev_co2) if len(bev_co2) > 0 else 0],
               color=["coral", "steelblue"], width=0.6)
        ax.set_xticks([0, 1])
        ax.set_xticklabels(["Diesel", "BEV"])
        ax.set_ylabel("CO2 per 1000 kcal")
        ax.set_title(f"{pt.capitalize()} Product")

        # Add value labels
        for i, v in enumerate([np.mean(diesel_co2) if len(diesel_co2) > 0 else 0,
                                np.mean(bev_co2) if len(bev_co2) > 0 else 0]):
            ax.text(i, v + 0.001, f"{v:.4f}", ha="center", fontweight="bold", fontsize=10)

    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "transport_diesel_vs_bev_last_frame.png"), dpi=150)

    # Animated version
    fig2, axes2 = plt.subplots(1, 2, figsize=(12, 5))
    fig2.suptitle("Diesel vs BEV: Transport CO2 Comparison", fontsize=14, fontweight="bold")
    bars = []
    data_pairs = []
    val_texts = []
    for ax, pt in zip(axes2, ["refrigerated", "dry"]):
        sub = df[df["product_type"] == pt]
        d = sub[sub["powertrain"] == "diesel"]["co2_per_1000kcal"].dropna().values
        b = sub[sub["powertrain"] == "bev"]["co2_per_1000kcal"].dropna().values
        data_pairs.append((d, b))
        bar = ax.bar([0, 1], [0, 0], color=["coral", "steelblue"], width=0.6)
        bars.append(bar)
        ax.set_xticks([0, 1])
        ax.set_xticklabels(["Diesel", "BEV"])
        ax.set_ylabel("CO2 per 1000 kcal")
        ax.set_title(f"{pt.capitalize()} Product")
        ymax = max(np.mean(d) if len(d) > 0 else 0.01, np.mean(b) if len(b) > 0 else 0.01) * 1.3
        ax.set_ylim(0, ymax)
        t_d = ax.text(0, 0, "", ha="center", fontweight="bold", fontsize=9)
        t_b = ax.text(1, 0, "", ha="center", fontweight="bold", fontsize=9)
        val_texts.append((t_d, t_b))

    step = max(1, max(len(d) for d, b in data_pairs) // max_frames)

    def update(frame):
        n = (frame + 1) * step
        for i, (bar, (d, b)) in enumerate(zip(bars, data_pairs)):
            nd, nb = min(n, len(d)), min(n, len(b))
            dv = np.mean(d[:nd]) if nd > 0 else 0
            bv = np.mean(b[:nb]) if nb > 0 else 0
            bar[0].set_height(dv)
            bar[1].set_height(bv)
            val_texts[i][0].set_position((0, dv + 0.001))
            val_texts[i][0].set_text(f"{dv:.4f}\nn={nd:,}")
            val_texts[i][1].set_position((1, bv + 0.001))
            val_texts[i][1].set_text(f"{bv:.4f}\nn={nb:,}")
        return [b for bar in bars for b in bar]

    n_frames = min(max_frames, max(len(d) for d, b in data_pairs) // step)
    anim = animation.FuncAnimation(fig2, update, frames=n_frames, interval=60, blit=False)
    out_path = os.path.join(outdir, "transport_diesel_vs_bev.mp4")
    anim.save(out_path, writer="ffmpeg", fps=20, dpi=100)
    plt.close(fig2)
    plt.close(fig)
    print(f"  Wrote {out_path}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True)
    parser.add_argument("--outdir", default="artifacts/analysis_final_2026-03-17/animations")
    parser.add_argument("--max_frames", type=int, default=120)
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    print(f"Loading {args.csv}...")
    df = load_data(args.csv)
    print(f"Loaded {len(df)} rows")

    # Filter to standard networks for fair comparison
    std_nets = ["dry_factory_set", "refrigerated_factory_set"]
    df = df[df["origin_network"].isin(std_nets)].copy()
    print(f"Filtered to standard networks: {len(df)} rows")

    print("Generating MC evolution animation...")
    make_evolution(df, args.outdir, args.max_frames)

    print("Generating density animation...")
    try:
        make_density_animation(df, args.outdir, min(args.max_frames, 80))
    except ImportError:
        print("  SKIP: scipy not available for KDE")

    print("Generating diesel vs BEV animation...")
    make_diesel_vs_bev(df, args.outdir, args.max_frames)

    print("DONE")

if __name__ == "__main__":
    main()
