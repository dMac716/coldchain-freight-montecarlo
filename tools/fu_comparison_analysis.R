#!/usr/bin/env Rscript
## tools/fu_comparison_analysis.R
## ============================================================================
## Generates figures, tables, and comparison outputs for the audit-uniform
## FU dataset against old_stored, exo_draw, and phase2 methods.
##
## This script is organized in two parts:
##   PART 1 — Audit-uniform standalone figures (tagged fu_method="audit_uniform"):
##     fig_a_co2_by_scenario.png   Boxplot: CO2/1000kcal by scenario
##     fig_b_co2_density.png       Density: diesel vs BEV by product type
##     fig_c_cdf.png               Empirical CDF by scenario
##     fig_e_trip_duration.png     Boxplot: trip duration by scenario
##     fig_f_charge_stops.png     Bar: BEV charging stops per trip
##     fig_h_electrification.png  Bar: % CO2 reduction BEV vs diesel
##     comprehensive_scenario_stats.csv  Full stats by powertrain/product/network
##     bev_charging_detail.csv    BEV charging breakdown by scenario
##     bev_charging_vs_no_charging.csv  With/without charging comparison
##
##   PART 2 — Four-way method comparison outputs:
##     fu_delta_by_scenario.csv    Mean FU differences (C-A, C-B, C-D) and %
##     bev_vs_diesel_ranking.csv   Does BEV beat diesel? Depends on method
##     overlay_dry_density.png     Density overlay: all methods, dry product
##     overlay_refrigerated_density.png  Same for refrigerated
##     overlay_cdf_all.png         CDF overlay: all methods, faceted
##     overlay_boxplot_methods.png Boxplot: FU by method, faceted
##     overlay_payload_density.png Payload distributions by method
##     fu_summary_statistics.csv   Full quantile summary by method/scenario
##
## INPUT DATA SOURCES:
##   A: analysis_postfix_validated.csv.gz — original Dataset B (partial FU)
##   B: fu_recovery_enrichment.csv — exogenous-draw recovered rows
##   C: /tmp/audit_uniform_input.csv — audit-uniform recomputed dataset
##   D: transport_sim_rows.csv — phase2 load-model validated (local drive)
##
## USAGE:
##   Rscript tools/fu_comparison_analysis.R
##   (requires /tmp/audit_uniform_input.csv to exist; see build_audit_uniform_dataset.R)
##
## DEPENDENCIES:
##   data.table, ggplot2, scales
## ============================================================================

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(scales)
})

ARTIFACT_DIR <- "artifacts/analysis_final_2026-03-17"
OUTDIR <- file.path(ARTIFACT_DIR, "audit_uniform_outputs")
tbl_dir <- file.path(OUTDIR, "tables")
fig_dir <- file.path(OUTDIR, "figures")
dir.create(tbl_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(fig_dir, showWarnings = FALSE, recursive = TRUE)

## Shared ggplot theme for all figures in this script
theme_audit <- theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold", size = 14),
        axis.text.x = element_text(angle = 45, hjust = 1))

## ── Load datasets ────────────────────────────────────────────────────────────
cat("Loading datasets...\n")

## A: original with old stored values
orig <- fread(cmd = sprintf("gzcat '%s/analysis_postfix_validated.csv.gz'", ARTIFACT_DIR),
              na.strings = c("", "NA"))
orig[, method := "A_old_stored"]

## B: exogenous-draw enrichment
enrich <- fread(sprintf("%s/fu_recovery_enrichment.csv", ARTIFACT_DIR))

## C: audit-uniform
au <- fread("/tmp/audit_uniform_input.csv")
au[, method := "C_audit_uniform"]

## D: phase2
p2_path <- "/Users/dMac/My Drive (djmacdonald@ucdavis.edu)/UC Davis/Winter 2025/KissockPaper/local_chunked_run_report_bundle/data/transport_sim_rows.csv"
p2 <- if (file.exists(p2_path)) fread(p2_path) else data.table()
if (nrow(p2) > 0) {
  p2[, product_type := ifelse(grepl("dry", scenario_name), "dry", "refrigerated")]
  p2[, powertrain := ifelse(grepl("bev", scenario_name), "bev", "diesel")]
}

cat(sprintf("  Original: %d rows (%d with FU)\n", nrow(orig), sum(!is.na(orig$co2_per_1000kcal))))
cat(sprintf("  Enrichment: %d rows\n", nrow(enrich)))
cat(sprintf("  Audit-uniform: %d rows\n", nrow(au)))
cat(sprintf("  Phase2: %d rows\n", nrow(p2)))

