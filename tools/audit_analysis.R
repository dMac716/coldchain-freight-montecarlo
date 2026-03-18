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

tbl_dir <- file.path(output_dir, "tables")
fig_dir <- file.path(output_dir, "figures")
dir.create(tbl_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(fig_dir, showWarnings = FALSE, recursive = TRUE)

# ---- Derive FU-normalized metrics ----
if (all(is.na(dt$kcal_delivered)) || sum(!is.na(dt$kcal_delivered)) == 0) {
  cat("[R] Deriving FU metrics from payload + kcal_per_kg_product\n")
  dt[, payload_kg := payload_max_lb_draw * load_fraction * 0.453592]
  dt[, kcal_delivered := payload_kg * kcal_per_kg_product]
  dt[, co2_per_1000kcal := co2_kg_total / kcal_delivered * 1000]
}

# ---- Scenario labels ----
dt[, scenario_label := paste0(
  ifelse(product_type == "dry", "Dry", "Refrig"), " / ",
  ifelse(origin_network == "dry_factory_set", "Centralized", "Regionalized"), " / ",
  toupper(powertrain)
)]

# ============================================================
# COMPREHENSIVE SCENARIO TABLE with all requested metrics
# ============================================================
comprehensive <- dt[, .(
  n_runs = .N,
  n_unique_pairs = uniqueN(pair_id),

  # --- Total Emissions ---
  mean_co2_kg_total = round(mean(co2_kg_total, na.rm = TRUE), 2),
  sd_co2_kg_total = round(sd(co2_kg_total, na.rm = TRUE), 2),
  p05_co2_kg = round(quantile(co2_kg_total, 0.05, na.rm = TRUE), 2),
  p50_co2_kg = round(quantile(co2_kg_total, 0.50, na.rm = TRUE), 2),
  p95_co2_kg = round(quantile(co2_kg_total, 0.95, na.rm = TRUE), 2),
  mean_co2_kg_propulsion = round(mean(co2_kg_propulsion, na.rm = TRUE), 2),
  mean_co2_kg_tru = round(mean(co2_kg_tru, na.rm = TRUE), 2),

  # --- Functional Unit Metrics (CO2 per 1000 kcal) ---
  mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 6),
  sd_co2_per_1000kcal = round(sd(co2_per_1000kcal, na.rm = TRUE), 6),
  p05_co2_per_1000kcal = round(quantile(co2_per_1000kcal, 0.05, na.rm = TRUE), 6),
  p50_co2_per_1000kcal = round(quantile(co2_per_1000kcal, 0.50, na.rm = TRUE), 6),
  p95_co2_per_1000kcal = round(quantile(co2_per_1000kcal, 0.95, na.rm = TRUE), 6),

  # --- Protein Metrics ---
  mean_protein_per_1000kcal = round(mean(protein_per_1000kcal, na.rm = TRUE), 4),
  mean_co2_per_kg_protein = round(mean(co2_per_kg_protein, na.rm = TRUE), 4),
  mean_co2_g_per_g_protein = round(mean(co2_g_per_g_protein, na.rm = TRUE), 4),

  # --- Driver Time ---
  mean_driving_time_h = round(mean(driving_time_h, na.rm = TRUE), 2),
  mean_driver_driving_min = round(mean(driver_driving_min, na.rm = TRUE), 1),
  mean_driver_on_duty_min = round(mean(driver_on_duty_min, na.rm = TRUE), 1),
  mean_driver_off_duty_min = round(mean(driver_off_duty_min, na.rm = TRUE), 1),
  mean_trip_duration_total_h = round(mean(trip_duration_total_h, na.rm = TRUE), 2),

  # --- Traffic ---
  mean_traffic_delay_h = round(mean(traffic_delay_time_h, na.rm = TRUE), 2),
  mean_congestion_delay_h = round(mean(congestion_delay_hours, na.rm = TRUE), 2),
  mean_time_traffic_delay_min = round(mean(time_traffic_delay_min, na.rm = TRUE), 1),

  # --- Trip Energy (with and without TRU) ---
  mean_energy_kwh_propulsion = round(mean(energy_kwh_propulsion, na.rm = TRUE), 1),
  mean_energy_kwh_tru = round(mean(energy_kwh_tru, na.rm = TRUE), 1),
  mean_energy_kwh_total = round(mean(energy_kwh_total, na.rm = TRUE), 1),
  mean_diesel_gal_propulsion = round(mean(diesel_gal_propulsion, na.rm = TRUE), 2),
  mean_diesel_gal_tru = round(mean(diesel_gal_tru, na.rm = TRUE), 2),

  # --- Charging (BEV) ---
  mean_charge_stops = round(mean(charge_stops, na.rm = TRUE), 2),
  pct_with_charge_stops = round(100 * sum(charge_stops > 0, na.rm = TRUE) / .N, 1),
  mean_time_charging_min = round(mean(time_charging_min, na.rm = TRUE), 1),
  mean_charging_or_refueling_h = round(mean(charging_or_refueling_time_h, na.rm = TRUE), 2),

  # --- Refueling (Diesel) ---
  mean_refuel_stops = round(mean(refuel_stops, na.rm = TRUE), 2),
  mean_time_refuel_min = round(mean(time_refuel_min, na.rm = TRUE), 1),

  # --- Distance ---
  mean_distance_miles = round(mean(distance_miles, na.rm = TRUE), 1),
  mean_duration_minutes = round(mean(duration_minutes, na.rm = TRUE), 1),

  # --- Load ---
  mean_payload_lb = round(mean(payload_max_lb_draw, na.rm = TRUE), 0),
  mean_load_fraction = round(mean(load_fraction, na.rm = TRUE), 3),
  mean_kcal_delivered = round(mean(kcal_delivered, na.rm = TRUE), 0)

), by = .(powertrain, product_type, origin_network)]

