#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")
Sys.setenv(
  OMP_NUM_THREADS = Sys.getenv("OMP_NUM_THREADS", unset = "1"),
  OPENBLAS_NUM_THREADS = Sys.getenv("OPENBLAS_NUM_THREADS", unset = "1"),
  MKL_NUM_THREADS = Sys.getenv("MKL_NUM_THREADS", unset = "1")
)

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--runs_csv"), type = "character", default = "outputs/summaries/full_n20_runs_merged.csv"),
  make_option(c("--lci_stage_csv"), type = "character", default = ""),
  make_option(c("--outdir"), type = "character", default = "docs/assets/transport/scientific/full_n20_fix")
)))

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)
if (!file.exists(opt$runs_csv)) stop("runs_csv not found: ", opt$runs_csv)

runs <- data.table::fread(opt$runs_csv)
for (cn in c("co2_per_1000kcal", "co2_kg_total", "delivery_time_min", "trucker_hours_per_1000kcal", "transport_cost_per_1000kcal",
             "traffic_multiplier", "payload_max_lb_draw", "ambient_f", "queue_delay_minutes", "mpg", "grid_kg_per_kwh",
             "connector_overhead_min", "refuel_stop_min", "origin_network", "product_type", "powertrain", "traffic_mode", "scenario", "pair_id", "run_id", "status",
             "units_per_case_draw", "units_per_truck", "cube_utilization_pct", "truckloads_per_1e6_kcal")) {
  if (!cn %in% names(runs)) runs[, (cn) := NA]
}
num_cols <- c("co2_per_1000kcal", "co2_kg_total", "delivery_time_min", "trucker_hours_per_1000kcal", "transport_cost_per_1000kcal",
              "traffic_multiplier", "payload_max_lb_draw", "ambient_f", "queue_delay_minutes", "mpg", "grid_kg_per_kwh",
              "connector_overhead_min", "refuel_stop_min", "units_per_case_draw", "units_per_truck", "cube_utilization_pct", "truckloads_per_1e6_kcal")
for (cn in num_cols) runs[, (cn) := suppressWarnings(as.numeric(get(cn)))]
for (cn in c("origin_network", "product_type", "powertrain", "traffic_mode", "scenario", "pair_id", "run_id", "status")) {
  runs[, (cn) := as.character(get(cn))]
}

y_label <- "kg CO2 / 1000 kcal"
if (!any(is.finite(runs$co2_per_1000kcal)) && any(is.finite(runs$co2_kg_total))) {
  runs[, co2_per_1000kcal := as.numeric(co2_kg_total)]
  y_label <- "kg CO2 per run (FU proxy fallback)"
}

ok <- runs[is.na(status) | tolower(trimws(status)) %in% c("", "ok", "na", "nan")]
ok <- ok[is.finite(co2_per_1000kcal)]
if (nrow(ok) == 0) stop("No valid rows after filtering (checked co2_per_1000kcal and fallback co2_kg_total)")

plot_box <- function(group_col, file_name, title) {
  d <- ok[!is.na(get(group_col)) & nzchar(get(group_col)), .(g = get(group_col), y = co2_per_1000kcal)]
  if (nrow(d) == 0) return(invisible(NULL))
  png(file.path(opt$outdir, file_name), width = 1400, height = 900, res = 150)
  par(mar = c(8, 6, 5, 2) + 0.1)
  boxplot(y ~ g, data = d, las = 2, col = "#d9e8ff", border = "#1f5fbf",
          ylab = y_label, xlab = "", main = title)
  stripchart(y ~ g, data = d, method = "jitter", pch = 16, cex = 0.6,
             col = grDevices::adjustcolor("#2F80ED", alpha.f = 0.4), vertical = TRUE, add = TRUE)
  dev.off()
}

plot_box("powertrain", "dist_powertrain.png", "Distribution: Diesel vs BEV")
plot_box("product_type", "dist_product_type.png", "Distribution: Dry vs Refrigerated Product")
plot_box("traffic_mode", "dist_traffic_mode.png", "Distribution: Stochastic vs Freeflow")
plot_box("origin_network", "dist_origin_network.png", "Distribution: Dry vs Refrigerated Factory Set")

