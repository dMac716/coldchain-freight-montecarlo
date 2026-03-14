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

opts <- list(
  make_option(c("--runs_csv"), type = "character", default = "outputs/summaries/full_n20_runs_merged.csv"),
  make_option(c("--outdir"), type = "character", default = "outputs/analysis/bev_grouping"),
  make_option(c("--status_ok"), type = "character", default = "OK")
)
opt <- parse_args(OptionParser(option_list = opts))

if (!file.exists(opt$runs_csv)) stop("runs_csv not found: ", opt$runs_csv)
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

runs <- data.table::fread(opt$runs_csv)
for (cn in c(
  "run_id","pair_id","traffic_mode","origin_network","route_id","route_plan_id","powertrain","status",
  "charge_stops","time_charging_min","queue_delay_minutes","connector_overhead_min","charging_or_refueling_time_h",
  "energy_kwh_propulsion","energy_kwh_tru","grid_kg_per_kwh","delivery_time_min","co2_per_1000kcal","trip_duration_total_h",
  "transport_cost_per_1000kcal","charger_levels_used","charger_types_used","station_ids_used","soc_min_observed","soc_max_observed",
  "max_charge_rate_kw_min","max_charge_rate_kw_max"
)) {
  if (!cn %in% names(runs)) runs[, (cn) := NA]
}

num_cols <- c("charge_stops","time_charging_min","queue_delay_minutes","connector_overhead_min","charging_or_refueling_time_h",
              "energy_kwh_propulsion","energy_kwh_tru","grid_kg_per_kwh","delivery_time_min","co2_per_1000kcal","trip_duration_total_h",
              "transport_cost_per_1000kcal","soc_min_observed","soc_max_observed","max_charge_rate_kw_min","max_charge_rate_kw_max")
for (cn in num_cols) runs[, (cn) := suppressWarnings(as.numeric(get(cn)))]
for (cn in c("run_id","pair_id","traffic_mode","origin_network","route_id","route_plan_id","powertrain","status",
             "charger_levels_used","charger_types_used","station_ids_used")) runs[, (cn) := as.character(get(cn))]

bev <- runs[tolower(powertrain) == "bev"]
if (nrow(bev) == 0) stop("No BEV rows found in runs_csv")

okvals <- tolower(trimws(as.character(opt$status_ok)))
bev_ok <- bev[is.na(status) | tolower(trimws(status)) %in% c("", okvals)]
if (nrow(bev_ok) == 0) bev_ok <- bev

# Regime diagnostic: kmeans(2) on core outcomes where possible.
core <- bev_ok[, .(co2_per_1000kcal, delivery_time_min, trip_duration_total_h, transport_cost_per_1000kcal)]
keep <- stats::complete.cases(core)
regime <- rep(NA_character_, nrow(bev_ok))
if (sum(keep) >= 10) {
  z <- scale(core[keep, ])
  km <- stats::kmeans(z, centers = 2, nstart = 20)
  lbl <- km$cluster
  mu <- tapply(core$co2_per_1000kcal[keep], lbl, mean, na.rm = TRUE)
  ord <- order(mu)
  lab <- ifelse(lbl == ord[[1]], "low_emission_regime", "high_emission_regime")
  regime[keep] <- lab
}
bev_ok[, bev_regime := regime]

# Build explanatory score by predictor via one-way R^2 against co2_per_1000kcal.
predictors <- c("charger_levels_used", "charger_types_used", "route_plan_id", "traffic_mode", "origin_network", "charge_stops")
score_rows <- list(); si <- 0L
for (p in predictors) {
  x <- bev_ok[[p]]
  y <- bev_ok$co2_per_1000kcal
  keep <- is.finite(y) & !is.na(x) & nzchar(as.character(x))
  if (sum(keep) < 8) next
  d <- data.frame(y = y[keep], x = as.factor(as.character(x[keep])))
  if (length(unique(d$x)) < 2) next
  fit <- stats::lm(y ~ x, data = d)
  r2 <- summary(fit)$r.squared
  si <- si + 1L
  score_rows[[si]] <- data.frame(driver = p, r2 = as.numeric(r2), n = nrow(d), stringsAsFactors = FALSE)
}
score <- if (length(score_rows) > 0) data.table::rbindlist(score_rows, fill = TRUE) else data.table::data.table(driver = character(), r2 = numeric(), n = integer())
if (nrow(score) > 0) data.table::setorder(score, -r2)

