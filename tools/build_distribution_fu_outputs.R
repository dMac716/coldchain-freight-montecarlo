#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--diesel_summary"), type = "character"),
  make_option(c("--diesel_runs"), type = "character"),
  make_option(c("--bev_summary"), type = "character"),
  make_option(c("--bev_runs"), type = "character"),
  make_option(c("--diesel_bundle_root"), type = "character", default = ""),
  make_option(c("--bev_bundle_root"), type = "character", default = ""),
  make_option(c("--routes_csv"), type = "character", default = "data/derived/routes_facility_to_petco.csv"),
  make_option(c("--outdir"), type = "character", default = "outputs/distribution_fu"),
  make_option(c("--validation_label"), type = "character", default = "phase"),
  make_option(c("--strict"), type = "character", default = "true")
)))

`%||%` <- function(x, y) if (is.null(x)) y else x
parse_bool <- function(x, default = TRUE) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Boolean value expected, got: ", as.character(x))
}

load_product_defaults <- function(path = file.path("data", "inputs_local", "products.csv")) {
  if (!file.exists(path)) {
    return(data.table::data.table(
      product_type = c("dry", "refrigerated"),
      kcal_per_kg_default = c(3675, 2375),
      packaging_mass_frac_default = c(0.0121, 0.0118942731277533),
      net_fill_kg_default = c(15.8757, 2.27),
      primary_package_kg_default = c(0.192096, 0.027),
      gross_mass_kg_default = c(NA_real_, 2.297)
    ))
  }
  p <- data.table::fread(path, showProgress = FALSE)
  if (!all(c("preservation", "kcal_per_kg") %in% names(p))) {
    return(data.table::data.table(
      product_type = c("dry", "refrigerated"),
      kcal_per_kg_default = c(3675, 2375),
      packaging_mass_frac_default = c(0.0121, 0.0118942731277533),
      net_fill_kg_default = c(15.8757, 2.27),
      primary_package_kg_default = c(0.192096, 0.027),
      gross_mass_kg_default = c(NA_real_, 2.297)
    ))
  }
  p[, product_type := tolower(trimws(as.character(preservation)))]
  p[, kcal_per_kg_default := suppressWarnings(as.numeric(kcal_per_kg))]
  p[, packaging_mass_frac_default := suppressWarnings(as.numeric(packaging_mass_frac))]
  p[, net_fill_kg_default := suppressWarnings(as.numeric(net_fill_kg))]
  p[, primary_package_kg_default := suppressWarnings(as.numeric(primary_package_kg))]
  p[, gross_mass_kg_default := suppressWarnings(as.numeric(gross_mass_kg))]
  p <- p[product_type %in% c("dry", "refrigerated") & is.finite(kcal_per_kg_default) & kcal_per_kg_default > 0]
  if (nrow(p) == 0) {
    return(data.table::data.table(
      product_type = c("dry", "refrigerated"),
      kcal_per_kg_default = c(3675, 2375),
      packaging_mass_frac_default = c(0.0121, 0.0118942731277533),
      net_fill_kg_default = c(15.8757, 2.27),
      primary_package_kg_default = c(0.192096, 0.027),
      gross_mass_kg_default = c(NA_real_, 2.297)
    ))
  }
  unique(
    p[, .(
      product_type,
      kcal_per_kg_default,
      packaging_mass_frac_default,
      net_fill_kg_default,
      primary_package_kg_default,
      gross_mass_kg_default
    )],
    by = "product_type"
  )
}

strict <- parse_bool(opt$strict, TRUE)
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

must_exist <- function(path) {
  if (!file.exists(path)) stop("Missing required file: ", path)
}
must_exist(opt$diesel_runs)
must_exist(opt$bev_runs)
must_exist(opt$routes_csv)

