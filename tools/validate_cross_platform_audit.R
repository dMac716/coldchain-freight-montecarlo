#!/usr/bin/env Rscript
# validate_cross_platform_audit.R — Compare analysis results across 3 methods
#
# Methods:
#   1. LOCAL:  Locally merged and deduplicated dataset (macOS)
#   2. GCS:   GCP VM audit from GCS tarballs (run on gcp-ta-worker-2)
#   3. AZURE: Azure VM audit (run on coldchain-worker-12)
#
# This script validates that all three methods produce consistent results,
# serving as proof of computational reproducibility.
#
# Usage:
#   Rscript tools/validate_cross_platform_audit.R \
#     --local_csv /path/to/local_deduped.csv \
#     --gcs_csv /path/to/gcs_audit_dataset.csv \
#     --azure_csv /path/to/azure_audit_dataset.csv \
#     --outdir artifacts/validation
#
# Or with tables only (if raw CSVs are too large):
#   Rscript tools/validate_cross_platform_audit.R \
#     --local_stats /path/to/local_stats.csv \
#     --gcs_stats /path/to/gcs_stats.csv \
#     --azure_stats /path/to/azure_stats.csv \
#     --outdir artifacts/validation

suppressPackageStartupMessages({
  library(data.table)
  library(optparse)
})

option_list <- list(
  make_option("--local_csv", type = "character", default = ""),
  make_option("--gcs_csv", type = "character", default = ""),
  make_option("--azure_csv", type = "character", default = ""),
  make_option("--local_stats", type = "character", default = ""),
  make_option("--gcs_stats", type = "character", default = ""),
  make_option("--azure_stats", type = "character", default = ""),
  make_option("--outdir", type = "character", default = "artifacts/validation")
)
opt <- parse_args(OptionParser(option_list = option_list))
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

cat("=== Cross-Platform Audit Validation ===\n\n")

# ---- Helper: compute scenario stats from raw CSV ----
compute_stats <- function(csv_path, label) {
  dt <- fread(csv_path, showProgress = FALSE)
  cat(sprintf("[%s] Loaded %d rows, %d columns\n", label, nrow(dt), ncol(dt)))

  # Derive FU if missing
  if (all(is.na(dt$kcal_delivered)) || sum(!is.na(dt$kcal_delivered)) == 0) {
    dt[, payload_kg := payload_max_lb_draw * load_fraction * 0.453592]
    dt[, kcal_delivered := payload_kg * kcal_per_kg_product]
    dt[, co2_per_1000kcal := co2_kg_total / kcal_delivered * 1000]
  }

  stats <- dt[, .(
    n_runs = .N,
    mean_co2_kg = round(mean(co2_kg_total, na.rm = TRUE), 4),
    sd_co2_kg = round(sd(co2_kg_total, na.rm = TRUE), 4),
    p50_co2_kg = round(median(co2_kg_total, na.rm = TRUE), 4),
    mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 8),
    mean_distance = round(mean(distance_miles, na.rm = TRUE), 4),
    mean_trip_h = round(mean(trip_duration_total_h, na.rm = TRUE), 4),
    mean_charge_stops = round(mean(charge_stops, na.rm = TRUE), 4),
    mean_energy_kwh = round(mean(energy_kwh_total, na.rm = TRUE), 4),
    mean_co2_tru = round(mean(co2_kg_tru, na.rm = TRUE), 4)
  ), by = .(powertrain, product_type, origin_network)]

  stats[, source := label]
  stats
}

# ---- Load or compute stats ----
sources <- list()

if (nzchar(opt$local_csv) && file.exists(opt$local_csv)) {
  sources$local <- compute_stats(opt$local_csv, "LOCAL")
} else if (nzchar(opt$local_stats) && file.exists(opt$local_stats)) {
  sources$local <- fread(opt$local_stats)
  sources$local[, source := "LOCAL"]
}

if (nzchar(opt$gcs_csv) && file.exists(opt$gcs_csv)) {
  sources$gcs <- compute_stats(opt$gcs_csv, "GCS")
} else if (nzchar(opt$gcs_stats) && file.exists(opt$gcs_stats)) {
  sources$gcs <- fread(opt$gcs_stats)
  sources$gcs[, source := "GCS"]
}

