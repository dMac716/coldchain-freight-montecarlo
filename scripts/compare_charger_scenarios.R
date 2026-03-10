#!/usr/bin/env Rscript
# scripts/compare_charger_scenarios.R
#
# Side-by-side comparison of deterministic (baseline) vs stochastic charger runs.
#
# Reads:  <det_run_dir>/charging_qa_summary.csv   (deterministic / no-congestion baseline)
#         <stoch_run_dir>/charging_qa_summary.csv  (stochastic run)
# Writes: <outdir>/
#           scenario_comparison_table.csv
#           scenario_comparison_table.json
#           scenario_comparison_waittime.png
#           scenario_comparison_delays.png
#
# Usage:
#   Rscript scripts/compare_charger_scenarios.R \
#     --det_run_dir   runs/<baseline_run_id> \
#     --stoch_run_dir runs/<stochastic_run_id> \
#     --outdir        outputs/analysis/charger_comparison
#   make compare-charger-scenarios DET_RUN_DIR=runs/A STOCH_RUN_DIR=runs/B

suppressPackageStartupMessages(library(optparse))
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table is required")
if (!requireNamespace("jsonlite",   quietly = TRUE)) stop("jsonlite is required")

Sys.setenv(
  OMP_NUM_THREADS      = Sys.getenv("OMP_NUM_THREADS",      unset = "1"),
  OPENBLAS_NUM_THREADS = Sys.getenv("OPENBLAS_NUM_THREADS", unset = "1"),
  MKL_NUM_THREADS      = Sys.getenv("MKL_NUM_THREADS",      unset = "1")
)

if (file.exists("R/log_helpers.R")) source("R/log_helpers.R")
if (exists("configure_log")) configure_log(tag = "compare_charger_scenarios")

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--det_run_dir"),   type = "character",
              help = "Run directory for deterministic (no-congestion) baseline"),
  make_option(c("--stoch_run_dir"), type = "character",
              help = "Run directory for stochastic charger run"),
  make_option(c("--outdir"),        type = "character", default = "",
              help = "Output directory (default: outputs/analysis/charger_comparison)"),
  make_option(c("--force"),         type = "character", default = "false",
              help = "Overwrite existing outputs: true | false")
)))

if (is.null(opt$det_run_dir))   stop("--det_run_dir is required")
if (is.null(opt$stoch_run_dir)) stop("--stoch_run_dir is required")

det_dir   <- normalizePath(opt$det_run_dir,   mustWork = FALSE)
stoch_dir <- normalizePath(opt$stoch_run_dir, mustWork = FALSE)
out_dir   <- if (nzchar(opt$outdir)) opt$outdir else "outputs/analysis/charger_comparison"
force     <- tolower(trimws(opt$force)) %in% c("true", "1", "yes")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (exists("log_event")) log_event("INFO", "start", sprintf(
  "compare: det=%s stoch=%s out=%s", det_dir, stoch_dir, out_dir))

# ---------------------------------------------------------------------------
# Load QA summaries
# ---------------------------------------------------------------------------
load_qa <- function(run_dir, label) {
  f <- file.path(run_dir, "charging_qa_summary.csv")
  if (!file.exists(f)) {
    if (exists("log_event")) log_event("WARN", "load", sprintf("%s: charging_qa_summary.csv missing — using zeros", label))
    return(data.table::data.table(
      scenario_id = NA_character_, powertrain = NA_character_,
      mean_wait_minutes = 0, p95_wait_minutes = 0,
      broken_event_count = 0L, occupied_event_count = 0L,
      compatible_charger_count = 0L, failed_charge_count = 0L,
      reefer_delay_total_min = 0, hos_delay_total_min = 0, total_stops = 0L
    ))
  }
  dt <- data.table::fread(f, na.strings = c("", "NA"))
  dt[, run_label := label]
  dt
}

det_qa   <- load_qa(det_dir,   "deterministic")
stoch_qa <- load_qa(stoch_dir, "stochastic")

# ---------------------------------------------------------------------------
# Build comparison table
# ---------------------------------------------------------------------------
metric_cols <- c("mean_wait_minutes", "p95_wait_minutes",
                 "broken_event_count", "occupied_event_count",
                 "failed_charge_count", "reefer_delay_total_min", "hos_delay_total_min")

# Merge on scenario_id + powertrain (if available)
join_cols <- intersect(c("scenario_id", "powertrain"), intersect(names(det_qa), names(stoch_qa)))

