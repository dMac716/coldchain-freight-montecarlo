#!/bin/bash
set -euo pipefail

# Sentry error reporting (requires SENTRY_DSN env var)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/lib/sentry_report.sh" ]; then
  source "${SCRIPT_DIR}/lib/sentry_report.sh"
elif [ -f "tools/lib/sentry_report.sh" ]; then
  source "tools/lib/sentry_report.sh"
fi
# Full GCS Audit + Graphics Pipeline
# Runs on GCP VM: installs deps, pulls all tarballs, merges, generates stats + graphics
# Uploads results bundle back to GCS

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

GCS_RERUNS="gs://coldchain-freight-sources/reruns_bev_fix"
GCS_LOCAL="gs://coldchain-freight-sources/local_backup"
GCS_OUTPUT="gs://coldchain-freight-sources/audit_2026-03-17"
AUDIT_DIR="/tmp/audit_bundle"
STAGING="/tmp/audit_staging"

rm -rf "$AUDIT_DIR" "$STAGING"
mkdir -p "$AUDIT_DIR/figures" "$AUDIT_DIR/tables" "$STAGING/tarballs" "$STAGING/extracted"

# ============================================================
echo "[audit] === Step 0: Install dependencies ==="
# ============================================================
# Python deps are optional (only needed for advanced diagnostics/animations).
# Try venv first, fall back to --break-system-packages, or skip.
PYTHON_BIN="python3"
if python3 -m venv /tmp/audit_venv 2>/dev/null; then
  /tmp/audit_venv/bin/pip install numpy pandas matplotlib 2>&1 | tail -3
  PYTHON_BIN="/tmp/audit_venv/bin/python3"
elif pip3 install --user --break-system-packages numpy pandas matplotlib 2>/dev/null; then
  echo "[audit] Installed Python deps with --break-system-packages"
else
  echo "[audit] WARN: Python deps not installed — skipping Python-based graphics"
fi

# R deps — ggplot2 is required for the analysis figures
Rscript -e 'for (p in c("ggplot2", "scales", "gridExtra")) { if (!requireNamespace(p, quietly=TRUE)) install.packages(p, repos="https://cloud.r-project.org") }' 2>&1 | tail -5

# ============================================================
echo "[audit] === Step 1: Download all tarballs from GCS ==="
# ============================================================
gsutil -m cp "${GCS_RERUNS}/*.tar.gz" "$STAGING/tarballs/" 2>&1 | tail -3
gsutil -m cp "${GCS_LOCAL}/*.tar.gz" "$STAGING/tarballs/" 2>&1 | tail -3
TARBALL_COUNT=$(ls "$STAGING/tarballs/"*.tar.gz | wc -l)
echo "[audit] Downloaded $TARBALL_COUNT tarballs"

# ============================================================
echo "[audit] === Step 2: Extract ==="
# ============================================================
cd "$STAGING/extracted"
for f in "$STAGING/tarballs/"*.tar.gz; do
  name=$(basename "$f" .tar.gz)
  mkdir -p "$name"
  tar xzf "$f" -C "$name" 2>/dev/null || true
done

# Also include the local run_bundle on this VM
if [ -d /srv/coldchain/repo/outputs/run_bundle ]; then
  echo "[audit] Including local VM run_bundle..."
  ln -sf /srv/coldchain/repo/outputs/run_bundle "$STAGING/extracted/local_vm_bundle"
fi

echo "[audit] Extraction done"

# ============================================================
echo "[audit] === Step 3: Merge summaries ==="
# ============================================================
FIRST=$(find . -name 'summaries.csv' -path '*/pair_*' | head -1)
head -1 "$FIRST" > "$STAGING/all_raw.csv"

# Use find + xargs to avoid "==> filename <==" issue
find . -name 'summaries.csv' -path '*/pair_*' -print0 | \
  xargs -0 -I{} sh -c 'tail -n +2 "$1"' _ {} >> "$STAGING/all_raw.csv"

RAW_COUNT=$(tail -n +2 "$STAGING/all_raw.csv" | wc -l)
echo "[audit] Raw rows: $RAW_COUNT"

# ============================================================
echo "[audit] === Step 4: Deduplicate ==="
# ============================================================
head -1 "$STAGING/all_raw.csv" > "$AUDIT_DIR/analysis_dataset_gcs_audit.csv"
tail -n +2 "$STAGING/all_raw.csv" | sort -t',' -k1,1 -u >> "$AUDIT_DIR/analysis_dataset_gcs_audit.csv"
DEDUP_COUNT=$(tail -n +2 "$AUDIT_DIR/analysis_dataset_gcs_audit.csv" | wc -l)
echo "[audit] Deduplicated rows: $DEDUP_COUNT"