if (nzchar(opt$azure_csv) && file.exists(opt$azure_csv)) {
  sources$azure <- compute_stats(opt$azure_csv, "AZURE")
} else if (nzchar(opt$azure_stats) && file.exists(opt$azure_stats)) {
  sources$azure <- fread(opt$azure_stats)
  sources$azure[, source := "AZURE"]
}

n_sources <- length(sources)
cat(sprintf("\nLoaded %d sources: %s\n\n", n_sources, paste(names(sources), collapse = ", ")))

if (n_sources < 2) {
  cat("Need at least 2 sources for comparison. Exiting.\n")
  quit(status = 1)
}

# ---- Intersect by run_id for exact comparison ----
# When sources have different row counts, also compute stats on shared runs only
raw_datasets <- list()
if (nzchar(opt$local_csv) && file.exists(opt$local_csv))
  raw_datasets$local <- fread(opt$local_csv, select = "run_id")
if (nzchar(opt$gcs_csv) && file.exists(opt$gcs_csv))
  raw_datasets$gcs <- fread(opt$gcs_csv, select = "run_id")
if (nzchar(opt$azure_csv) && file.exists(opt$azure_csv))
  raw_datasets$azure <- fread(opt$azure_csv, select = "run_id")

if (length(raw_datasets) >= 2) {
  shared_ids <- Reduce(intersect, lapply(raw_datasets, function(x) x$run_id))
  cat(sprintf("[Intersect] %d shared run_ids across %d sources\n",
              length(shared_ids), length(raw_datasets)))

  # Re-compute stats on shared subset
  shared_sources <- list()
  for (nm in names(raw_datasets)) {
    csv_opt <- paste0(nm, "_csv")
    csv_path <- opt[[csv_opt]]
    if (nzchar(csv_path) && file.exists(csv_path)) {
      dt_full <- fread(csv_path, showProgress = FALSE)
      dt_shared <- dt_full[run_id %in% shared_ids]
      cat(sprintf("[Intersect] %s: %d → %d rows (shared)\n", nm, nrow(dt_full), nrow(dt_shared)))

      if (all(is.na(dt_shared$kcal_delivered)) || sum(!is.na(dt_shared$kcal_delivered)) == 0) {
        dt_shared[, payload_kg := payload_max_lb_draw * load_fraction * 0.453592]
        dt_shared[, kcal_delivered := payload_kg * kcal_per_kg_product]
        dt_shared[, co2_per_1000kcal := co2_kg_total / kcal_delivered * 1000]
      }

      s <- dt_shared[, .(
        n_runs = .N,
        mean_co2_kg = round(mean(co2_kg_total, na.rm = TRUE), 4),
        sd_co2_kg = round(sd(co2_kg_total, na.rm = TRUE), 4),
        p50_co2_kg = round(median(co2_kg_total, na.rm = TRUE), 4),
        mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 8),
        mean_distance = round(mean(distance_miles, na.rm = TRUE), 4),
        mean_trip_h = round(mean(trip_duration_total_h, na.rm = TRUE), 4),
        mean_charge_stops = round(mean(charge_stops, na.rm = TRUE), 4),
        mean_energy_kwh = round(mean(energy_kwh_total, na.rm = TRUE), 4),
        mean_co2_tru = round(mean(co2_kg_tru, na.rm = TRUE), 4)
      ), by = .(powertrain, product_type, origin_network)]
      s[, source := paste0(nm, "_shared")]
      shared_sources[[nm]] <- s
    }
  }

  if (length(shared_sources) >= 2) {
    shared_combined <- rbindlist(shared_sources, fill = TRUE)
    fwrite(shared_combined, file.path(opt$outdir, "cross_platform_shared_stats.csv"))
    cat("[OK] Wrote cross_platform_shared_stats.csv (identical run_id subset)\n\n")
  }
}

# ---- Combine all stats ----
all_stats <- rbindlist(sources, fill = TRUE)
fwrite(all_stats, file.path(opt$outdir, "cross_platform_stats_combined.csv"))
cat("[OK] Wrote cross_platform_stats_combined.csv\n")

# ---- Pairwise comparison ----
merge_keys <- c("powertrain", "product_type", "origin_network")
source_names <- names(sources)
comparisons <- list()