read_pair <- function(summary_csv, runs_csv, bundle_root, powertrain_label) {
  if (nzchar(bundle_root) && dir.exists(bundle_root)) {
    summ_paths <- list.files(bundle_root, pattern = "summaries\\.csv$", recursive = TRUE, full.names = TRUE)
    summ_paths <- summ_paths[grepl("/pair_", dirname(summ_paths))]
    pt_tag <- paste0("/", tolower(as.character(powertrain_label %||% "")), "/")
    if (nzchar(pt_tag)) {
      summ_paths_pt <- summ_paths[grepl(pt_tag, summ_paths, fixed = TRUE)]
      if (length(summ_paths_pt) > 0) summ_paths <- summ_paths_pt
    }
    if (length(summ_paths) > 0) {
      s <- data.table::rbindlist(lapply(summ_paths, function(p) data.table::fread(p, showProgress = FALSE)), fill = TRUE, use.names = TRUE)
    } else if (nzchar(summary_csv) && file.exists(summary_csv)) {
      s <- data.table::fread(summary_csv)
    } else {
      stop("No per-run summaries found under bundle_root and no summary csv provided for ", powertrain_label)
    }
  } else if (nzchar(summary_csv) && file.exists(summary_csv)) {
    s <- data.table::fread(summary_csv)
  } else {
    stop("Missing summary source for ", powertrain_label)
  }
  r <- data.table::fread(runs_csv)
  s[, run_id := as.character(run_id)]
  r[, run_id := as.character(run_id)]
  if (!"powertrain" %in% names(s)) s[, powertrain := tolower(as.character(powertrain_label))]
  if (!"powertrain" %in% names(r)) r[, powertrain := tolower(as.character(powertrain_label))]
  x <- merge(s, r, by = "run_id", all.x = TRUE, suffixes = c("", ".runs"))
  x[, powertrain := tolower(as.character(powertrain))]
  x
}

d_diesel <- read_pair(opt$diesel_summary %||% "", opt$diesel_runs, opt$diesel_bundle_root %||% "", "diesel")
d_bev <- read_pair(opt$bev_summary %||% "", opt$bev_runs, opt$bev_bundle_root %||% "", "bev")
d <- data.table::rbindlist(list(d_diesel, d_bev), fill = TRUE, use.names = TRUE)

routes <- data.table::fread(opt$routes_csv)
if (!all(c("route_id", "distance_m") %in% names(routes))) stop("routes_csv must include route_id,distance_m")
routes <- unique(routes[, .(route_id = as.character(route_id), base_route_distance_miles = as.numeric(distance_m) / 1609.344, retail_id = as.character(retail_id %||% NA_character_))], by = "route_id")
d <- merge(d, routes, by = "route_id", all.x = TRUE)

for (cn in c("pair_id", "origin_network", "scenario", "route_id", "status", "traffic_mode", "run_id")) {
  if (!cn %in% names(d)) d[, (cn) := NA_character_]
}
if (!"route_completed" %in% names(d)) d[, route_completed := NA]
if ("route_completed.runs" %in% names(d) && !"route_completed" %in% names(d)) d[, route_completed := route_completed.runs]
if ("route_completed.runs" %in% names(d)) {
  d[is.na(route_completed), route_completed := route_completed.runs]
}
if ("route_completed" %in% names(d)) {
  d[, route_completed := as.logical(route_completed)]
  d[is.na(route_completed), route_completed := !grepl("INCOMPLETE_ROUTE", toupper(as.character(status %||% "")), fixed = TRUE)]
}
for (cn in c("distance_miles", "trip_duration_total_h", "traffic_delay_time_h", "driving_time_h", "energy_kwh_total",
             "energy_kwh_propulsion", "energy_kwh_tru", "diesel_gal_propulsion", "diesel_gal_tru", "co2_kg_total",
             "charge_stops", "charging_or_refueling_time_h", "kcal_delivered", "kcal_per_truck", "kcal_per_kg_product", "product_mass_lb_per_truck",
             "payload_lb", "actual_units_loaded",
             "ambient_f", "traffic_multiplier", "queue_delay_minutes", "delivery_time_min", "time_charging_min", "congestion_delay_hours")) {
  if (!cn %in% names(d)) d[, (cn) := NA_real_]
  d[, (cn) := suppressWarnings(as.numeric(get(cn)))]
}