## ── Scenario labels ──────────────────────────────────────────────────────────
au[, scenario_label := paste0(
  ifelse(product_type == "dry", "Dry", "Refrig"), " / ",
  ifelse(origin_network == "dry_factory_set", "Centralized", "Regionalized"), " / ",
  toupper(powertrain)
)]

## ========================================================================
## PART 1: AUDIT-UNIFORM FIGURES (tagged fu_method = "audit_uniform")
## ========================================================================
cat("\n=== Part 1: Audit-Uniform Figures ===\n")

## Fig A: CO2/1000kcal boxplot
p1 <- ggplot(au, aes(x = scenario_label, y = co2_per_1000kcal, fill = powertrain)) +
  geom_boxplot(outlier.size = 0.3, outlier.alpha = 0.2) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  labs(title = sprintf("CO2 per 1000 kcal by Scenario [audit_uniform] (n=%s)", comma(nrow(au))),
       subtitle = "FU: payload_kg = payload_max_lb_draw * load_fraction * 0.453592",
       x = NULL, y = "kg CO2 / 1000 kcal") + theme_audit
ggsave(file.path(fig_dir, "fig_a_co2_by_scenario.png"), p1, width = 12, height = 7, dpi = 150)

## Fig B: CO2 density
p2_fig <- ggplot(au, aes(x = co2_per_1000kcal, fill = powertrain)) +
  geom_density(alpha = 0.5) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  facet_wrap(~product_type, scales = "free") +
  labs(title = "Emissions Density: Diesel vs BEV [audit_uniform]",
       x = "kg CO2 / 1000 kcal") + theme_audit
ggsave(file.path(fig_dir, "fig_b_co2_density.png"), p2_fig, width = 10, height = 5, dpi = 150)

## Fig C: CDF
p3 <- ggplot(au, aes(x = co2_per_1000kcal, color = scenario_label)) +
  stat_ecdf(linewidth = 0.7) +
  labs(title = "Empirical CDF: CO2 per 1000 kcal [audit_uniform]",
       x = "kg CO2 / 1000 kcal", y = "Cumulative Probability",
       color = "Scenario") +
  theme_audit + theme(legend.position = "right", legend.text = element_text(size = 8))
ggsave(file.path(fig_dir, "fig_c_cdf.png"), p3, width = 12, height = 7, dpi = 150)

## Fig E: Trip duration boxplot
p5 <- ggplot(au, aes(x = scenario_label, y = trip_duration_total_h, fill = powertrain)) +
  geom_boxplot(outlier.size = 0.3, outlier.alpha = 0.2) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  labs(title = "Trip Duration by Scenario [audit_uniform]", x = NULL, y = "Hours") + theme_audit
ggsave(file.path(fig_dir, "fig_e_trip_duration.png"), p5, width = 12, height = 7, dpi = 150)

## Fig F: BEV charge stops
bev_au <- au[powertrain == "bev"]
p6 <- ggplot(bev_au, aes(x = factor(charge_stops))) +
  geom_bar(fill = "steelblue") + facet_wrap(~product_type) +
  labs(title = "BEV Charging Stops per Trip [audit_uniform]",
       x = "Charge Stops", y = "Count") + theme_audit
ggsave(file.path(fig_dir, "fig_f_charge_stops.png"), p6, width = 10, height = 5, dpi = 150)

## Fig H: Electrification benefit
std_nets <- c("dry_factory_set", "refrigerated_factory_set")
delta <- merge(
  au[powertrain == "diesel" & origin_network %in% std_nets,
     .(diesel_co2 = median(co2_per_1000kcal, na.rm = TRUE)),
     by = .(product_type, origin_network)],
  au[powertrain == "bev" & origin_network %in% std_nets,
     .(bev_co2 = median(co2_per_1000kcal, na.rm = TRUE)),
     by = .(product_type, origin_network)],
  by = c("product_type", "origin_network"))
delta[, pct_reduction := round(100 * (diesel_co2 - bev_co2) / diesel_co2, 1)]
delta[, label := paste0(ifelse(product_type == "dry", "Dry", "Refrig"), " / ",
                        ifelse(origin_network == "dry_factory_set", "Central", "Regional"))]
