#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

option_list <- list(
  make_option(c("--tracks_dir"), type = "character", default = "outputs/sim_tracks"),
  make_option(c("--events_dir"), type = "character", default = "outputs/sim_events"),
  make_option(c("--bundle_dir"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--outdir"), type = "character", default = "outputs/analysis")
)
opt <- parse_args(OptionParser(option_list = option_list))

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

track_files <- list.files(opt$tracks_dir, pattern = "\\.csv$", full.names = TRUE)
if (length(track_files) == 0) stop("No sim track files found in ", opt$tracks_dir)

rows <- list()
for (f in track_files) {
  if (!isTRUE(file.info(f)$size > 0)) next
  run_id <- sub("\\.csv$", "", basename(f))
  tr <- tryCatch(utils::read.csv(f, stringsAsFactors = FALSE), error = function(e) data.frame())
  if (nrow(tr) == 0) next
  ev_path <- file.path(opt$events_dir, paste0(run_id, ".csv"))
  ev <- if (file.exists(ev_path) && isTRUE(file.info(ev_path)$size > 0)) {
    tryCatch(utils::read.csv(ev_path, stringsAsFactors = FALSE), error = function(e) data.frame())
  } else data.frame()
  bundle_summary_path <- file.path(opt$bundle_dir, run_id, "summaries.csv")
  bsum <- if (file.exists(bundle_summary_path) && isTRUE(file.info(bundle_summary_path)$size > 0)) {
    tryCatch(utils::read.csv(bundle_summary_path, stringsAsFactors = FALSE), error = function(e) data.frame())
  } else data.frame()

  last <- tr[nrow(tr), , drop = FALSE]
  scenario <- if ("scenario" %in% names(last)) as.character(last$scenario[[1]]) else NA_character_
  powertrain <- if (any(is.finite(tr$soc))) "bev" else "diesel"
  plan_violation <- nrow(ev) > 0 && any(ev$event_type == "PLAN_SOC_VIOLATION")
  completed <- nrow(ev) > 0 && any(ev$event_type == "ROUTE_COMPLETE")

  rows[[length(rows) + 1]] <- data.frame(
    run_id = run_id,
    pair_id = if (nrow(bsum) > 0 && "pair_id" %in% names(bsum)) as.character(bsum$pair_id[[1]]) else NA_character_,
    scenario = scenario,
    powertrain = powertrain,
    traffic_mode = if (nrow(bsum) > 0 && "traffic_mode" %in% names(bsum)) as.character(bsum$traffic_mode[[1]]) else NA_character_,
    status = if (plan_violation) "PLAN_SOC_VIOLATION" else if (completed) "OK" else "INCOMPLETE",
    co2_kg_total = as.numeric(last$co2_kg_cum[[1]]),
    propulsion_kwh_total = as.numeric(last$propulsion_kwh_cum[[1]]),
    tru_kwh_total = as.numeric(last$tru_kwh_cum[[1]]),
    diesel_gal_total = as.numeric(last$diesel_gal_cum[[1]]),
    tru_gal_total = as.numeric(last$tru_gal_cum[[1]]),
    delay_minutes_total = as.numeric(last$delay_minutes_cum[[1]]),
    detour_minutes_total = if ("detour_minutes_cum" %in% names(last)) as.numeric(last$detour_minutes_cum[[1]]) else NA_real_,
    od_cache_hit_count = if ("od_cache_hit_count" %in% names(last)) as.integer(last$od_cache_hit_count[[1]]) else NA_integer_,
    stop_count = as.integer(last$stop_count[[1]]),
    charge_count = as.integer(last$charge_count[[1]]),
    refuel_count = as.integer(last$refuel_count[[1]]),
    product_type = if (nrow(bsum) > 0 && "product_type" %in% names(bsum)) as.character(bsum$product_type[[1]]) else NA_character_,
    origin_network = if (nrow(bsum) > 0 && "origin_network" %in% names(bsum)) as.character(bsum$origin_network[[1]]) else NA_character_,
    route_id = if (nrow(bsum) > 0 && "route_id" %in% names(bsum)) as.character(bsum$route_id[[1]]) else NA_character_,
    kcal_delivered = if (nrow(bsum) > 0 && "kcal_delivered" %in% names(bsum)) as.numeric(bsum$kcal_delivered[[1]]) else NA_real_,
    mass_required_for_fu_kg = if (nrow(bsum) > 0 && "mass_required_for_fu_kg" %in% names(bsum)) as.numeric(bsum$mass_required_for_fu_kg[[1]]) else NA_real_,
    protein_kg_delivered = if (nrow(bsum) > 0 && "protein_kg_delivered" %in% names(bsum)) as.numeric(bsum$protein_kg_delivered[[1]]) else NA_real_,
    co2_per_1000kcal = if (nrow(bsum) > 0 && "co2_per_1000kcal" %in% names(bsum)) as.numeric(bsum$co2_per_1000kcal[[1]]) else NA_real_,
    co2_per_kg_protein = if (nrow(bsum) > 0 && "co2_per_kg_protein" %in% names(bsum)) as.numeric(bsum$co2_per_kg_protein[[1]]) else NA_real_,
    co2_g_per_g_protein = if (nrow(bsum) > 0 && "co2_g_per_g_protein" %in% names(bsum)) as.numeric(bsum$co2_g_per_g_protein[[1]]) else NA_real_,
    co2_kg_upstream = if (nrow(bsum) > 0 && "co2_kg_upstream" %in% names(bsum)) as.numeric(bsum$co2_kg_upstream[[1]]) else NA_real_,
    co2_kg_full = if (nrow(bsum) > 0 && "co2_kg_full" %in% names(bsum)) as.numeric(bsum$co2_kg_full[[1]]) else NA_real_,
    co2_full_per_1000kcal = if (nrow(bsum) > 0 && "co2_full_per_1000kcal" %in% names(bsum)) as.numeric(bsum$co2_full_per_1000kcal[[1]]) else NA_real_,
    co2_full_per_kg_protein = if (nrow(bsum) > 0 && "co2_full_per_kg_protein" %in% names(bsum)) as.numeric(bsum$co2_full_per_kg_protein[[1]]) else NA_real_,
    co2_full_g_per_g_protein = if (nrow(bsum) > 0 && "co2_full_g_per_g_protein" %in% names(bsum)) as.numeric(bsum$co2_full_g_per_g_protein[[1]]) else NA_real_,
    transport_cost_usd = if (nrow(bsum) > 0 && "transport_cost_usd" %in% names(bsum)) as.numeric(bsum$transport_cost_usd[[1]]) else if (nrow(bsum) > 0 && "transport_cost_total" %in% names(bsum)) as.numeric(bsum$transport_cost_total[[1]]) else NA_real_,
    transport_cost_total = if (nrow(bsum) > 0 && "transport_cost_total" %in% names(bsum)) as.numeric(bsum$transport_cost_total[[1]]) else if (nrow(bsum) > 0 && "transport_cost_usd" %in% names(bsum)) as.numeric(bsum$transport_cost_usd[[1]]) else NA_real_,
    transport_cost_per_1000kcal = if (nrow(bsum) > 0 && "transport_cost_per_1000kcal" %in% names(bsum)) as.numeric(bsum$transport_cost_per_1000kcal[[1]]) else NA_real_,
    transport_cost_per_kcal = if (nrow(bsum) > 0 && "transport_cost_per_kcal" %in% names(bsum)) as.numeric(bsum$transport_cost_per_kcal[[1]]) else NA_real_,
    transport_cost_per_kg_protein = if (nrow(bsum) > 0 && "transport_cost_per_kg_protein" %in% names(bsum)) as.numeric(bsum$transport_cost_per_kg_protein[[1]]) else NA_real_,
    delivered_price_per_kcal = if (nrow(bsum) > 0 && "delivered_price_per_kcal" %in% names(bsum)) as.numeric(bsum$delivered_price_per_kcal[[1]]) else NA_real_,
    price_index = if (nrow(bsum) > 0 && "price_index" %in% names(bsum)) as.numeric(bsum$price_index[[1]]) else NA_real_,
    price_index_vs_dry_baseline = if (nrow(bsum) > 0 && "price_index_vs_dry_baseline" %in% names(bsum)) as.numeric(bsum$price_index_vs_dry_baseline[[1]]) else NA_real_,
    protein_per_1000kcal = if (nrow(bsum) > 0 && "protein_per_1000kcal" %in% names(bsum)) as.numeric(bsum$protein_per_1000kcal[[1]]) else NA_real_,
    driving_time_h = if (nrow(bsum) > 0 && "driving_time_h" %in% names(bsum)) as.numeric(bsum$driving_time_h[[1]]) else NA_real_,
    traffic_delay_time_h = if (nrow(bsum) > 0 && "traffic_delay_time_h" %in% names(bsum)) as.numeric(bsum$traffic_delay_time_h[[1]]) else NA_real_,
    charging_or_refueling_time_h = if (nrow(bsum) > 0 && "charging_or_refueling_time_h" %in% names(bsum)) as.numeric(bsum$charging_or_refueling_time_h[[1]]) else NA_real_,
    rest_time_h = if (nrow(bsum) > 0 && "rest_time_h" %in% names(bsum)) as.numeric(bsum$rest_time_h[[1]]) else NA_real_,
    trip_duration_total_h = if (nrow(bsum) > 0 && "trip_duration_total_h" %in% names(bsum)) as.numeric(bsum$trip_duration_total_h[[1]]) else NA_real_,
    payload_max_lb_draw = if (nrow(bsum) > 0 && "payload_max_lb_draw" %in% names(bsum)) as.numeric(bsum$payload_max_lb_draw[[1]]) else NA_real_,
    units_per_truck = if (nrow(bsum) > 0 && "units_per_truck" %in% names(bsum)) as.numeric(bsum$units_per_truck[[1]]) else NA_real_,
    product_mass_lb_per_truck = if (nrow(bsum) > 0 && "product_mass_lb_per_truck" %in% names(bsum)) as.numeric(bsum$product_mass_lb_per_truck[[1]]) else NA_real_,
    kcal_per_truck = if (nrow(bsum) > 0 && "kcal_per_truck" %in% names(bsum)) as.numeric(bsum$kcal_per_truck[[1]]) else NA_real_,
    protein_kg_per_truck = if (nrow(bsum) > 0 && "protein_kg_per_truck" %in% names(bsum)) as.numeric(bsum$protein_kg_per_truck[[1]]) else NA_real_,
    delivery_time_min = if (nrow(bsum) > 0 && "delivery_time_min" %in% names(bsum)) as.numeric(bsum$delivery_time_min[[1]]) else NA_real_,
    driver_driving_min = if (nrow(bsum) > 0 && "driver_driving_min" %in% names(bsum)) as.numeric(bsum$driver_driving_min[[1]]) else NA_real_,
    driver_on_duty_min = if (nrow(bsum) > 0 && "driver_on_duty_min" %in% names(bsum)) as.numeric(bsum$driver_on_duty_min[[1]]) else NA_real_,
    driver_off_duty_min = if (nrow(bsum) > 0 && "driver_off_duty_min" %in% names(bsum)) as.numeric(bsum$driver_off_duty_min[[1]]) else NA_real_,
    time_charging_min = if (nrow(bsum) > 0 && "time_charging_min" %in% names(bsum)) as.numeric(bsum$time_charging_min[[1]]) else NA_real_,
    time_refuel_min = if (nrow(bsum) > 0 && "time_refuel_min" %in% names(bsum)) as.numeric(bsum$time_refuel_min[[1]]) else NA_real_,
    time_load_unload_min = if (nrow(bsum) > 0 && "time_load_unload_min" %in% names(bsum)) as.numeric(bsum$time_load_unload_min[[1]]) else NA_real_,
    time_traffic_delay_min = if (nrow(bsum) > 0 && "time_traffic_delay_min" %in% names(bsum)) as.numeric(bsum$time_traffic_delay_min[[1]]) else NA_real_,
    num_break_30min = if (nrow(bsum) > 0 && "num_break_30min" %in% names(bsum)) as.integer(bsum$num_break_30min[[1]]) else NA_integer_,
    num_rest_10hr = if (nrow(bsum) > 0 && "num_rest_10hr" %in% names(bsum)) as.integer(bsum$num_rest_10hr[[1]]) else NA_integer_,
    trucker_hours_per_1000kcal = if (nrow(bsum) > 0 && "trucker_hours_per_1000kcal" %in% names(bsum)) as.numeric(bsum$trucker_hours_per_1000kcal[[1]]) else NA_real_,
    stringsAsFactors = FALSE
  )
}

if (length(rows) == 0) stop("No non-empty simulation tracks found in ", opt$tracks_dir)
run_level <- do.call(rbind, rows)
utils::write.csv(run_level, file.path(opt$outdir, "route_sim_run_level.csv"), row.names = FALSE)

split_key <- paste(run_level$scenario, run_level$powertrain, run_level$traffic_mode, sep = "||")
groups <- split(run_level, split_key)
out <- lapply(groups, function(d) {
  ok <- d$status == "OK"
  x_ok <- d$co2_kg_total[ok]
  x_all <- d$co2_kg_total
  data.frame(
    scenario = d$scenario[[1]],
    powertrain = d$powertrain[[1]],
    traffic_mode = as.character(d$traffic_mode[[1]]),
    n_runs = nrow(d),
    n_ok = sum(ok, na.rm = TRUE),
    completion_rate = mean(ok, na.rm = TRUE),
    n_plan_soc_violation = sum(d$status == "PLAN_SOC_VIOLATION", na.rm = TRUE),
    p_plan_soc_violation = mean(d$status == "PLAN_SOC_VIOLATION", na.rm = TRUE),
    mean_co2_kg_all = mean(x_all, na.rm = TRUE),
    p05_co2_kg_all = as.numeric(stats::quantile(x_all, 0.05, na.rm = TRUE, names = FALSE)),
    p50_co2_kg_all = as.numeric(stats::quantile(x_all, 0.50, na.rm = TRUE, names = FALSE)),
    p95_co2_kg_all = as.numeric(stats::quantile(x_all, 0.95, na.rm = TRUE, names = FALSE)),
    mean_co2_kg_ok = if (length(x_ok) > 0) mean(x_ok, na.rm = TRUE) else NA_real_,
    p05_co2_kg_ok = if (length(x_ok) > 0) as.numeric(stats::quantile(x_ok, 0.05, na.rm = TRUE, names = FALSE)) else NA_real_,
    p50_co2_kg_ok = if (length(x_ok) > 0) as.numeric(stats::quantile(x_ok, 0.50, na.rm = TRUE, names = FALSE)) else NA_real_,
    p95_co2_kg_ok = if (length(x_ok) > 0) as.numeric(stats::quantile(x_ok, 0.95, na.rm = TRUE, names = FALSE)) else NA_real_,
    p05_co2_per_1000kcal = as.numeric(stats::quantile(d$co2_per_1000kcal, 0.05, na.rm = TRUE, names = FALSE)),
    p50_co2_per_1000kcal = as.numeric(stats::quantile(d$co2_per_1000kcal, 0.50, na.rm = TRUE, names = FALSE)),
    p95_co2_per_1000kcal = as.numeric(stats::quantile(d$co2_per_1000kcal, 0.95, na.rm = TRUE, names = FALSE)),
    p05_co2_per_kg_protein = as.numeric(stats::quantile(d$co2_per_kg_protein, 0.05, na.rm = TRUE, names = FALSE)),
    p50_co2_per_kg_protein = as.numeric(stats::quantile(d$co2_per_kg_protein, 0.50, na.rm = TRUE, names = FALSE)),
    p95_co2_per_kg_protein = as.numeric(stats::quantile(d$co2_per_kg_protein, 0.95, na.rm = TRUE, names = FALSE)),
    p05_co2_kg_upstream = as.numeric(stats::quantile(d$co2_kg_upstream, 0.05, na.rm = TRUE, names = FALSE)),
    p50_co2_kg_upstream = as.numeric(stats::quantile(d$co2_kg_upstream, 0.50, na.rm = TRUE, names = FALSE)),
    p95_co2_kg_upstream = as.numeric(stats::quantile(d$co2_kg_upstream, 0.95, na.rm = TRUE, names = FALSE)),
    p05_co2_kg_full = as.numeric(stats::quantile(d$co2_kg_full, 0.05, na.rm = TRUE, names = FALSE)),
    p50_co2_kg_full = as.numeric(stats::quantile(d$co2_kg_full, 0.50, na.rm = TRUE, names = FALSE)),
    p95_co2_kg_full = as.numeric(stats::quantile(d$co2_kg_full, 0.95, na.rm = TRUE, names = FALSE)),
    p05_co2_full_per_1000kcal = as.numeric(stats::quantile(d$co2_full_per_1000kcal, 0.05, na.rm = TRUE, names = FALSE)),
    p50_co2_full_per_1000kcal = as.numeric(stats::quantile(d$co2_full_per_1000kcal, 0.50, na.rm = TRUE, names = FALSE)),
    p95_co2_full_per_1000kcal = as.numeric(stats::quantile(d$co2_full_per_1000kcal, 0.95, na.rm = TRUE, names = FALSE)),
    p05_co2_full_per_kg_protein = as.numeric(stats::quantile(d$co2_full_per_kg_protein, 0.05, na.rm = TRUE, names = FALSE)),
    p50_co2_full_per_kg_protein = as.numeric(stats::quantile(d$co2_full_per_kg_protein, 0.50, na.rm = TRUE, names = FALSE)),
    p95_co2_full_per_kg_protein = as.numeric(stats::quantile(d$co2_full_per_kg_protein, 0.95, na.rm = TRUE, names = FALSE)),
    p50_co2_g_per_g_protein = as.numeric(stats::quantile(d$co2_g_per_g_protein, 0.50, na.rm = TRUE, names = FALSE)),
    p50_co2_full_g_per_g_protein = as.numeric(stats::quantile(d$co2_full_g_per_g_protein, 0.50, na.rm = TRUE, names = FALSE)),
    p05_delivery_time_min = as.numeric(stats::quantile(d$delivery_time_min, 0.05, na.rm = TRUE, names = FALSE)),
    p50_delivery_time_min = as.numeric(stats::quantile(d$delivery_time_min, 0.50, na.rm = TRUE, names = FALSE)),
    p95_delivery_time_min = as.numeric(stats::quantile(d$delivery_time_min, 0.95, na.rm = TRUE, names = FALSE)),
    p05_driver_driving_min = as.numeric(stats::quantile(d$driver_driving_min, 0.05, na.rm = TRUE, names = FALSE)),
    p50_driver_driving_min = as.numeric(stats::quantile(d$driver_driving_min, 0.50, na.rm = TRUE, names = FALSE)),
    p95_driver_driving_min = as.numeric(stats::quantile(d$driver_driving_min, 0.95, na.rm = TRUE, names = FALSE)),
    p05_driver_on_duty_min = as.numeric(stats::quantile(d$driver_on_duty_min, 0.05, na.rm = TRUE, names = FALSE)),
    p50_driver_on_duty_min = as.numeric(stats::quantile(d$driver_on_duty_min, 0.50, na.rm = TRUE, names = FALSE)),
    p95_driver_on_duty_min = as.numeric(stats::quantile(d$driver_on_duty_min, 0.95, na.rm = TRUE, names = FALSE)),
    p05_driver_off_duty_min = as.numeric(stats::quantile(d$driver_off_duty_min, 0.05, na.rm = TRUE, names = FALSE)),
    p50_driver_off_duty_min = as.numeric(stats::quantile(d$driver_off_duty_min, 0.50, na.rm = TRUE, names = FALSE)),
    p95_driver_off_duty_min = as.numeric(stats::quantile(d$driver_off_duty_min, 0.95, na.rm = TRUE, names = FALSE)),
    p50_time_charging_min = as.numeric(stats::quantile(d$time_charging_min, 0.50, na.rm = TRUE, names = FALSE)),
    p50_time_refuel_min = as.numeric(stats::quantile(d$time_refuel_min, 0.50, na.rm = TRUE, names = FALSE)),
    p50_time_load_unload_min = as.numeric(stats::quantile(d$time_load_unload_min, 0.50, na.rm = TRUE, names = FALSE)),
    p50_time_traffic_delay_min = as.numeric(stats::quantile(d$time_traffic_delay_min, 0.50, na.rm = TRUE, names = FALSE)),
    p50_trucker_hours_per_1000kcal = as.numeric(stats::quantile(d$trucker_hours_per_1000kcal, 0.50, na.rm = TRUE, names = FALSE)),
    p50_trip_duration_total_h = as.numeric(stats::quantile(d$trip_duration_total_h, 0.50, na.rm = TRUE, names = FALSE)),
    p95_trip_duration_total_h = as.numeric(stats::quantile(d$trip_duration_total_h, 0.95, na.rm = TRUE, names = FALSE)),
    p50_transport_cost_per_1000kcal = as.numeric(stats::quantile(d$transport_cost_per_1000kcal, 0.50, na.rm = TRUE, names = FALSE)),
    p50_transport_cost_per_kg_protein = as.numeric(stats::quantile(d$transport_cost_per_kg_protein, 0.50, na.rm = TRUE, names = FALSE)),
    p50_delivered_price_per_kcal = as.numeric(stats::quantile(d$delivered_price_per_kcal, 0.50, na.rm = TRUE, names = FALSE)),
    p50_price_index = as.numeric(stats::quantile(d$price_index, 0.50, na.rm = TRUE, names = FALSE)),
    stringsAsFactors = FALSE
  )
})
summary_df <- do.call(rbind, out)
utils::write.csv(summary_df, file.path(opt$outdir, "route_sim_summary_stats.csv"), row.names = FALSE)

make_traffic_penalty <- function(run_level) {
  req <- c("pair_id", "scenario", "powertrain", "traffic_mode", "co2_kg_total")
  if (!all(req %in% names(run_level))) return(data.frame())
  d <- run_level[run_level$status != "PLAN_SOC_VIOLATION" & is.finite(run_level$co2_kg_total), , drop = FALSE]
  if (nrow(d) == 0) return(data.frame())
  d$traffic_mode <- tolower(as.character(d$traffic_mode))
  d <- d[d$traffic_mode %in% c("stochastic", "freeflow"), , drop = FALSE]
  if (nrow(d) == 0) return(data.frame())
  keys <- split(d, list(d$pair_id, d$scenario, d$powertrain), drop = TRUE)
  rows <- lapply(keys, function(x) {
    if (all(is.na(x$pair_id))) return(NULL)
    c_stoch <- x$co2_kg_total[x$traffic_mode == "stochastic"]
    c_free <- x$co2_kg_total[x$traffic_mode == "freeflow"]
    if (length(c_stoch) == 0 || length(c_free) == 0) return(NULL)
    st <- as.numeric(stats::median(c_stoch, na.rm = TRUE))
    fr <- as.numeric(stats::median(c_free, na.rm = TRUE))
    data.frame(
      pair_id = as.character(x$pair_id[[1]]),
      scenario = as.character(x$scenario[[1]]),
      powertrain = as.character(x$powertrain[[1]]),
      co2_stochastic_kg = st,
      co2_freeflow_kg = fr,
      traffic_emissions_penalty_kg = st - fr,
      traffic_emissions_penalty_pct = if (is.finite(fr) && fr != 0) 100 * (st - fr) / fr else NA_real_,
      stringsAsFactors = FALSE
    )
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

tep_df <- make_traffic_penalty(run_level)
if (nrow(tep_df) > 0) {
  utils::write.csv(tep_df, file.path(opt$outdir, "route_sim_traffic_penalty.csv"), row.names = FALSE)
  cat("Wrote", file.path(opt$outdir, "route_sim_traffic_penalty.csv"), "\n")

  tep_groups <- split(tep_df, list(tep_df$scenario, tep_df$powertrain), drop = TRUE)
  tep_summary <- do.call(rbind, lapply(tep_groups, function(d) {
    x <- as.numeric(d$traffic_emissions_penalty_kg)
    data.frame(
      scenario = as.character(d$scenario[[1]]),
      powertrain = as.character(d$powertrain[[1]]),
      n_pairs = nrow(d),
      mean_traffic_emissions_penalty_kg = mean(x, na.rm = TRUE),
      p05_traffic_emissions_penalty_kg = as.numeric(stats::quantile(x, 0.05, na.rm = TRUE, names = FALSE)),
      p50_traffic_emissions_penalty_kg = as.numeric(stats::quantile(x, 0.50, na.rm = TRUE, names = FALSE)),
      p95_traffic_emissions_penalty_kg = as.numeric(stats::quantile(x, 0.95, na.rm = TRUE, names = FALSE)),
      p_traffic_emissions_penalty_gt_0 = mean(x > 0, na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  }))
  utils::write.csv(tep_summary, file.path(opt$outdir, "route_sim_traffic_penalty_summary.csv"), row.names = FALSE)
  cat("Wrote", file.path(opt$outdir, "route_sim_traffic_penalty_summary.csv"), "\n")
}

make_prob_ev_slower <- function(run_level) {
  req <- c("pair_id", "scenario", "trip_duration_total_h", "powertrain")
  if (!all(req %in% names(run_level))) return(data.frame())
  d <- run_level[is.finite(run_level$trip_duration_total_h), , drop = FALSE]
  if (nrow(d) == 0) return(data.frame())
  keys <- split(d, list(d$pair_id, d$scenario), drop = TRUE)
  rows <- lapply(keys, function(x) {
    e <- x$trip_duration_total_h[tolower(x$powertrain) == "bev"]
    z <- x$trip_duration_total_h[tolower(x$powertrain) == "diesel"]
    if (length(e) == 0 || length(z) == 0) return(NULL)
    n <- min(length(e), length(z))
    data.frame(
      pair_id = as.character(x$pair_id[[1]]),
      scenario = as.character(x$scenario[[1]]),
      ev_slower_than_diesel = mean(e[seq_len(n)] > z[seq_len(n)], na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

make_prob_refrigerated_gt_dry <- function(run_level) {
  req <- c("pair_id", "scenario", "co2_kg_total", "product_type")
  if (!all(req %in% names(run_level))) return(data.frame())
  d <- run_level[is.finite(run_level$co2_kg_total), , drop = FALSE]
  if (nrow(d) == 0) return(data.frame())
  keys <- split(d, list(d$pair_id, d$scenario), drop = TRUE)
  rows <- lapply(keys, function(x) {
    r <- x$co2_kg_total[tolower(x$product_type) == "refrigerated"]
    z <- x$co2_kg_total[tolower(x$product_type) == "dry"]
    if (length(r) == 0 || length(z) == 0) return(NULL)
    n <- min(length(r), length(z))
    data.frame(
      pair_id = as.character(x$pair_id[[1]]),
      scenario = as.character(x$scenario[[1]]),
      p_refrigerated_gt_dry = mean(r[seq_len(n)] > z[seq_len(n)], na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

ev_slow_df <- make_prob_ev_slower(run_level)
if (nrow(ev_slow_df) > 0) {
  utils::write.csv(ev_slow_df, file.path(opt$outdir, "route_sim_prob_ev_slower_than_diesel.csv"), row.names = FALSE)
  cat("Wrote", file.path(opt$outdir, "route_sim_prob_ev_slower_than_diesel.csv"), "\n")
}

ref_gt_dry_df <- make_prob_refrigerated_gt_dry(run_level)
if (nrow(ref_gt_dry_df) > 0) {
  utils::write.csv(ref_gt_dry_df, file.path(opt$outdir, "route_sim_prob_refrigerated_gt_dry.csv"), row.names = FALSE)
  cat("Wrote", file.path(opt$outdir, "route_sim_prob_refrigerated_gt_dry.csv"), "\n")
}

make_upstream_ingredient_summary <- function(run_level, bundle_dir) {
  rows <- list()
  for (i in seq_len(nrow(run_level))) {
    rid <- as.character(run_level$run_id[[i]])
    p <- file.path(bundle_dir, rid, "upstream_ingredients.csv")
    if (!file.exists(p) || !isTRUE(file.info(p)$size > 0)) next
    d <- tryCatch(utils::read.csv(p, stringsAsFactors = FALSE), error = function(e) data.frame())
    if (nrow(d) == 0) next
    d$scenario <- run_level$scenario[[i]]
    d$powertrain <- run_level$powertrain[[i]]
    d$traffic_mode <- run_level$traffic_mode[[i]]
    rows[[length(rows) + 1L]] <- d
  }
  if (length(rows) == 0) return(data.frame())
  all <- do.call(rbind, rows)
  keys <- split(all, list(all$scenario, all$powertrain, all$product_type, all$ingredient_raw), drop = TRUE)
  out <- lapply(keys, function(x) {
    data.frame(
      scenario = as.character(x$scenario[[1]]),
      powertrain = as.character(x$powertrain[[1]]),
      product_type = as.character(x$product_type[[1]]),
      ingredient_raw = as.character(x$ingredient_raw[[1]]),
      lci_key = as.character(x$lci_key[[1]]),
      p05_upstream_kgco2_per_1000kcal = as.numeric(stats::quantile(x$upstream_kgco2_per_1000kcal, 0.05, na.rm = TRUE, names = FALSE)),
      p50_upstream_kgco2_per_1000kcal = as.numeric(stats::quantile(x$upstream_kgco2_per_1000kcal, 0.50, na.rm = TRUE, names = FALSE)),
      p95_upstream_kgco2_per_1000kcal = as.numeric(stats::quantile(x$upstream_kgco2_per_1000kcal, 0.95, na.rm = TRUE, names = FALSE)),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, out)
}

upstream_df <- make_upstream_ingredient_summary(run_level, opt$bundle_dir)
if (nrow(upstream_df) > 0) {
  utils::write.csv(upstream_df, file.path(opt$outdir, "upstream_ingredients_summary.csv"), row.names = FALSE)
  cat("Wrote", file.path(opt$outdir, "upstream_ingredients_summary.csv"), "\n")
}

make_geo_protein_gsi <- function(run_level) {
  req <- c("pair_id", "route_id", "powertrain", "scenario", "traffic_mode", "product_type", "origin_network", "co2_per_kg_protein")
  if (!all(req %in% names(run_level))) return(data.frame())
  d <- run_level[is.finite(run_level$co2_per_kg_protein), , drop = FALSE]
  if (nrow(d) == 0) return(data.frame())
  keys <- split(d, list(d$pair_id, d$route_id, d$powertrain, d$scenario, d$traffic_mode, d$product_type), drop = TRUE)
  rows <- lapply(keys, function(x) {
    if (all(is.na(x$pair_id))) return(NULL)
    a <- x$co2_per_kg_protein[tolower(x$origin_network) == "refrigerated_factory_set"]
    b <- x$co2_per_kg_protein[tolower(x$origin_network) == "dry_factory_set"]
    if (length(a) == 0 || length(b) == 0) return(NULL)
    delta <- as.numeric(stats::median(a, na.rm = TRUE) - stats::median(b, na.rm = TRUE))
    data.frame(
      pair_id = as.character(x$pair_id[[1]]),
      route_id = as.character(x$route_id[[1]]),
      powertrain = as.character(x$powertrain[[1]]),
      scenario = as.character(x$scenario[[1]]),
      traffic_mode = as.character(x$traffic_mode[[1]]),
      product_type = as.character(x$product_type[[1]]),
      gsi_delta_co2_per_kg_protein = delta,
      stringsAsFactors = FALSE
    )
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

gsi_df <- make_geo_protein_gsi(run_level)
if (nrow(gsi_df) > 0) {
  utils::write.csv(gsi_df, file.path(opt$outdir, "route_sim_geo_sensitivity_protein.csv"), row.names = FALSE)
  cat("Wrote", file.path(opt$outdir, "route_sim_geo_sensitivity_protein.csv"), "\n")

  gsi_groups <- split(gsi_df, list(gsi_df$route_id, gsi_df$powertrain, gsi_df$scenario, gsi_df$traffic_mode, gsi_df$product_type), drop = TRUE)
  gsi_summary <- do.call(rbind, lapply(gsi_groups, function(d) {
    x <- as.numeric(d$gsi_delta_co2_per_kg_protein)
    data.frame(
      route_id = as.character(d$route_id[[1]]),
      powertrain = as.character(d$powertrain[[1]]),
      scenario = as.character(d$scenario[[1]]),
      traffic_mode = as.character(d$traffic_mode[[1]]),
      product_type = as.character(d$product_type[[1]]),
      n_pairs = nrow(d),
      gsi_co2_per_kg_protein_p05 = as.numeric(stats::quantile(x, 0.05, na.rm = TRUE, names = FALSE)),
      gsi_co2_per_kg_protein_p50 = as.numeric(stats::quantile(x, 0.50, na.rm = TRUE, names = FALSE)),
      gsi_co2_per_kg_protein_p95 = as.numeric(stats::quantile(x, 0.95, na.rm = TRUE, names = FALSE)),
      p_gsi_gt_0 = mean(x > 0, na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  }))
  utils::write.csv(gsi_summary, file.path(opt$outdir, "route_sim_geo_sensitivity_protein_summary.csv"), row.names = FALSE)
  cat("Wrote", file.path(opt$outdir, "route_sim_geo_sensitivity_protein_summary.csv"), "\n")
}

cat("Wrote", file.path(opt$outdir, "route_sim_run_level.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "route_sim_summary_stats.csv"), "\n")