d[, shared_seed := suppressWarnings(as.integer(sub("^.*_seed_([0-9]+).*$", "\\1", as.character(pair_id))))]
d[, replicate_id := as.integer(factor(shared_seed, levels = sort(unique(shared_seed))))]
d[, scenario_name := data.table::fifelse(powertrain == "diesel" & origin_network == "dry_factory_set", "dry_diesel",
                             data.table::fifelse(powertrain == "diesel" & origin_network == "refrigerated_factory_set", "refrigerated_diesel",
                             data.table::fifelse(powertrain == "bev" & origin_network == "dry_factory_set", "dry_bev",
                             data.table::fifelse(powertrain == "bev" & origin_network == "refrigerated_factory_set", "refrigerated_bev", NA_character_))))]
d[, origin_name := data.table::fifelse(origin_network == "dry_factory_set", "Kansas Plant",
                           data.table::fifelse(origin_network == "refrigerated_factory_set", "Texas Plant", as.character(origin_network)))]
d[, destination_name := "Davis, CA Petco"]
d[, reefer_on := as.logical(origin_network == "refrigerated_factory_set")]
if (!"traffic_state_id" %in% names(d)) d[, traffic_state_id := NA_character_]
d[is.na(traffic_state_id) | !nzchar(trimws(as.character(traffic_state_id))),
  traffic_state_id := paste0(as.character(traffic_mode), "_tm", formatC(traffic_multiplier, format = "f", digits = 4), "_qd", formatC(queue_delay_minutes, format = "f", digits = 2))]
d[, departure_state_id := paste0("seed_", shared_seed)]
d[, ambient_state_id := paste0("ambient_", formatC(ambient_f, format = "f", digits = 2))]
d[, trip_distance_miles := as.numeric(distance_miles)]
d[, trip_duration_hours := as.numeric(trip_duration_total_h)]
d[!is.finite(congestion_delay_hours), congestion_delay_hours := as.numeric(traffic_delay_time_h) + (as.numeric(queue_delay_minutes) / 60)]
d[, refrigeration_runtime_hours := data.table::fifelse(reefer_on, pmax(0, as.numeric(driving_time_h) + as.numeric(traffic_delay_time_h) + as.numeric(charging_or_refueling_time_h)), 0)]
d[, diesel_gallons := as.numeric(diesel_gal_propulsion) + as.numeric(diesel_gal_tru)]
d[, traction_electricity_kwh := as.numeric(energy_kwh_propulsion)]
d[, charging_events := as.integer(round(charge_stops))]
d[, charging_energy_kwh := as.numeric(energy_kwh_total)]
d[, charging_time_hours := data.table::fifelse(powertrain == "bev", as.numeric(charging_or_refueling_time_h), 0)]
d[, total_trip_co2_kg := as.numeric(co2_kg_total)]
d[, payload_kg_delivered := as.numeric(product_mass_lb_per_truck) * 0.45359237]
d[!is.finite(payload_kg_delivered) | payload_kg_delivered <= 0, payload_kg_delivered := as.numeric(payload_lb) * 0.45359237]
d[, product_type_inferred := data.table::fifelse(reefer_on, "refrigerated", "dry")]
product_defaults <- load_product_defaults()
d <- merge(d, product_defaults, by.x = "product_type_inferred", by.y = "product_type", all.x = TRUE)
d[, unit_mass_kg_default := as.numeric(gross_mass_kg_default)]
d[
  !is.finite(unit_mass_kg_default) | unit_mass_kg_default <= 0,
  unit_mass_kg_default := as.numeric(net_fill_kg_default) + as.numeric(primary_package_kg_default)
]
d[
  !is.finite(unit_mass_kg_default) | unit_mass_kg_default <= 0,
  unit_mass_kg_default := as.numeric(net_fill_kg_default) * (1 + as.numeric(packaging_mass_frac_default))
]
d[
  (!is.finite(payload_kg_delivered) | payload_kg_delivered <= 0) &
    is.finite(actual_units_loaded) & actual_units_loaded > 0 &
    is.finite(unit_mass_kg_default) & unit_mass_kg_default > 0,
  payload_kg_delivered := as.numeric(actual_units_loaded) * as.numeric(unit_mass_kg_default)
]
d[, energy_density_kcal_per_kg := suppressWarnings(as.numeric(kcal_per_kg_product))]
d[!is.finite(energy_density_kcal_per_kg) | energy_density_kcal_per_kg <= 0, energy_density_kcal_per_kg := suppressWarnings(as.numeric(kcal_per_kg_default))]
d[, total_kcal_delivered := suppressWarnings(as.numeric(kcal_delivered))]
d[!is.finite(total_kcal_delivered) | total_kcal_delivered <= 0, total_kcal_delivered := suppressWarnings(as.numeric(kcal_per_truck))]
d[
  (!is.finite(total_kcal_delivered) | total_kcal_delivered <= 0) &
    is.finite(payload_kg_delivered) & payload_kg_delivered > 0 &
    is.finite(energy_density_kcal_per_kg) & energy_density_kcal_per_kg > 0,
  total_kcal_delivered := payload_kg_delivered * energy_density_kcal_per_kg
]
d[, co2_per_1000kcal := data.table::fifelse(
  is.finite(total_trip_co2_kg) &
    is.finite(total_kcal_delivered) &
    total_kcal_delivered > 0,
  total_trip_co2_kg / total_kcal_delivered * 1000,
  NA_real_
)]

