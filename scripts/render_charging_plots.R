#!/usr/bin/env Rscript
# scripts/render_charging_plots.R
#
# Generate standard diagnostic plots for stochastic charger availability.
#
# Reads:  <run_dir>/charging_events.csv
#         <run_dir>/charging_qa_summary.csv  (optional, for aggregated plots)
# Writes: <run_dir>/graphs/
#           wait_time_distribution.png
#           trip_duration_increase.png
#           reefer_runtime_increase.png
#           emissions_by_congestion.png
#           sensitivity_tornado.png          (if multiple scenario_id groups exist)
#
# Follows the repository plotting pattern (optparse, data.table, base R PNG at 1400x900/150dpi).
# Skips existing PNGs unless --force is set (idempotent).
#
# Usage:
#   Rscript scripts/render_charging_plots.R --run_dir runs/<run_id>
#   Rscript scripts/render_charging_plots.R --run_dir runs/<run_id> --force true
#   make render-charging-plots CHARGER_RUN_DIR=runs/<run_id>

suppressPackageStartupMessages(library(optparse))
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table is required")

# Thread safety (match repo pattern)
Sys.setenv(
  OMP_NUM_THREADS = Sys.getenv("OMP_NUM_THREADS", unset = "1"),
  OPENBLAS_NUM_THREADS = Sys.getenv("OPENBLAS_NUM_THREADS", unset = "1"),
  MKL_NUM_THREADS = Sys.getenv("MKL_NUM_THREADS", unset = "1")
)

if (file.exists("R/log_helpers.R")) source("R/log_helpers.R")

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--run_dir"), type = "character",
              help = "Run directory containing charging_events.csv"),
  make_option(c("--outdir"), type = "character", default = "",
              help = "Output directory for PNGs (default: <run_dir>/graphs)"),
  make_option(c("--force"), type = "character", default = "false",
              help = "Overwrite existing PNGs: true | false (default: false)")
)))

if (is.null(opt$run_dir)) stop("--run_dir is required")
run_dir  <- normalizePath(opt$run_dir, mustWork = FALSE)
`%||%`   <- function(x, y) if (is.null(x) || (length(x) == 1 && is.na(x))) y else x
out_dir  <- if (nzchar(opt$outdir %||% "")) opt$outdir else file.path(run_dir, "graphs")
force    <- tolower(trimws(opt$force)) %in% c("true", "1", "yes")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (exists("configure_log")) configure_log(tag = "render_charging_plots")
if (exists("log_event"))     log_event("INFO", "start", sprintf("render_charging_plots: run_dir=%s outdir=%s", run_dir, out_dir))

events_f  <- file.path(run_dir, "charging_events.csv")
summary_f <- file.path(run_dir, "charging_qa_summary.csv")

if (!file.exists(events_f)) {
  msg <- sprintf("charging_events.csv not found in %s — nothing to plot", run_dir)
  if (exists("log_event")) log_event("WARN", "load", msg) else message("WARN: ", msg)
  quit(status = 0)
}

ev  <- data.table::fread(events_f, na.strings = c("", "NA"))
qa  <- if (file.exists(summary_f)) data.table::fread(summary_f, na.strings = c("", "NA")) else NULL

for (col in c("wait_time_minutes", "charge_duration_minutes",
              "reefer_runtime_increment_minutes", "hos_delay_minutes")) {
  if (!col %in% names(ev)) ev[, (col) := 0]
  ev[, (col) := suppressWarnings(as.numeric(get(col)))]
}
if (!"charger_state"  %in% names(ev)) ev[, charger_state  := "unknown"]
if (!"scenario_id"    %in% names(ev)) ev[, scenario_id    := NA_character_]
if (!"powertrain"     %in% names(ev)) ev[, powertrain     := NA_character_]

# Helper: open PNG for writing unless it exists and force is FALSE (used internally)
open_plot_png <- function(name, w = 1400, h = 900, res = 150) {
  path <- file.path(out_dir, name)
  if (file.exists(path) && !force) {
    if (exists("log_event")) log_event("INFO", "plot", sprintf("skip (exists): %s", name))
    return(invisible(NULL))
  }
  png(path, width = w, height = h, res = res)
  path
}
# Note: plots below use the inline guard pattern for clarity; open_plot_png is
# available for any additional plots added to this file.