# ============================================================
echo "[audit] === Step 5: R analysis + graphics ==="
# ============================================================
cat > /tmp/audit_analysis.R << 'REOF'
suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(scales)
})

args <- commandArgs(trailingOnly = TRUE)
input_csv <- args[1]
output_dir <- args[2]

dt <- fread(input_csv, showProgress = FALSE)
cat(sprintf("[R] Loaded %d rows, %d columns\n", nrow(dt), ncol(dt)))

fig_dir <- file.path(output_dir, "figures")
tbl_dir <- file.path(output_dir, "tables")
dir.create(fig_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(tbl_dir, showWarnings = FALSE, recursive = TRUE)

# ---- Scenario labels ----
dt[, scenario_label := paste0(
  ifelse(product_type == "dry", "Dry", "Refrig"), " / ",
  ifelse(origin_network == "dry_factory_set", "Centralized", "Regionalized"), " / ",
  toupper(powertrain)
)]

# ---- Table 1: Full scenario summary ----
summary_stats <- dt[, .(
  n_runs = .N,
  n_unique_pairs = uniqueN(pair_id),
  mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 4),
  sd_co2_per_1000kcal = round(sd(co2_per_1000kcal, na.rm = TRUE), 4),
  p05_co2 = round(quantile(co2_per_1000kcal, 0.05, na.rm = TRUE), 4),
  p25_co2 = round(quantile(co2_per_1000kcal, 0.25, na.rm = TRUE), 4),
  p50_co2 = round(quantile(co2_per_1000kcal, 0.50, na.rm = TRUE), 4),
  p75_co2 = round(quantile(co2_per_1000kcal, 0.75, na.rm = TRUE), 4),
  p95_co2 = round(quantile(co2_per_1000kcal, 0.95, na.rm = TRUE), 4),
  mean_distance_miles = round(mean(distance_miles, na.rm = TRUE), 1),
  mean_trip_h = round(mean(trip_duration_total_h, na.rm = TRUE), 2),
  mean_charge_stops = round(mean(charge_stops, na.rm = TRUE), 2),
  mean_refuel_stops = round(mean(refuel_stops, na.rm = TRUE), 2),
  mean_co2_kg = round(mean(co2_kg_total, na.rm = TRUE), 2),
  mean_kcal_delivered = round(mean(kcal_delivered, na.rm = TRUE), 0)
), by = .(powertrain, product_type, origin_network)]
fwrite(summary_stats, file.path(tbl_dir, "scenario_summary_stats.csv"))
cat("[R] Wrote scenario_summary_stats.csv\n")

# ---- Table 2: Powertrain-level ----
pt_summary <- dt[, .(
  n_runs = .N,
  mean_co2 = round(mean(co2_per_1000kcal, na.rm = TRUE), 4),
  sd_co2 = round(sd(co2_per_1000kcal, na.rm = TRUE), 4),
  p05 = round(quantile(co2_per_1000kcal, 0.05, na.rm = TRUE), 4),
  p25 = round(quantile(co2_per_1000kcal, 0.25, na.rm = TRUE), 4),
  p50 = round(quantile(co2_per_1000kcal, 0.50, na.rm = TRUE), 4),
  p75 = round(quantile(co2_per_1000kcal, 0.75, na.rm = TRUE), 4),
  p95 = round(quantile(co2_per_1000kcal, 0.95, na.rm = TRUE), 4)
), by = .(powertrain)]
fwrite(pt_summary, file.path(tbl_dir, "powertrain_summary.csv"))

# ---- Table 3: Completeness ----
completeness <- dt[, .(
  n_runs = .N,
  n_ok = sum(status == "OK", na.rm = TRUE),
  pct_ok = round(100 * sum(status == "OK", na.rm = TRUE) / .N, 2),
  n_na_co2 = sum(is.na(co2_per_1000kcal)),
  n_na_distance = sum(is.na(distance_miles))
), by = .(powertrain, product_type, origin_network)]
fwrite(completeness, file.path(tbl_dir, "completeness_audit.csv"))

# ---- Table 4: Source inventory ----
src_inv <- dt[, .(n = .N), by = .(powertrain, product_type, origin_network)]
fwrite(src_inv, file.path(tbl_dir, "source_inventory.csv"))

# ============================================================
# FIGURES
# ============================================================