p8 <- ggplot(delta, aes(x = label, y = pct_reduction, fill = pct_reduction > 0)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = paste0(pct_reduction, "%"),
                vjust = ifelse(pct_reduction >= 0, -0.5, 1.5)),
            fontface = "bold", size = 4.5) +
  scale_fill_manual(values = c(`TRUE` = "steelblue", `FALSE` = "coral"),
                    labels = c(`TRUE` = "BEV advantage", `FALSE` = "Diesel advantage"),
                    name = NULL) +
  labs(title = "Electrification: % CO2 Reduction vs Diesel [audit_uniform]",
       x = NULL, y = "% Reduction") + theme_audit
ggsave(file.path(fig_dir, "fig_h_electrification.png"), p8, width = 8, height = 6, dpi = 150)
cat("  Figures written.\n")

## ── Comprehensive scenario table ─────────────────────────────────────────────
comprehensive <- au[, .(
  n_runs = .N,
  n_unique_pairs = uniqueN(pair_id),
  mean_co2_kg_total = round(mean(co2_kg_total, na.rm = TRUE), 2),
  sd_co2_kg_total = round(sd(co2_kg_total, na.rm = TRUE), 2),
  p05_co2_kg = round(quantile(co2_kg_total, 0.05, na.rm = TRUE), 2),
  p50_co2_kg = round(quantile(co2_kg_total, 0.50, na.rm = TRUE), 2),
  p95_co2_kg = round(quantile(co2_kg_total, 0.95, na.rm = TRUE), 2),
  mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 6),
  sd_co2_per_1000kcal = round(sd(co2_per_1000kcal, na.rm = TRUE), 6),
  p05_co2_per_1000kcal = round(quantile(co2_per_1000kcal, 0.05, na.rm = TRUE), 6),
  p50_co2_per_1000kcal = round(quantile(co2_per_1000kcal, 0.50, na.rm = TRUE), 6),
  p95_co2_per_1000kcal = round(quantile(co2_per_1000kcal, 0.95, na.rm = TRUE), 6),
  mean_distance_miles = round(mean(distance_miles, na.rm = TRUE), 1),
  mean_trip_h = round(mean(trip_duration_total_h, na.rm = TRUE), 2),
  mean_charge_stops = round(mean(charge_stops, na.rm = TRUE), 2),
  mean_payload_lb = round(mean(payload_max_lb_draw, na.rm = TRUE), 0),
  mean_load_fraction = round(mean(load_fraction, na.rm = TRUE), 3),
  mean_kcal_delivered = round(mean(kcal_delivered, na.rm = TRUE), 0),
  mean_energy_kwh = round(mean(energy_kwh_total, na.rm = TRUE), 1),
  fu_method = "audit_uniform"
), by = .(powertrain, product_type, origin_network)]

fwrite(comprehensive, file.path(tbl_dir, "comprehensive_scenario_stats.csv"))
cat("  comprehensive_scenario_stats.csv written.\n")

## ── BEV charging tables ──────────────────────────────────────────────────────
bev_detail <- bev_au[, .(
  n_runs = .N,
  pct_with_charging = round(100 * sum(charge_stops > 0, na.rm = TRUE) / .N, 1),
  mean_charge_stops = round(mean(charge_stops, na.rm = TRUE), 2),
  median_charge_stops = as.double(median(charge_stops, na.rm = TRUE)),
  mean_co2_kg = round(mean(co2_kg_total, na.rm = TRUE), 2),
  mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 6),
  mean_energy_kwh = round(mean(energy_kwh_total, na.rm = TRUE), 1),
  fu_method = "audit_uniform"
), by = .(product_type, origin_network)]
fwrite(bev_detail, file.path(tbl_dir, "bev_charging_detail.csv"))

bev_au[, has_charging := charge_stops > 0]
bev_compare <- bev_au[, .(
  n = .N,
  mean_co2_kg = round(mean(co2_kg_total, na.rm = TRUE), 2),
  mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 6),
  mean_trip_h = round(mean(trip_duration_total_h, na.rm = TRUE), 2),
  mean_energy_kwh = round(mean(energy_kwh_total, na.rm = TRUE), 1),
  mean_distance = round(mean(distance_miles, na.rm = TRUE), 1),
  fu_method = "audit_uniform"
), by = .(product_type, has_charging)]
fwrite(bev_compare, file.path(tbl_dir, "bev_charging_vs_no_charging.csv"))
cat("  BEV tables written.\n")

## ========================================================================
## PART 2: FOUR-WAY COMPARISON OUTPUTS
## ========================================================================
cat("\n=== Part 2: Four-Way Comparison ===\n")