# ---------------------------------------------------------------------------
# 1. Wait-time distribution histogram
# ---------------------------------------------------------------------------
{
  path <- file.path(out_dir, "wait_time_distribution.png")
  if (!file.exists(path) || force) {
    wait_vals <- ev[charger_state == "occupied" & is.finite(wait_time_minutes), wait_time_minutes]
    png(path, width = 1400, height = 900, res = 150)
    par(mar = c(6, 5, 5, 2) + 0.1)
    if (length(wait_vals) > 0) {
      hist(wait_vals, breaks = 30, col = "#d9e8ff", border = "#1f5fbf",
           main = "Charger Wait-Time Distribution (occupied stops)",
           xlab = "Wait time (minutes)", ylab = "Count",
           cex.main = 1.2, cex.lab = 1.0)
      abline(v = mean(wait_vals), col = "#e63946", lwd = 2, lty = 2)
      abline(v = quantile(wait_vals, 0.95), col = "#ff9f1c", lwd = 2, lty = 2)
      legend("topright", c(sprintf("Mean: %.1f min", mean(wait_vals)),
                            sprintf("P95:  %.1f min", quantile(wait_vals, 0.95))),
             col = c("#e63946", "#ff9f1c"), lty = 2, lwd = 2, bty = "n", cex = 0.9)
    } else {
      plot.new(); title(main = "No occupied-charger events recorded")
    }
    dev.off()
    if (exists("log_event")) log_event("INFO", "plot", "wait_time_distribution.png")
  }
}

# ---------------------------------------------------------------------------
# 2. Trip duration increase by charger state (boxplot)
# ---------------------------------------------------------------------------
{
  path <- file.path(out_dir, "trip_duration_increase.png")
  if (!file.exists(path) || force) {
    d <- ev[charger_state %in% c("available", "occupied") & is.finite(wait_time_minutes)]
    png(path, width = 1400, height = 900, res = 150)
    par(mar = c(6, 6, 5, 2) + 0.1)
    if (nrow(d) > 0 && length(unique(d$charger_state)) > 0) {
      boxplot(wait_time_minutes ~ charger_state, data = d,
              col = "#d9e8ff", border = "#1f5fbf", las = 1,
              main = "Charge-Stop Delay by Charger State",
              ylab = "Wait time (minutes)", xlab = "Charger state",
              cex.main = 1.2, cex.lab = 1.0)
      stripchart(wait_time_minutes ~ charger_state, data = d,
                 method = "jitter", pch = 16, cex = 0.5,
                 col = grDevices::adjustcolor("#2F80ED", alpha.f = 0.35),
                 vertical = TRUE, add = TRUE)
    } else {
      plot.new(); title(main = "No charge-stop data available")
    }
    dev.off()
    if (exists("log_event")) log_event("INFO", "plot", "trip_duration_increase.png")
  }
}

# ---------------------------------------------------------------------------
# 3. Reefer runtime increase by congestion scenario
# ---------------------------------------------------------------------------
{
  path <- file.path(out_dir, "reefer_runtime_increase.png")
  if (!file.exists(path) || force) {
    d <- ev[is.finite(reefer_runtime_increment_minutes)]
    group_col <- if ("scenario_id" %in% names(d) && any(!is.na(d$scenario_id))) "scenario_id" else "charger_state"
    png(path, width = 1400, height = 900, res = 150)
    par(mar = c(8, 6, 5, 2) + 0.1)
    if (nrow(d) > 0) {
      boxplot(reefer_runtime_increment_minutes ~ get(group_col), data = d,
              col = "#e8f5e9", border = "#388e3c", las = 2,
              main = "Reefer Runtime Increment by Scenario",
              ylab = "Reefer runtime added (minutes)", xlab = "",
              cex.main = 1.2, cex.lab = 1.0)
      stripchart(reefer_runtime_increment_minutes ~ get(group_col), data = d,
                 method = "jitter", pch = 16, cex = 0.5,
                 col = grDevices::adjustcolor("#43a047", alpha.f = 0.35),
                 vertical = TRUE, add = TRUE)
    } else {
      plot.new(); title(main = "No reefer increment data available")
    }
    dev.off()
    if (exists("log_event")) log_event("INFO", "plot", "reefer_runtime_increase.png")
  }
}