theme_audit <- theme_minimal(base_size = 12) + theme(
  plot.title = element_text(face = "bold", size = 14),
  axis.text.x = element_text(angle = 45, hjust = 1)
)

# Fig A: CO2/1000kcal boxplot by scenario
p1 <- ggplot(dt, aes(x = scenario_label, y = co2_per_1000kcal, fill = powertrain)) +
  geom_boxplot(outlier.size = 0.3, outlier.alpha = 0.2) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  labs(title = "CO2 per 1000 kcal by Scenario (GCS Audit)",
       x = NULL, y = "kg CO2 / 1000 kcal") +
  theme_audit
ggsave(file.path(fig_dir, "fig_a_co2_by_scenario_boxplot.png"), p1, width = 12, height = 7, dpi = 150)
cat("[R] Wrote fig_a_co2_by_scenario_boxplot.png\n")

# Fig B: CO2 density overlay diesel vs BEV
p2 <- ggplot(dt, aes(x = co2_per_1000kcal, fill = powertrain)) +
  geom_density(alpha = 0.5) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  facet_wrap(~product_type, scales = "free_y") +
  labs(title = "Emissions Density: Diesel vs BEV",
       x = "kg CO2 / 1000 kcal", y = "Density") +
  theme_audit
ggsave(file.path(fig_dir, "fig_b_co2_density.png"), p2, width = 10, height = 5, dpi = 150)
cat("[R] Wrote fig_b_co2_density.png\n")

# Fig C: CDF
p3 <- ggplot(dt, aes(x = co2_per_1000kcal, color = scenario_label)) +
  stat_ecdf(linewidth = 0.7) +
  labs(title = "Empirical CDF: CO2 per 1000 kcal",
       x = "kg CO2 / 1000 kcal", y = "Cumulative Probability",
       color = "Scenario") +
  theme_audit + theme(legend.position = "right", legend.text = element_text(size = 8))
ggsave(file.path(fig_dir, "fig_c_cdf_emissions.png"), p3, width = 12, height = 7, dpi = 150)
cat("[R] Wrote fig_c_cdf_emissions.png\n")

# Fig D: Emission decomposition (propulsion vs TRU)
decomp <- dt[, .(
  propulsion = mean(co2_kg_propulsion, na.rm = TRUE),
  tru = mean(co2_kg_tru, na.rm = TRUE)
), by = .(scenario_label, powertrain)]
decomp_long <- melt(decomp, id.vars = c("scenario_label", "powertrain"),
                    variable.name = "component", value.name = "co2_kg")
p4 <- ggplot(decomp_long, aes(x = scenario_label, y = co2_kg, fill = component)) +
  geom_col(position = "stack") +
  scale_fill_manual(values = c(propulsion = "steelblue", tru = "coral"),
                    labels = c("Propulsion", "Refrigeration (TRU)")) +
  labs(title = "Emission Decomposition: Propulsion vs TRU",
       x = NULL, y = "Mean CO2 (kg)", fill = "Component") +
  theme_audit
ggsave(file.path(fig_dir, "fig_d_emission_decomposition.png"), p4, width = 12, height = 7, dpi = 150)
cat("[R] Wrote fig_d_emission_decomposition.png\n")

# Fig E: Trip duration boxplot
p5 <- ggplot(dt, aes(x = scenario_label, y = trip_duration_total_h, fill = powertrain)) +
  geom_boxplot(outlier.size = 0.3, outlier.alpha = 0.2) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  labs(title = "Trip Duration by Scenario",
       x = NULL, y = "Total Trip Duration (hours)") +
  theme_audit
ggsave(file.path(fig_dir, "fig_e_trip_duration.png"), p5, width = 12, height = 7, dpi = 150)
cat("[R] Wrote fig_e_trip_duration.png\n")

# Fig F: BEV charge stops distribution
bev_dt <- dt[powertrain == "bev"]
p6 <- ggplot(bev_dt, aes(x = factor(charge_stops))) +
  geom_bar(fill = "steelblue") +
  facet_wrap(~product_type) +
  labs(title = "BEV Charging Stop Distribution",
       x = "Number of Charge Stops", y = "Count") +
  theme_audit
ggsave(file.path(fig_dir, "fig_f_charge_stops.png"), p6, width = 10, height = 5, dpi = 150)
cat("[R] Wrote fig_f_charge_stops.png\n")