# Convergence charts (global cumulative mean by run order).
conv_metrics <- c("co2_per_1000kcal", "delivery_time_min", "trucker_hours_per_1000kcal", "transport_cost_per_1000kcal")
ord <- ok[order(run_id)]
ord[, idx := .I]
for (m in conv_metrics) {
  y <- suppressWarnings(as.numeric(ord[[m]]))
  keep <- is.finite(y)
  if (sum(keep) < 5) next
  yy <- y[keep]
  xx <- seq_along(yy)
  cmean <- cumsum(yy) / xx
  png(file.path(opt$outdir, paste0("convergence_", m, ".png")), width = 1400, height = 900, res = 150)
  par(mar = c(5, 6, 5, 2) + 0.1)
  plot(xx, cmean, type = "l", lwd = 2, col = "#2F80ED",
       xlab = "Monte Carlo samples", ylab = m,
       main = paste("Convergence:", m))
  abline(h = mean(yy, na.rm = TRUE), lty = 2, col = "#EB5757", lwd = 2)
  legend("topright", bty = "n", lty = c(1, 2), lwd = 2,
         col = c("#2F80ED", "#EB5757"), legend = c("Cumulative mean", "Final mean"))
  dev.off()
}

# Sensitivity: rank absolute correlation to co2_per_1000kcal
preds <- c("traffic_multiplier", "payload_max_lb_draw", "ambient_f", "queue_delay_minutes", "mpg", "grid_kg_per_kwh", "connector_overhead_min", "refuel_stop_min")
sens <- data.table::data.table(variable = preds, corr = NA_real_)
for (i in seq_len(nrow(sens))) {
  v <- sens$variable[[i]]
  x <- suppressWarnings(as.numeric(ok[[v]]))
  y <- suppressWarnings(as.numeric(ok$co2_per_1000kcal))
  keep <- is.finite(x) & is.finite(y)
  sens$corr[[i]] <- if (sum(keep) >= 10) stats::cor(x[keep], y[keep]) else NA_real_
}
sens <- sens[is.finite(corr)]
if (nrow(sens) > 0) {
  sens[, abs_corr := abs(corr)]
  data.table::setorder(sens, -abs_corr)
  data.table::fwrite(sens, file.path(opt$outdir, "sensitivity_ranked.csv"))
  png(file.path(opt$outdir, "sensitivity_ranked.png"), width = 1400, height = 900, res = 150)
  par(mar = c(8, 6, 5, 2) + 0.1)
  barplot(sens$abs_corr, names.arg = sens$variable, las = 2, col = "#F2994A",
          main = "Sensitivity Diagnostic (|corr| with transport emissions metric)", ylab = "Absolute correlation")
  mtext("Diagnostic ranking only; not causal inference", side = 1, line = 6, cex = 0.9)
  dev.off()
}

# Geography comparison (paired GSI with p05/p50/p95)
if (all(c("pair_id", "origin_network", "scenario", "powertrain", "product_type", "co2_per_1000kcal") %in% names(ok))) {
  g <- ok[origin_network %in% c("dry_factory_set", "refrigerated_factory_set")]
  agg <- g[, .(co2 = mean(co2_per_1000kcal, na.rm = TRUE)), by = .(pair_id, scenario, powertrain, product_type, origin_network)]
  wide <- data.table::dcast(agg, pair_id + scenario + powertrain + product_type ~ origin_network, value.var = "co2")
  if (all(c("dry_factory_set", "refrigerated_factory_set") %in% names(wide))) {
    wide[, gsi_delta := refrigerated_factory_set - dry_factory_set]
    wide <- wide[is.finite(gsi_delta)]
    if (nrow(wide) > 0) {
    summ <- wide[, .(
      p05 = as.numeric(stats::quantile(gsi_delta, 0.05, na.rm = TRUE, names = FALSE)),
      p50 = as.numeric(stats::quantile(gsi_delta, 0.50, na.rm = TRUE, names = FALSE)),
      p95 = as.numeric(stats::quantile(gsi_delta, 0.95, na.rm = TRUE, names = FALSE))
    ), by = .(scenario, powertrain, product_type)]
    summ <- summ[is.finite(p05) | is.finite(p50) | is.finite(p95)]
    data.table::fwrite(summ, file.path(opt$outdir, "geography_gsi_summary.csv"))
    if (nrow(summ) > 0) {
      lbl <- paste(summ$scenario, summ$powertrain, summ$product_type, sep = " | ")
      png(file.path(opt$outdir, "geography_gsi_p05_p50_p95.png"), width = 1400, height = 900, res = 150)
      par(mar = c(8, 6, 5, 2) + 0.1)
      plot(seq_len(nrow(summ)), summ$p50, pch = 16, ylim = range(c(summ$p05, summ$p95), na.rm = TRUE),
           xaxt = "n", xlab = "", ylab = "Refrigerated - Dry (kg CO2 / 1000 kcal)",
           main = "Geography Sensitivity Index (paired-origin)")
      axis(1, at = seq_len(nrow(summ)), labels = lbl, las = 2)
      segments(seq_len(nrow(summ)), summ$p05, seq_len(nrow(summ)), summ$p95, lwd = 3, col = "#2F80ED")
      abline(h = 0, lty = 2, col = "#666666")
      dev.off()
    }
    }
  }
}