fwrite(comprehensive, file.path(tbl_dir, "comprehensive_scenario_stats.csv"))
cat("[R] Wrote comprehensive_scenario_stats.csv\n")

# ---- BEV-specific charging detail ----
bev_dt <- dt[powertrain == "bev"]
bev_detail <- bev_dt[, .(
  n_runs = .N,
  pct_with_charging = round(100 * sum(charge_stops > 0, na.rm = TRUE) / .N, 1),
  mean_charge_stops = round(mean(charge_stops, na.rm = TRUE), 2),
  median_charge_stops = as.double(median(charge_stops, na.rm = TRUE)),
  p05_charge_stops = as.double(quantile(charge_stops, 0.05, na.rm = TRUE)),
  p95_charge_stops = as.double(quantile(charge_stops, 0.95, na.rm = TRUE)),
  mean_time_charging_min = round(mean(time_charging_min, na.rm = TRUE), 1),
  median_time_charging_min = round(median(time_charging_min, na.rm = TRUE), 1),
  mean_energy_kwh_total = round(mean(energy_kwh_total, na.rm = TRUE), 1),
  mean_energy_kwh_tru = round(mean(energy_kwh_tru, na.rm = TRUE), 1),
  mean_co2_kg = round(mean(co2_kg_total, na.rm = TRUE), 2),
  mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 6),
  mean_charging_attempts = round(mean(charging_attempts, na.rm = TRUE), 1),
  mean_occupied_events = round(mean(occupied_events, na.rm = TRUE), 1),
  mean_broken_events = round(mean(broken_events, na.rm = TRUE), 1),
  mean_wait_time_min = round(mean(average_wait_time_minutes, na.rm = TRUE), 1),
  mean_failed_frac = round(mean(failed_charging_attempt_fraction, na.rm = TRUE), 3)
), by = .(product_type, origin_network)]
fwrite(bev_detail, file.path(tbl_dir, "bev_charging_detail.csv"))
cat("[R] Wrote bev_charging_detail.csv\n")