# ---------------------------------------------------------------------------
# 4. HOS delay by scenario (bar chart from QA summary or raw events)
# ---------------------------------------------------------------------------
{
  path <- file.path(out_dir, "emissions_by_congestion.png")
  if (!file.exists(path) || force) {
    d <- ev[is.finite(hos_delay_minutes)]
    group_col <- if ("scenario_id" %in% names(d) && any(!is.na(d$scenario_id))) "scenario_id" else "charger_state"
    png(path, width = 1400, height = 900, res = 150)
    par(mar = c(8, 6, 5, 2) + 0.1)
    if (nrow(d) > 0) {
      means <- tapply(d$hos_delay_minutes, d[[group_col]], mean, na.rm = TRUE)
      means <- sort(means)
      bp <- barplot(means,
                    col = "#fff3e0", border = "#e65100", las = 2,
                    main = "Mean HOS Delay per Stop by Scenario\n(proxy for downstream emission impact)",
                    ylab = "Mean HOS delay (minutes)", xlab = "",
                    cex.main = 1.1, cex.lab = 1.0)
      text(bp, means + max(means) * 0.02,
           labels = sprintf("%.1f", means), cex = 0.8, adj = c(0.5, 0))
    } else {
      plot.new(); title(main = "No HOS delay data available")
    }
    dev.off()
    if (exists("log_event")) log_event("INFO", "plot", "emissions_by_congestion.png")
  }
}

# ---------------------------------------------------------------------------
# 5. Tornado sensitivity summary (only when multiple scenario groups exist)
# ---------------------------------------------------------------------------
{
  path <- file.path(out_dir, "sensitivity_tornado.png")
  scenarios <- unique(na.omit(ev$scenario_id))
  if ((length(scenarios) >= 2) && (!file.exists(path) || force)) {
    # Compute per-scenario mean of key metrics
    metrics <- c("wait_time_minutes", "reefer_runtime_increment_minutes", "hos_delay_minutes")
    avail_metrics <- intersect(metrics, names(ev))
    if (length(avail_metrics) > 0) {
      means_list <- lapply(avail_metrics, function(m) {
        tapply(ev[[m]], ev$scenario_id, mean, na.rm = TRUE)
      })
      names(means_list) <- avail_metrics

      # Normalise relative to first scenario (baseline)
      baseline_id <- scenarios[1]
      rel <- sapply(avail_metrics, function(m) {
        v <- means_list[[m]]
        base <- v[baseline_id]
        if (!is.finite(base) || base == 0) return(rep(NA_real_, length(v)))
        (v - base) / abs(base) * 100
      })
      rel <- as.matrix(rel)
      rownames(rel) <- names(means_list[[1]])

      if (any(is.finite(rel))) {
        png(path, width = 1400, height = 900, res = 150)
        par(mar = c(6, 12, 5, 4) + 0.1)
        cols_bar <- ifelse(rel[, 1] >= 0, "#ef5350", "#42a5f5")
        if (ncol(rel) == 1) {
          vals <- rel[, 1]
          vals[!is.finite(vals)] <- 0
          barplot(vals,
                  horiz = TRUE, col = cols_bar, border = NA, las = 1,
                  main = sprintf("Sensitivity vs Baseline (%s)\n(%%  change in mean metric)", baseline_id),
                  xlab = "% change from baseline", cex.lab = 1.0, cex.main = 1.1)
          abline(v = 0, lwd = 2, col = "#333")
        }
        dev.off()
        if (exists("log_event")) log_event("INFO", "plot", "sensitivity_tornado.png")
      }
    }
  }
}

n_plots <- length(list.files(out_dir, pattern = "[.]png$"))
if (exists("log_event")) log_event("INFO", "complete",
  sprintf("render_charging_plots done: %d PNGs in %s", n_plots, out_dir))
message("Charging plots written to: ", out_dir)