# Required explanatory table.
out_tbl <- bev_ok[, .(
  run_id, pair_id, traffic_mode, origin_network, route_id, route_plan_id,
  charge_stops, time_charging_min, queue_delay_minutes, connector_overhead_min,
  charging_or_refueling_time_h, energy_kwh_propulsion, energy_kwh_tru, grid_kg_per_kwh,
  charger_levels_used, charger_types_used, station_ids_used,
  soc_min_observed, soc_max_observed,
  delivery_time_min, co2_per_1000kcal
)]
out_tbl_path <- file.path(opt$outdir, "bev_grouping_explanatory_table.csv")
data.table::fwrite(out_tbl, out_tbl_path)

# One explanatory figure.
fig_png <- file.path(opt$outdir, "bev_grouping_explanatory_figure.png")
fig_svg <- file.path(opt$outdir, "bev_grouping_explanatory_figure.svg")

plot_one <- function(devfun, path) {
  devfun(path, width = 1400, height = 900, res = 150)
  par(mfrow = c(1, 2), mar = c(5, 5, 4, 1) + 0.1)

  # Left: trip-duration vs emissions with regime color.
  x <- bev_ok$trip_duration_total_h
  y <- bev_ok$co2_per_1000kcal
  rg <- bev_ok$bev_regime
  if (all(is.na(rg))) rg <- ifelse(is.finite(bev_ok$charge_stops) & bev_ok$charge_stops >= 2, "higher-stop", "lower-stop")
  cols <- ifelse(rg %in% c("high_emission_regime", "higher-stop"), "#D55E00", "#0072B2")
  plot(x, y, pch = 16, col = grDevices::adjustcolor(cols, alpha.f = 0.65),
       xlab = "Trip duration total (h)", ylab = "CO2 per 1000 kcal",
       main = "BEV clustering vs trip time")
  abline(stats::lm(y ~ x), col = "#444444", lwd = 2)
  legend("topleft", legend = c("lower regime", "higher regime"), pch = 16,
         col = c("#0072B2", "#D55E00"), bty = "n", cex = 0.9)

  # Right: route plan + charge stops signal.
  xp <- bev_ok$charge_stops
  yp <- bev_ok$co2_per_1000kcal
  pp <- as.factor(ifelse(nzchar(bev_ok$route_plan_id), bev_ok$route_plan_id, "NA_plan"))
  pcols <- as.integer(pp)
  plot(xp, yp, pch = 16, col = grDevices::adjustcolor(pcols, alpha.f = 0.7),
       xlab = "Charge stops", ylab = "CO2 per 1000 kcal",
       main = "Regime separation by route plan/charging")
  if (length(levels(pp)) <= 8) {
    legend("topleft", legend = levels(pp), col = seq_along(levels(pp)), pch = 16, bty = "n", cex = 0.75)
  }
}

plot_one(grDevices::png, fig_png)
dev.off()
plot_one(function(path, width, height, res) grDevices::svg(path, width = width / 100, height = height / 100), fig_svg)
dev.off()

if (nrow(score) > 0) {
  data.table::fwrite(score, file.path(opt$outdir, "bev_grouping_driver_scores.csv"))
}

top_driver <- if (nrow(score) > 0) as.character(score$driver[[1]]) else "none"
top_r2 <- if (nrow(score) > 0) as.numeric(score$r2[[1]]) else NA_real_
has_two_regimes <- sum(!is.na(bev_ok$bev_regime)) >= 8

note <- c(
  "# BEV Grouping Diagnostic",
  "",
  paste0("Source runs: `", opt$runs_csv, "`"),
  paste0("Rows analyzed (BEV): ", nrow(bev_ok)),
  paste0("Two-regime signal available: ", if (has_two_regimes) "yes" else "insufficient"),
  paste0("Top explanatory driver by one-way R^2: `", top_driver, "`", if (is.finite(top_r2)) paste0(" (R^2=", sprintf("%.3f", top_r2), ")") else ""),
  "",
  "Interpretation:",
  paste0("- BEV outcome grouping is assessed using co2_per_1000kcal, delivery_time_min, trip_duration_total_h, and transport_cost_per_1000kcal."),
  "- Regime separation is visualized against trip duration and charge-stop/route-plan structure.",
  "- This is a diagnostic attribution, not a causal proof; use with paired-origin and CRN context."
)
writeLines(note, file.path(opt$outdir, "bev_grouping_note.md"))

cat("Wrote", out_tbl_path, "\n")
cat("Wrote", fig_png, "\n")
cat("Wrote", fig_svg, "\n")
cat("Wrote", file.path(opt$outdir, "bev_grouping_note.md"), "\n")