# ---- Runs with charging vs without (comparison) ----
bev_dt[, has_charging := charge_stops > 0]
bev_compare <- bev_dt[, .(
  n = .N,
  mean_co2_kg = round(mean(co2_kg_total, na.rm = TRUE), 2),
  mean_co2_per_1000kcal = round(mean(co2_per_1000kcal, na.rm = TRUE), 6),
  mean_trip_h = round(mean(trip_duration_total_h, na.rm = TRUE), 2),
  mean_energy_kwh = round(mean(energy_kwh_total, na.rm = TRUE), 1),
  mean_distance = round(mean(distance_miles, na.rm = TRUE), 1)
), by = .(product_type, has_charging)]
fwrite(bev_compare, file.path(tbl_dir, "bev_charging_vs_no_charging.csv"))
cat("[R] Wrote bev_charging_vs_no_charging.csv\n")

# ============================================================
# FIGURES
# ============================================================
theme_audit <- theme_minimal(base_size = 12) +
  theme(plot.title = element_text(face = "bold", size = 14),
        axis.text.x = element_text(angle = 45, hjust = 1))

# Fig A: CO2/1000kcal boxplot
p1 <- ggplot(dt, aes(x = scenario_label, y = co2_per_1000kcal, fill = powertrain)) +
  geom_boxplot(outlier.size = 0.3, outlier.alpha = 0.2) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  labs(title = sprintf("CO2 per 1000 kcal by Scenario (n=%s)", comma(nrow(dt))),
       x = NULL, y = "kg CO2 / 1000 kcal") + theme_audit
ggsave(file.path(fig_dir, "fig_a_co2_by_scenario.png"), p1, width = 12, height = 7, dpi = 150)

# Fig B: CO2 density
p2 <- ggplot(dt, aes(x = co2_per_1000kcal, fill = powertrain)) +
  geom_density(alpha = 0.5) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  facet_wrap(~product_type, scales = "free") +
  labs(title = "Emissions Density: Diesel vs BEV", x = "kg CO2 / 1000 kcal") + theme_audit
ggsave(file.path(fig_dir, "fig_b_co2_density.png"), p2, width = 10, height = 5, dpi = 150)

# Fig C: CDF
p3 <- ggplot(dt, aes(x = co2_per_1000kcal, color = scenario_label)) +
  stat_ecdf(linewidth = 0.7) +
  labs(title = "Empirical CDF: CO2 per 1000 kcal", x = "kg CO2 / 1000 kcal",
       y = "Cumulative Probability", color = "Scenario") +
  theme_audit + theme(legend.position = "right", legend.text = element_text(size = 8))
ggsave(file.path(fig_dir, "fig_c_cdf.png"), p3, width = 12, height = 7, dpi = 150)

# Fig D: Emission decomposition
decomp <- dt[, .(propulsion = mean(co2_kg_propulsion, na.rm = TRUE),
                 tru = mean(co2_kg_tru, na.rm = TRUE)),
             by = .(scenario_label, powertrain)]
decomp_long <- melt(decomp, id.vars = c("scenario_label", "powertrain"),
                    variable.name = "component", value.name = "co2_kg")
p4 <- ggplot(decomp_long[!is.na(co2_kg)],
             aes(x = scenario_label, y = co2_kg, fill = component)) +
  geom_col(position = "stack") +
  scale_fill_manual(values = c(propulsion = "steelblue", tru = "coral"),
                    labels = c("Propulsion", "TRU")) +
  labs(title = "Emission Decomposition: Propulsion vs TRU", x = NULL, y = "Mean CO2 (kg)") +
  theme_audit
ggsave(file.path(fig_dir, "fig_d_decomposition.png"), p4, width = 12, height = 7, dpi = 150)

# Fig E: Trip duration
p5 <- ggplot(dt, aes(x = scenario_label, y = trip_duration_total_h, fill = powertrain)) +
  geom_boxplot(outlier.size = 0.3, outlier.alpha = 0.2) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  labs(title = "Trip Duration by Scenario", x = NULL, y = "Hours") + theme_audit
ggsave(file.path(fig_dir, "fig_e_trip_duration.png"), p5, width = 12, height = 7, dpi = 150)