req_scen <- c("dry_diesel", "refrigerated_diesel", "dry_bev", "refrigerated_bev")
fails <- character()
fail_row <- function(msg) fails <<- c(fails, msg)

# 1) Completeness
chk_comp <- d[, .(n = .N, n_scen = data.table::uniqueN(scenario_name), scen = paste(sort(unique(scenario_name)), collapse = "|")), by = replicate_id]
if (nrow(chk_comp[n_scen != 4]) > 0) fail_row(paste0("scenario completeness failed: ", paste(chk_comp[n_scen != 4, paste0("replicate=", replicate_id, " scen=", scen)], collapse = "; ")))

# 2) Within-pair shared uncertainty
for (pt in c("diesel", "bev")) {
  w <- d[powertrain == pt, .(n_traffic = data.table::uniqueN(traffic_state_id), n_depart = data.table::uniqueN(departure_state_id), n_amb = data.table::uniqueN(ambient_state_id)), by = replicate_id]
  if (nrow(w[n_traffic > 1 | n_depart > 1 | n_amb > 1]) > 0) fail_row(paste0("shared uncertainty failed for ", pt))
}
if (nrow(d[is.na(traffic_state_id) | !nzchar(trimws(as.character(traffic_state_id)))]) > 0) fail_row("traffic_state_id missing/non-finite")

# 3) Origin/reefer consistency
if (nrow(d[scenario_name %in% c("dry_diesel", "dry_bev") & (origin_name != "Kansas Plant" | reefer_on)]) > 0) fail_row("dry origin/reefer consistency failed")
if (nrow(d[scenario_name %in% c("refrigerated_diesel", "refrigerated_bev") & (origin_name != "Texas Plant" | !reefer_on)]) > 0) fail_row("refrigerated origin/reefer consistency failed")

# 4) Cross-powertrain route consistency by origin
match_chk <- d[, .(
  n_route = data.table::uniqueN(route_id),
  n_base_dist = data.table::uniqueN(round(base_route_distance_miles, 6))
), by = .(replicate_id, origin_network)]
if (nrow(match_chk[n_route != 1 | n_base_dist != 1]) > 0) fail_row("diesel/bev route identity mismatch within origin")

