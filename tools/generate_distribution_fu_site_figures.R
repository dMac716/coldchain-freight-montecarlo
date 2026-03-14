#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript tools/generate_distribution_fu_site_figures.R <rows_csv> <outdir>")
}

rows_csv <- args[[1]]
outdir <- args[[2]]
if (!file.exists(rows_csv)) stop("Missing rows csv: ", rows_csv)
dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

d <- data.table::fread(rows_csv)
d <- d[is.finite(co2_per_1000kcal) & is.finite(trip_duration_hours)]
d[, scenario_name := as.character(scenario_name)]

scenario_levels <- c("dry_diesel", "refrigerated_diesel", "dry_bev", "refrigerated_bev")
d <- d[scenario_name %in% scenario_levels]
d[, scenario_name := factor(scenario_name, levels = scenario_levels)]

cols <- c(
  dry_diesel = "#1f77b4",
  refrigerated_diesel = "#0f3f73",
  dry_bev = "#d4a017",
  refrigerated_bev = "#8f6a00"
)

# 1) Scenario mean with uncertainty bars
s <- d[, .(
  mean = mean(co2_per_1000kcal, na.rm = TRUE),
  p05 = as.numeric(quantile(co2_per_1000kcal, 0.05, na.rm = TRUE)),
  p95 = as.numeric(quantile(co2_per_1000kcal, 0.95, na.rm = TRUE))
), by = scenario_name]
s <- s[order(scenario_name)]

png(file.path(outdir, "co2_per_1000kcal_by_scenario.png"), width = 1500, height = 900, res = 150)
par(mar = c(8, 5, 3, 1))
bp <- barplot(
  s$mean,
  col = cols[as.character(s$scenario_name)],
  border = NA,
  names.arg = gsub("_", "\n", as.character(s$scenario_name)),
  ylab = "kg CO2e / 1000 kcal",
  main = "Transport CO2 Intensity by Scenario (Mean with P05-P95)"
)
arrows(bp, s$p05, bp, s$p95, angle = 90, code = 3, length = 0.06, lwd = 2)
grid(nx = NA, ny = NULL, col = "grey90")
dev.off()

# 2) Paired delta distributions
wide <- dcast(d, replicate_id ~ scenario_name, value.var = "co2_per_1000kcal")
wide[, delta_diesel := refrigerated_diesel - dry_diesel]
wide[, delta_bev := refrigerated_bev - dry_bev]

png(file.path(outdir, "paired_delta_boxplot.png"), width = 1200, height = 900, res = 150)
par(mar = c(5, 6, 3, 1))
boxplot(
  list(
    "Diesel Δ (refrig - dry)" = wide$delta_diesel,
    "BEV Δ (refrig - dry)" = wide$delta_bev
  ),
  col = c("#1f77b4", "#d4a017"),
  border = NA,
  ylab = "Delta kg CO2e / 1000 kcal",
  main = "Within-Powertrain Paired Deltas"
)
abline(h = 0, lty = 2, col = "grey40")
grid(nx = NA, ny = NULL, col = "grey90")
dev.off()

# 3) Trip duration by scenario
png(file.path(outdir, "trip_duration_by_scenario.png"), width = 1500, height = 900, res = 150)
par(mar = c(8, 5, 3, 1))
boxplot(
  trip_duration_hours ~ scenario_name,
  data = d,
  col = cols[scenario_levels],
  border = NA,
  names = gsub("_", "\n", scenario_levels),
  ylab = "Trip duration (hours)",
  main = "Trip Duration Distribution by Scenario"
)
grid(nx = NA, ny = NULL, col = "grey90")
dev.off()

# 4) CO2 vs duration scatter
png(file.path(outdir, "co2_vs_duration_scatter.png"), width = 1500, height = 900, res = 150)
par(mar = c(5, 5, 3, 1))
plot(
  d$trip_duration_hours,
  d$co2_per_1000kcal,
  pch = 16,
  cex = 0.9,
  col = cols[as.character(d$scenario_name)],
  xlab = "Trip duration (hours)",
  ylab = "kg CO2e / 1000 kcal",
  main = "CO2 Intensity vs Trip Duration"
)
grid(nx = NA, ny = NULL, col = "grey90")
legend("topright", legend = scenario_levels, col = cols[scenario_levels], pch = 16, bty = "n")
dev.off()

cat("Wrote figures to ", outdir, "\n", sep = "")