# Fig F: BEV charge stops
p6 <- ggplot(bev_dt, aes(x = factor(charge_stops))) +
  geom_bar(fill = "steelblue") + facet_wrap(~product_type) +
  labs(title = "BEV Charging Stops per Trip", x = "Charge Stops", y = "Count") + theme_audit
ggsave(file.path(fig_dir, "fig_f_charge_stops.png"), p6, width = 10, height = 5, dpi = 150)

# Fig G: Energy breakdown by scenario
energy_dt <- dt[, .(propulsion_kwh = mean(energy_kwh_propulsion, na.rm = TRUE),
                    tru_kwh = mean(energy_kwh_tru, na.rm = TRUE)),
                by = .(scenario_label, powertrain)]
energy_long <- melt(energy_dt, id.vars = c("scenario_label", "powertrain"),
                    variable.name = "component", value.name = "kwh")
p7 <- ggplot(energy_long[!is.na(kwh)],
             aes(x = scenario_label, y = kwh, fill = component)) +
  geom_col(position = "stack") +
  scale_fill_manual(values = c(propulsion_kwh = "steelblue", tru_kwh = "coral"),
                    labels = c("Propulsion", "TRU")) +
  labs(title = "Energy Usage: Propulsion vs TRU", x = NULL, y = "Mean kWh") + theme_audit
ggsave(file.path(fig_dir, "fig_g_energy_breakdown.png"), p7, width = 12, height = 7, dpi = 150)

# Fig H: Electrification benefit (standard networks only)
std_nets <- c("dry_factory_set", "refrigerated_factory_set")
delta <- merge(
  dt[powertrain == "diesel" & origin_network %in% std_nets,
     .(diesel_co2 = median(co2_per_1000kcal, na.rm = TRUE)),
     by = .(product_type, origin_network)],
  dt[powertrain == "bev" & origin_network %in% std_nets,
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
  labs(title = "Electrification: % CO2 Reduction vs Diesel (median)",
       x = NULL, y = "% Reduction") + theme_audit
ggsave(file.path(fig_dir, "fig_h_electrification.png"), p8, width = 8, height = 6, dpi = 150)

# Fig I: Driver time breakdown
driver_dt <- dt[, .(driving = mean(driver_driving_min, na.rm = TRUE),
                    charging = mean(time_charging_min, na.rm = TRUE),
                    refueling = mean(time_refuel_min, na.rm = TRUE),
                    traffic = mean(time_traffic_delay_min, na.rm = TRUE),
                    rest = mean(driver_off_duty_min, na.rm = TRUE)),
                by = .(scenario_label, powertrain)]
driver_long <- melt(driver_dt, id.vars = c("scenario_label", "powertrain"),
                    variable.name = "activity", value.name = "minutes")
p9 <- ggplot(driver_long[!is.na(minutes)],
             aes(x = scenario_label, y = minutes / 60, fill = activity)) +
  geom_col(position = "stack") +
  scale_fill_brewer(palette = "Set2") +
  labs(title = "Driver Time Breakdown", x = NULL, y = "Hours", fill = "Activity") + theme_audit
ggsave(file.path(fig_dir, "fig_i_driver_time.png"), p9, width = 12, height = 7, dpi = 150)

# Fig J: TRU energy per trip
p10 <- ggplot(dt[!is.na(energy_kwh_tru) & energy_kwh_tru > 0],
              aes(x = scenario_label, y = energy_kwh_tru, fill = powertrain)) +
  geom_boxplot(outlier.size = 0.3, outlier.alpha = 0.2) +
  scale_fill_manual(values = c(bev = "steelblue", diesel = "coral")) +
  labs(title = "TRU Energy per Trip", x = NULL, y = "TRU Energy (kWh)") + theme_audit
ggsave(file.path(fig_dir, "fig_j_tru_energy.png"), p10, width = 12, height = 7, dpi = 150)

cat(sprintf("\n[R] COMPREHENSIVE AUDIT COMPLETE: %d runs, %d scenarios\n",
            nrow(dt), uniqueN(dt$scenario_label)))