# Fig G: CO2 vs distance scatter
set.seed(42)
sample_dt <- dt[sample(.N, min(.N, 10000))]
p7 <- ggplot(sample_dt, aes(x = distance_miles, y = co2_kg_total, color = powertrain)) +
  geom_point(alpha = 0.3, size = 0.8) +
  scale_color_manual(values = c(bev = "steelblue", diesel = "coral")) +
  labs(title = "CO2 vs Distance (10k sample)",
       x = "Distance (miles)", y = "CO2 Total (kg)") +
  theme_audit
ggsave(file.path(fig_dir, "fig_g_co2_vs_distance.png"), p7, width = 10, height = 6, dpi = 150)
cat("[R] Wrote fig_g_co2_vs_distance.png\n")

# Fig H: Electrification benefit (delta histogram)
if (nrow(dt[powertrain == "diesel"]) > 0 && nrow(dt[powertrain == "bev"]) > 0) {
  diesel_med <- dt[powertrain == "diesel", .(diesel_co2 = median(co2_per_1000kcal, na.rm = TRUE)),
                   by = .(product_type, origin_network)]
  bev_med <- dt[powertrain == "bev", .(bev_co2 = median(co2_per_1000kcal, na.rm = TRUE)),
                by = .(product_type, origin_network)]
  delta <- merge(diesel_med, bev_med, by = c("product_type", "origin_network"))
  delta[, pct_reduction := round(100 * (diesel_co2 - bev_co2) / diesel_co2, 1)]
  delta[, label := paste0(
    ifelse(product_type == "dry", "Dry", "Refrig"), " / ",
    ifelse(origin_network == "dry_factory_set", "Centralized", "Regionalized")
  )]
  fwrite(delta, file.path(tbl_dir, "electrification_delta.csv"))

  p8 <- ggplot(delta, aes(x = label, y = pct_reduction)) +
    geom_col(fill = "steelblue") +
    geom_text(aes(label = paste0(pct_reduction, "%")), vjust = -0.5) +
    labs(title = "Electrification Benefit: % CO2 Reduction (median)",
         x = NULL, y = "% CO2 Reduction vs Diesel") +
    theme_audit
  ggsave(file.path(fig_dir, "fig_h_electrification_benefit.png"), p8, width = 8, height = 6, dpi = 150)
  cat("[R] Wrote fig_h_electrification_benefit.png\n")
}

cat(sprintf("\n[R] AUDIT COMPLETE: %d unique runs, %d scenarios\n",
            nrow(dt), uniqueN(dt$scenario_label)))
REOF

Rscript /tmp/audit_analysis.R "$AUDIT_DIR/analysis_dataset_gcs_audit.csv" "$AUDIT_DIR"

# ============================================================
echo "[audit] === Step 6: Metadata ==="
# ============================================================
cat > "$AUDIT_DIR/audit_metadata.txt" << EOF
GCS Full Audit Report
=====================
Date:              $(date -u +%Y-%m-%dT%H:%M:%SZ)
Host:              $(hostname)
Tarballs:          $TARBALL_COUNT
Raw rows:          $RAW_COUNT
Deduplicated rows: $DEDUP_COUNT
Sources:           ${GCS_RERUNS}, ${GCS_LOCAL}

Powertrain breakdown:
$(tail -n +2 "$AUDIT_DIR/analysis_dataset_gcs_audit.csv" | cut -d',' -f5 | sort | uniq -c | sort -rn)

Product type breakdown:
$(tail -n +2 "$AUDIT_DIR/analysis_dataset_gcs_audit.csv" | cut -d',' -f19 | sort | uniq -c | sort -rn)

Origin network breakdown:
$(tail -n +2 "$AUDIT_DIR/analysis_dataset_gcs_audit.csv" | cut -d',' -f20 | sort | uniq -c | sort -rn)
EOF

# ============================================================
echo "[audit] === Step 7: Package and upload ==="
# ============================================================
cd /tmp
tar czf audit_bundle_2026-03-17.tar.gz -C "$AUDIT_DIR" .
gsutil cp /tmp/audit_bundle_2026-03-17.tar.gz "$GCS_OUTPUT/audit_bundle_2026-03-17.tar.gz"

# Also upload the raw deduped dataset
gzip -c "$AUDIT_DIR/analysis_dataset_gcs_audit.csv" > /tmp/analysis_dataset_gcs_audit.csv.gz
gsutil cp /tmp/analysis_dataset_gcs_audit.csv.gz "$GCS_OUTPUT/analysis_dataset_gcs_audit.csv.gz"

echo "[audit] Uploaded to $GCS_OUTPUT/"
echo "[audit] === ALL DONE ==="