# 5) Plausibility
if ("route_completed" %in% names(d) && nrow(d[route_completed != TRUE]) > 0) {
  fail_row("route completion failed: incomplete route present; abort before FU export")
}
if (nrow(d[!is.finite(base_route_distance_miles) | base_route_distance_miles < 1000 | base_route_distance_miles > 2500]) > 0) fail_row("base route distance plausibility failed")
if (nrow(d[!is.finite(trip_distance_miles) | trip_distance_miles <= 0 | trip_distance_miles < 0.5 * base_route_distance_miles]) > 0) fail_row("trip distance plausibility failed (possible incomplete route)")
if (nrow(d[!is.finite(trip_duration_hours) | trip_duration_hours <= 0]) > 0) fail_row("trip duration plausibility failed")

# 6) Traffic realism
if (nrow(d[!is.finite(congestion_delay_hours) | congestion_delay_hours <= 0]) > 0) fail_row("traffic realism failed: zero/non-finite congestion delay")

# 7) Non-finite checks
crit_cols <- c("trip_distance_miles", "trip_duration_hours", "total_trip_co2_kg", "payload_kg_delivered", "total_kcal_delivered", "co2_per_1000kcal")
for (cn in crit_cols) if (nrow(d[!is.finite(get(cn))]) > 0) fail_row(paste0("non-finite critical metric: ", cn))
if (nrow(d[payload_kg_delivered <= 0 | total_kcal_delivered <= 0 | total_trip_co2_kg < 0]) > 0) fail_row("impossible negative/zero critical values")

# 8) Dry reefer off checks
if (nrow(d[scenario_name %in% c("dry_diesel", "dry_bev") & ((is.finite(diesel_gal_tru) & diesel_gal_tru > 1e-9) | (is.finite(energy_kwh_tru) & energy_kwh_tru > 1e-9))]) > 0) {
  fail_row("dry reefer usage nonzero")
}

validation_path <- file.path(opt$outdir, "transport_sim_validation_report.txt")
if (length(fails) > 0) {
  bad_rows <- d[1:min(.N, 20), .(replicate_id, scenario_name, powertrain, origin_name, destination_name, reefer_on, shared_seed, route_id, trip_distance_miles, trip_duration_hours, congestion_delay_hours, charge_stops, co2_per_1000kcal)]
  table_txt <- capture.output(print(bad_rows))
  lines <- c(
    paste0("VALIDATION: FAIL (", opt$validation_label, ")"),
    unique(fails),
    "",
    "Offending rows (first 20):",
    table_txt
  )
  writeLines(lines, con = validation_path)
  if (strict) stop(paste(unique(fails), collapse = " | "))
}

rows_out <- d[, .(
  replicate_id, pair_id, scenario_name, powertrain, origin_name, destination_name, reefer_on,
  shared_seed, traffic_state_id, departure_state_id, ambient_state_id,
  route_id, base_route_distance_miles, trip_distance_miles, trip_duration_hours, congestion_delay_hours,
  refrigeration_runtime_hours, diesel_gallons, traction_electricity_kwh, charging_events,
  charging_energy_kwh, charging_time_hours, total_trip_co2_kg, payload_kg_delivered,
  energy_density_kcal_per_kg, total_kcal_delivered, co2_per_1000kcal
)]
data.table::setorder(rows_out, replicate_id, scenario_name)

# Required compact validation print for replicate 1
rep1 <- rows_out[replicate_id == min(replicate_id, na.rm = TRUE), .(
  replicate_id, scenario_name, powertrain, origin_name, destination_name, reefer_on,
  shared_seed, traffic_state_id, trip_distance_miles, trip_duration_hours,
  congestion_delay_hours, refrigeration_runtime_hours, total_trip_co2_kg, co2_per_1000kcal
)]
print(rep1)