# Stage contribution chart from LCI summary-by-stage.
if (nzchar(opt$lci_stage_csv) && file.exists(opt$lci_stage_csv)) {
  st <- data.table::fread(opt$lci_stage_csv)
  if (all(c("stage", "co2e_kg_per_1000kcal") %in% names(st))) {
    st <- st[is.finite(as.numeric(co2e_kg_per_1000kcal))]
    st[, co2e_kg_per_1000kcal := as.numeric(co2e_kg_per_1000kcal)]
    if (nrow(st) > 0) {
      png(file.path(opt$outdir, "lci_stage_contribution.png"), width = 1400, height = 900, res = 150)
      par(mar = c(8, 6, 5, 2) + 0.1)
      barplot(st$co2e_kg_per_1000kcal, names.arg = st$stage, las = 2, col = "#56CCF2",
              ylab = "kg CO2e / 1000 kcal", main = "Stage Contribution (LCI + Distribution)")
      dev.off()
    }
  }
}

# Packaging uncertainty sensitivity diagnostics.
pkg <- ok[tolower(product_type) == "refrigerated" & is.finite(units_per_case_draw)]
if (nrow(pkg) > 0) {
  pkg[, units_per_case_draw := as.integer(round(units_per_case_draw))]
  pkg <- pkg[units_per_case_draw %in% c(4L, 5L, 6L)]
  mcols <- c("units_per_truck", "cube_utilization_pct", "truckloads_per_1e6_kcal", "co2_per_1000kcal", "trucker_hours_per_1000kcal")
  long <- data.table::rbindlist(lapply(mcols, function(m) {
    if (!m %in% names(pkg)) return(NULL)
    data.table::data.table(units_per_case_draw = pkg$units_per_case_draw, metric = m, value = suppressWarnings(as.numeric(pkg[[m]])))
  }), fill = TRUE, use.names = TRUE)
  long <- long[is.finite(value)]
  if (nrow(long) > 0) {
    summ <- long[, .(
      n = .N,
      mean = as.numeric(mean(value, na.rm = TRUE)),
      p05 = as.numeric(stats::quantile(value, 0.05, na.rm = TRUE, names = FALSE)),
      p50 = as.numeric(stats::quantile(value, 0.50, na.rm = TRUE, names = FALSE)),
      p95 = as.numeric(stats::quantile(value, 0.95, na.rm = TRUE, names = FALSE))
    ), by = .(units_per_case_draw, metric)]
    data.table::fwrite(summ, file.path(opt$outdir, "refrigerated_units_per_case_sensitivity_summary.csv"))

    png(file.path(opt$outdir, "refrigerated_units_per_case_sensitivity_boxplots.png"), width = 1800, height = 1100, res = 150)
    par(mfrow = c(2, 3), mar = c(6, 5, 4, 2) + 0.1)
    for (m in mcols) {
      d <- long[metric == m]
      if (nrow(d) == 0) {
        plot.new()
        title(main = paste("No data:", m))
        next
      }
      boxplot(value ~ as.factor(units_per_case_draw), data = d, col = "#d9e8ff", border = "#1f5fbf",
              xlab = "Refrigerated units per case draw", ylab = m, main = paste("Sensitivity:", m))
      stripchart(value ~ as.factor(units_per_case_draw), data = d, method = "jitter", pch = 16, cex = 0.55,
                 col = grDevices::adjustcolor("#2F80ED", alpha.f = 0.35), vertical = TRUE, add = TRUE)
    }
    plot.new()
    mtext("Refrigerated packaging uncertainty: units_per_case in {4,5,6}", side = 3, line = -2, cex = 1.0)
    dev.off()
  }
}

cat("Wrote scientific graphics to", opt$outdir, "\n")