## Build long-form comparison dataset
## For each row, compute all available FU methods
comp_dt <- au[, .(run_id, seed, powertrain, product_type, origin_network,
                   co2_kg_total, payload_max_lb_draw, load_fraction,
                   kcal_per_kg_product, distance_miles, charge_stops,
                   trip_duration_total_h, energy_kwh_total)]

## C: audit uniform (already computed)
comp_dt[, c_payload_kg := payload_max_lb_draw * load_fraction * 0.453592]
comp_dt[, c_kcal_delivered := c_payload_kg * kcal_per_kg_product]
comp_dt[, c_co2_fu := co2_kg_total / c_kcal_delivered * 1000]

## A: old stored (join from original)
comp_dt <- merge(comp_dt,
  orig[!is.na(co2_per_1000kcal), .(run_id, a_co2_fu = co2_per_1000kcal,
                                     a_kcal_delivered = kcal_delivered, a_payload_kg = payload_kg)],
  by = "run_id", all.x = TRUE, sort = FALSE)

## B: exo draw (join from enrichment)
comp_dt <- merge(comp_dt,
  enrich[, .(run_id,
             b_co2_fu = get("co2_per_1000kcal"),
             b_kcal_delivered = get("kcal_delivered"),
             b_payload_kg = get("payload_kg"))],
  by = "run_id", all.x = TRUE, sort = FALSE)

comp_dt[, scenario := paste0(product_type, "/", powertrain)]

## ── Delta table: mean differences by scenario ────────────────────────────────
## For each scenario, compute absolute and percentage differences between
## method C (audit_uniform) and methods A, B, D. Positive delta_CA means
## the audit method produces a higher FU value than the old stored method.
cat("  Building delta tables...\n")

scenarios <- comp_dt[, unique(scenario)]
delta_rows <- list()

for (sc in scenarios) {
  sub <- comp_dt[scenario == sc]
  n <- nrow(sub)
  c_mean <- mean(sub$c_co2_fu, na.rm = TRUE)
  a_mean <- mean(sub$a_co2_fu, na.rm = TRUE)
  b_mean <- mean(sub$b_co2_fu, na.rm = TRUE)

  # Phase2
  p2_sub <- if (nrow(p2) > 0) {
    p2_pt <- strsplit(sc, "/")[[1]][1]
    p2_pw <- strsplit(sc, "/")[[1]][2]
    p2[product_type == p2_pt & powertrain == p2_pw]
  } else data.table()
  d_mean <- if (nrow(p2_sub) > 0) mean(p2_sub$co2_per_1000kcal) else NA_real_

  delta_rows[[length(delta_rows) + 1]] <- data.table(
    scenario = sc,
    n_total = n,
    n_old_stored = sum(!is.na(sub$a_co2_fu)),
    n_exo_draw = sum(!is.na(sub$b_co2_fu)),
    n_phase2 = if (nrow(p2_sub) > 0) nrow(p2_sub) else 0L,
    mean_C_audit = round(c_mean, 6),
    mean_A_old = round(a_mean, 6),
    mean_B_exo = round(b_mean, 6),
    mean_D_phase2 = round(d_mean, 6),
    delta_CA = round(c_mean - a_mean, 6),
    delta_CB = round(c_mean - b_mean, 6),
    delta_CD = round(c_mean - d_mean, 6),
    pct_CA = round(100 * (c_mean - a_mean) / a_mean, 1),
    pct_CB = round(100 * (c_mean - b_mean) / b_mean, 1),
    pct_CD = round(100 * (c_mean - d_mean) / d_mean, 1)
  )
}

delta_tbl <- rbindlist(delta_rows)
fwrite(delta_tbl, file.path(tbl_dir, "fu_delta_by_scenario.csv"))
cat("  fu_delta_by_scenario.csv written.\n")
print(delta_tbl)

## ── Ranking comparison: BEV vs diesel ────────────────────────────────────────
## Key question: does the BEV-vs-diesel ranking flip depending on which FU
## method is used? This table answers that for each product type and method.
cat("\n  Building BEV vs diesel ranking...\n")