build_wide <- function(det, stoch, join_cols, metric_cols) {
  metric_cols <- intersect(metric_cols, intersect(names(det), names(stoch)))
  if (length(join_cols) > 0) {
    merged <- merge(det[, c(join_cols, metric_cols), with = FALSE],
                    stoch[, c(join_cols, metric_cols), with = FALSE],
                    by = join_cols, suffixes = c("_det", "_stoch"), all = TRUE)
  } else {
    merged <- cbind(
      data.table::setnames(det[, metric_cols, with = FALSE],  paste0(metric_cols, "_det")),
      data.table::setnames(stoch[, metric_cols, with = FALSE], paste0(metric_cols, "_stoch"))
    )
  }
  for (m in metric_cols) {
    det_col   <- paste0(m, "_det")
    stoch_col <- paste0(m, "_stoch")
    delta_col <- paste0(m, "_delta")
    if (all(c(det_col, stoch_col) %in% names(merged))) {
      merged[, (delta_col) := get(stoch_col) - get(det_col)]
    }
  }
  merged
}

comparison <- build_wide(det_qa, stoch_qa, join_cols, metric_cols)

# ---------------------------------------------------------------------------
# Write comparison table
# ---------------------------------------------------------------------------
out_csv  <- file.path(out_dir, "scenario_comparison_table.csv")
out_json <- file.path(out_dir, "scenario_comparison_table.json")
data.table::fwrite(comparison, out_csv)
jsonlite::write_json(
  list(det_run_dir = det_dir, stoch_run_dir = stoch_dir,
       comparison = jsonlite::fromJSON(jsonlite::toJSON(comparison, auto_unbox = TRUE))),
  out_json, pretty = TRUE, auto_unbox = TRUE
)
if (exists("log_event")) {
  log_event("INFO", "write", sprintf("comparison table: %s", out_csv))
}

# ---------------------------------------------------------------------------
# Plot 1: Wait-time comparison (grouped barplot)
# ---------------------------------------------------------------------------
{
  path <- file.path(out_dir, "scenario_comparison_waittime.png")
  if (!file.exists(path) || force) {
    det_mean   <- if (nrow(det_qa)   > 0) mean(det_qa$mean_wait_minutes,   na.rm = TRUE) else 0
    stoch_mean <- if (nrow(stoch_qa) > 0) mean(stoch_qa$mean_wait_minutes, na.rm = TRUE) else 0
    det_p95    <- if (nrow(det_qa)   > 0) mean(det_qa$p95_wait_minutes,    na.rm = TRUE) else 0
    stoch_p95  <- if (nrow(stoch_qa) > 0) mean(stoch_qa$p95_wait_minutes,  na.rm = TRUE) else 0

    mat <- matrix(c(det_mean, stoch_mean, det_p95, stoch_p95), nrow = 2,
                  dimnames = list(c("Deterministic", "Stochastic"),
                                  c("Mean wait (min)", "P95 wait (min)")))

    png(path, width = 1400, height = 900, res = 150)
    par(mar = c(6, 6, 5, 2) + 0.1)
    bp <- barplot(t(mat), beside = TRUE,
                  col = c("#d9e8ff", "#fee8d9"), border = c("#1f5fbf", "#e65100"),
                  legend.text = colnames(mat),
                  args.legend = list(bty = "n", cex = 0.85),
                  main = "Wait Time: Deterministic vs Stochastic",
                  ylab = "Minutes", las = 1,
                  cex.main = 1.2, cex.lab = 1.0)
    dev.off()
    if (exists("log_event")) log_event("INFO", "plot", "scenario_comparison_waittime.png")
  }
}

# ---------------------------------------------------------------------------
# Plot 2: Delay metrics comparison
# ---------------------------------------------------------------------------
{
  path <- file.path(out_dir, "scenario_comparison_delays.png")
  if (!file.exists(path) || force) {
    metrics_to_plot <- intersect(
      c("reefer_delay_total_min", "hos_delay_total_min"),
      intersect(names(det_qa), names(stoch_qa))
    )
    if (length(metrics_to_plot) > 0) {
      det_vals   <- sapply(metrics_to_plot, function(m) sum(det_qa[[m]],   na.rm = TRUE))
      stoch_vals <- sapply(metrics_to_plot, function(m) sum(stoch_qa[[m]], na.rm = TRUE))
      mat <- rbind(det_vals, stoch_vals)
      rownames(mat) <- c("Deterministic", "Stochastic")
      colnames(mat) <- c("Reefer delay (min)", "HOS delay (min)")[seq_along(metrics_to_plot)]

      png(path, width = 1400, height = 900, res = 150)
      par(mar = c(6, 7, 5, 2) + 0.1)
      barplot(mat, beside = TRUE,
              col = c("#e8f5e9", "#fce4ec"), border = c("#388e3c", "#c62828"),
              legend.text = rownames(mat),
              args.legend = list(bty = "n", cex = 0.85),
              main = "Total Delay Contribution: Deterministic vs Stochastic",
              ylab = "Total minutes (all stops)", las = 1,
              cex.main = 1.1, cex.lab = 1.0)
      dev.off()
      if (exists("log_event")) log_event("INFO", "plot", "scenario_comparison_delays.png")
    }
  }
}

print(comparison)
if (exists("log_event")) log_event("INFO", "complete",
  sprintf("compare_charger_scenarios done: outputs in %s", out_dir))
message("Comparison outputs written to: ", out_dir)