wide1 <- data.table::dcast(rep1, replicate_id ~ scenario_name, value.var = "co2_per_1000kcal")
if (nrow(wide1) > 0) {
  diesel_delta <- as.numeric(wide1$refrigerated_diesel - wide1$dry_diesel)
  bev_delta <- as.numeric(wide1$refrigerated_bev - wide1$dry_bev)
  cat("diesel paired delta per 1000 kcal:", diesel_delta, "\n")
  cat("BEV paired delta per 1000 kcal:", bev_delta, "\n")
}

pair_summ <- data.table::dcast(rows_out, replicate_id + shared_seed ~ scenario_name, value.var = "co2_per_1000kcal")
pair_summ[, delta_diesel_co2_per_1000kcal := refrigerated_diesel - dry_diesel]
pair_summ[, delta_bev_co2_per_1000kcal := refrigerated_bev - dry_bev]

power_summ <- rows_out[, .(
  n = .N,
  mean = mean(co2_per_1000kcal, na.rm = TRUE),
  median = stats::median(co2_per_1000kcal, na.rm = TRUE),
  p05 = as.numeric(stats::quantile(co2_per_1000kcal, 0.05, na.rm = TRUE, names = FALSE)),
  p50 = as.numeric(stats::quantile(co2_per_1000kcal, 0.50, na.rm = TRUE, names = FALSE)),
  p95 = as.numeric(stats::quantile(co2_per_1000kcal, 0.95, na.rm = TRUE, names = FALSE))
), by = .(scenario_name, powertrain)]

delta_summ <- pair_summ[, .(
  mean_paired_diesel_delta = mean(delta_diesel_co2_per_1000kcal, na.rm = TRUE),
  mean_paired_bev_delta = mean(delta_bev_co2_per_1000kcal, na.rm = TRUE),
  median_paired_diesel_delta = stats::median(delta_diesel_co2_per_1000kcal, na.rm = TRUE),
  median_paired_bev_delta = stats::median(delta_bev_co2_per_1000kcal, na.rm = TRUE),
  p05_paired_diesel_delta = as.numeric(stats::quantile(delta_diesel_co2_per_1000kcal, 0.05, na.rm = TRUE, names = FALSE)),
  p95_paired_diesel_delta = as.numeric(stats::quantile(delta_diesel_co2_per_1000kcal, 0.95, na.rm = TRUE, names = FALSE)),
  p05_paired_bev_delta = as.numeric(stats::quantile(delta_bev_co2_per_1000kcal, 0.05, na.rm = TRUE, names = FALSE)),
  p95_paired_bev_delta = as.numeric(stats::quantile(delta_bev_co2_per_1000kcal, 0.95, na.rm = TRUE, names = FALSE)),
  valid_replicates = .N
)]

graphics_inputs <- power_summ[, .(
  scenario_name,
  mean_co2_per_1000kcal = mean,
  p05_co2_per_1000kcal = p05,
  p95_co2_per_1000kcal = p95
)]
if (nrow(delta_summ) > 0) {
  for (cn in names(delta_summ)) graphics_inputs[, (cn) := delta_summ[[cn]][[1]]]
}

data.table::fwrite(rows_out, file.path(opt$outdir, "transport_sim_rows.csv"))
data.table::fwrite(pair_summ, file.path(opt$outdir, "transport_sim_paired_summary.csv"))
data.table::fwrite(power_summ, file.path(opt$outdir, "transport_sim_powertrain_summary.csv"))
data.table::fwrite(graphics_inputs, file.path(opt$outdir, "transport_sim_graphics_inputs.csv"))

if (length(fails) == 0) {
  writeLines(c(
    paste0("VALIDATION: PASS (", opt$validation_label, ")"),
    paste0("rows=", nrow(rows_out)),
    paste0("replicates=", data.table::uniqueN(rows_out$replicate_id))
  ), con = validation_path)
}

cat("Wrote outputs under ", opt$outdir, "\n", sep = "")