ranking_rows <- list()
for (pt in c("dry", "refrigerated")) {
  for (method_name in c("C_audit_uniform", "A_old_stored", "B_exo_draw", "D_phase2")) {
    if (method_name == "C_audit_uniform") {
      d_val <- comp_dt[product_type == pt & powertrain == "diesel", mean(c_co2_fu, na.rm = TRUE)]
      b_val <- comp_dt[product_type == pt & powertrain == "bev", mean(c_co2_fu, na.rm = TRUE)]
    } else if (method_name == "A_old_stored") {
      d_val <- comp_dt[product_type == pt & powertrain == "diesel" & !is.na(a_co2_fu), mean(a_co2_fu)]
      b_val <- comp_dt[product_type == pt & powertrain == "bev" & !is.na(a_co2_fu), mean(a_co2_fu)]
    } else if (method_name == "B_exo_draw") {
      d_val <- comp_dt[product_type == pt & powertrain == "diesel" & !is.na(b_co2_fu), mean(b_co2_fu)]
      b_val <- comp_dt[product_type == pt & powertrain == "bev" & !is.na(b_co2_fu), mean(b_co2_fu)]
    } else if (method_name == "D_phase2" && nrow(p2) > 0) {
      d_val <- p2[product_type == pt & powertrain == "diesel", mean(co2_per_1000kcal)]
      b_val <- p2[product_type == pt & powertrain == "bev", mean(co2_per_1000kcal)]
    } else {
      next
    }
    if (length(d_val) == 0 || is.na(d_val) || length(b_val) == 0 || is.na(b_val)) next

    ranking_rows[[length(ranking_rows) + 1]] <- data.table(
      product_type = pt,
      method = method_name,
      diesel_mean = round(d_val, 6),
      bev_mean = round(b_val, 6),
      bev_minus_diesel = round(b_val - d_val, 6),
      pct_reduction = round(100 * (d_val - b_val) / d_val, 1),
      bev_wins = b_val < d_val
    )
  }
}

ranking_tbl <- rbindlist(ranking_rows)
fwrite(ranking_tbl, file.path(tbl_dir, "bev_vs_diesel_ranking.csv"))
cat("  bev_vs_diesel_ranking.csv written.\n")
print(ranking_tbl)

## ── Distribution overlay figures ─────────────────────────────────────────────
## Visualize how the four FU methods produce different distributions for the
## same underlying runs. Uses colorblind-safe palette (Okabe-Ito).
cat("\n  Building distribution overlay figures...\n")

## Build long-form dataset: stack all methods with a "method" label column
overlay_list <- list()

## C: audit uniform (all rows)
overlay_list[[1]] <- au[, .(run_id, product_type, powertrain,
                             co2_per_1000kcal, method = "C_audit_uniform")]

## A: old stored (rows with values)
a_sub <- orig[!is.na(co2_per_1000kcal)]
overlay_list[[2]] <- a_sub[, .(run_id, product_type, powertrain,
                                co2_per_1000kcal, method = "A_old_stored")]

## B: exo draw (recovered rows)
b_sub <- merge(enrich[, .(run_id, co2_per_1000kcal)],
               au[, .(run_id, product_type, powertrain)],
               by = "run_id")
overlay_list[[3]] <- b_sub[, .(run_id, product_type, powertrain,
                                co2_per_1000kcal, method = "B_exo_draw")]

## D: phase2
if (nrow(p2) > 0) {
  overlay_list[[4]] <- p2[, .(run_id = paste0("p2_", .I), product_type, powertrain,
                               co2_per_1000kcal, method = "D_phase2")]
}

overlay <- rbindlist(overlay_list, fill = TRUE)

method_colors <- c(
  "A_old_stored" = "#E69F00",
  "B_exo_draw" = "#56B4E9",
  "C_audit_uniform" = "#009E73",
  "D_phase2" = "#CC79A7"
)

## Overlay density by product_type
for (pt in c("dry", "refrigerated")) {
  sub <- overlay[product_type == pt & is.finite(co2_per_1000kcal)]
  if (nrow(sub) < 10) next

  p <- ggplot(sub, aes(x = co2_per_1000kcal, fill = method, color = method)) +
    geom_density(alpha = 0.25, linewidth = 0.8) +
    scale_fill_manual(values = method_colors) +
    scale_color_manual(values = method_colors) +
    facet_wrap(~powertrain, scales = "free") +
    labs(title = sprintf("FU Distribution Overlay: %s product", pt),
         subtitle = "Four FU computation methods compared",
         x = "kg CO2 / 1000 kcal", fill = "Method", color = "Method") +
    theme_audit + theme(legend.position = "bottom")
  ggsave(file.path(fig_dir, sprintf("overlay_%s_density.png", pt)), p,
         width = 12, height = 6, dpi = 150)
}