for (i in 1:(n_sources - 1)) {
  for (j in (i + 1):n_sources) {
    s1_name <- source_names[i]
    s2_name <- source_names[j]
    s1 <- sources[[i]]
    s2 <- sources[[j]]

    # Standardize column names for merge
    compare_cols <- intersect(
      setdiff(names(s1), c(merge_keys, "source")),
      setdiff(names(s2), c(merge_keys, "source"))
    )

    m <- merge(s1[, c(merge_keys, compare_cols), with = FALSE],
               s2[, c(merge_keys, compare_cols), with = FALSE],
               by = merge_keys, suffixes = c(paste0(".", s1_name), paste0(".", s2_name)))

    # Compute deltas for numeric columns
    delta_rows <- list()
    for (col in compare_cols) {
      c1 <- paste0(col, ".", s1_name)
      c2 <- paste0(col, ".", s2_name)
      if (c1 %in% names(m) && c2 %in% names(m)) {
        v1 <- as.numeric(m[[c1]])
        v2 <- as.numeric(m[[c2]])
        abs_diff <- abs(v1 - v2)
        pct_diff <- ifelse(v1 != 0, 100 * abs_diff / abs(v1), NA_real_)
        delta_rows[[col]] <- data.table(
          metric = col,
          max_abs_diff = round(max(abs_diff, na.rm = TRUE), 6),
          mean_abs_diff = round(mean(abs_diff, na.rm = TRUE), 6),
          max_pct_diff = round(max(pct_diff, na.rm = TRUE), 4),
          mean_pct_diff = round(mean(pct_diff, na.rm = TRUE), 4)
        )
      }
    }
    delta_dt <- rbindlist(delta_rows)
    delta_dt[, comparison := paste0(s1_name, " vs ", s2_name)]
    comparisons[[paste0(s1_name, "_", s2_name)]] <- delta_dt

    cat(sprintf("\n=== %s vs %s ===\n", toupper(s1_name), toupper(s2_name)))
    print(delta_dt[, .(metric, max_abs_diff, max_pct_diff)])
  }
}

all_comparisons <- rbindlist(comparisons)
fwrite(all_comparisons, file.path(opt$outdir, "cross_platform_deltas.csv"))
cat("\n[OK] Wrote cross_platform_deltas.csv\n")

# ---- Run count comparison ----
run_counts <- all_stats[, .(source, powertrain, product_type, origin_network, n_runs)]
run_wide <- dcast(run_counts, powertrain + product_type + origin_network ~ source,
                  value.var = "n_runs")
fwrite(run_wide, file.path(opt$outdir, "cross_platform_run_counts.csv"))
cat("[OK] Wrote cross_platform_run_counts.csv\n")

# ---- Validation verdict ----
TOLERANCE_PCT <- 1.0  # 1% tolerance for matching
pass <- TRUE
for (comp in comparisons) {
  fails <- comp[max_pct_diff > TOLERANCE_PCT & metric != "n_runs"]
  if (nrow(fails) > 0) {
    cat(sprintf("\n[WARN] %s: %d metrics exceed %.1f%% tolerance:\n",
                comp$comparison[1], nrow(fails), TOLERANCE_PCT))
    print(fails)
    pass <- FALSE
  }
}

if (pass) {
  cat(sprintf("\n[PASS] All metrics match within %.1f%% across %d sources.\n",
              TOLERANCE_PCT, n_sources))
} else {
  cat(sprintf("\n[WARN] Some metrics differ by >%.1f%%. Check run counts — different source data expected.\n",
              TOLERANCE_PCT))
}

# ---- Summary report ----
report <- sprintf("Cross-Platform Audit Validation Report
========================================
Date: %s
Sources: %s
Tolerance: %.1f%%
Verdict: %s

Run count comparison:
%s

Metric deltas:
%s
",
  Sys.time(),
  paste(source_names, collapse = ", "),
  TOLERANCE_PCT,
  if (pass) "PASS" else "WARN — differences found (check run count alignment)",
  paste(capture.output(print(run_wide)), collapse = "\n"),
  paste(capture.output(print(all_comparisons)), collapse = "\n")
)

writeLines(report, file.path(opt$outdir, "cross_platform_validation_report.txt"))
cat("[OK] Wrote cross_platform_validation_report.txt\n")
cat("\nDONE\n")