## Combined CDF overlay
p_cdf <- ggplot(overlay[is.finite(co2_per_1000kcal)],
                aes(x = co2_per_1000kcal, color = method, linetype = method)) +
  stat_ecdf(linewidth = 0.8) +
  scale_color_manual(values = method_colors) +
  facet_grid(product_type ~ powertrain, scales = "free_x") +
  labs(title = "CDF Overlay: All FU Methods",
       x = "kg CO2 / 1000 kcal", y = "Cumulative Probability",
       color = "Method", linetype = "Method") +
  theme_audit + theme(legend.position = "bottom")
ggsave(file.path(fig_dir, "overlay_cdf_all.png"), p_cdf, width = 14, height = 8, dpi = 150)

## Boxplot comparison across methods
p_box <- ggplot(overlay[is.finite(co2_per_1000kcal)],
                aes(x = method, y = co2_per_1000kcal, fill = method)) +
  geom_boxplot(outlier.size = 0.3, outlier.alpha = 0.2) +
  scale_fill_manual(values = method_colors) +
  facet_grid(product_type ~ powertrain, scales = "free_y") +
  labs(title = "CO2/1000kcal by FU Method",
       x = NULL, y = "kg CO2 / 1000 kcal") +
  theme_audit + theme(legend.position = "none",
                      axis.text.x = element_text(angle = 30, hjust = 1, size = 8))
ggsave(file.path(fig_dir, "overlay_boxplot_methods.png"), p_box, width = 14, height = 8, dpi = 150)

cat("  Overlay figures written.\n")

## ── Payload comparison figure ────────────────────────────────────────────────
## The payload (denominator of FU) is the root cause of method disagreement.
## This figure shows why: methods A/B/C use fundamentally different payload
## definitions, producing different tonnes-per-truck distributions.
pay_list <- list()
pay_list[[1]] <- comp_dt[, .(payload_kg = c_payload_kg, method = "C_audit_uniform",
                              product_type, powertrain)]
pay_list[[2]] <- comp_dt[!is.na(a_payload_kg), .(payload_kg = a_payload_kg, method = "A_old_stored",
                                                   product_type, powertrain)]
pay_list[[3]] <- comp_dt[!is.na(b_payload_kg), .(payload_kg = b_payload_kg, method = "B_exo_draw",
                                                   product_type, powertrain)]
pay_dt <- rbindlist(pay_list)

p_pay <- ggplot(pay_dt[is.finite(payload_kg)],
                aes(x = payload_kg / 1000, fill = method, color = method)) +
  geom_density(alpha = 0.25, linewidth = 0.8) +
  scale_fill_manual(values = method_colors) +
  scale_color_manual(values = method_colors) +
  facet_wrap(~product_type, scales = "free") +
  labs(title = "Payload Distribution by FU Method",
       subtitle = "The denominator driving FU differences",
       x = "Payload (tonnes)", fill = "Method", color = "Method") +
  theme_audit + theme(legend.position = "bottom")
ggsave(file.path(fig_dir, "overlay_payload_density.png"), p_pay, width = 12, height = 5, dpi = 150)
cat("  Payload overlay written.\n")

## ── Summary statistics table ─────────────────────────────────────────────────
cat("\n  Building summary statistics...\n")

summary_rows <- list()
for (sc in unique(overlay$scenario <- paste0(overlay$product_type, "/", overlay$powertrain))) {
  for (m in unique(overlay$method)) {
    vals <- overlay[scenario == sc & method == m & is.finite(co2_per_1000kcal), co2_per_1000kcal]
    if (length(vals) == 0) next
    summary_rows[[length(summary_rows) + 1]] <- data.table(
      scenario = sc,
      method = m,
      n = length(vals),
      mean = round(mean(vals), 6),
      sd = round(sd(vals), 6),
      p05 = round(quantile(vals, 0.05), 6),
      p25 = round(quantile(vals, 0.25), 6),
      p50 = round(quantile(vals, 0.50), 6),
      p75 = round(quantile(vals, 0.75), 6),
      p95 = round(quantile(vals, 0.95), 6)
    )
  }
}

summary_tbl <- rbindlist(summary_rows)
fwrite(summary_tbl, file.path(tbl_dir, "fu_summary_statistics.csv"))
cat("  fu_summary_statistics.csv written.\n")

## ── Final output listing ─────────────────────────────────────────────────────
cat("\n=== OUTPUT FILES ===\n")
all_files <- list.files(OUTDIR, recursive = TRUE)
for (f in all_files) cat(sprintf("  %s\n", f))

cat(sprintf("\n=== DONE: %d tables, %d figures ===\n",
            length(list.files(tbl_dir)), length(list.files(fig_dir))))
