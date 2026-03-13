#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--phase_root"), type = "character", default = "outputs/distribution/crossed_factory_transport/phase2"),
  make_option(c("--outdir"), type = "character", default = "outputs/distribution/crossed_factory_transport"),
  make_option(c("--validation_label"), type = "character", default = "crossed_factory_transport"),
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
strict <- parse_bool(opt$strict, TRUE)

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

bundle_summary_paths <- list.files(opt$phase_root, pattern = "^summaries\\.csv$", recursive = TRUE, full.names = TRUE)
summary_paths <- if (length(bundle_summary_paths) > 0) {
  bundle_summary_paths
} else {
  list.files(opt$phase_root, pattern = "^route_sim_summary\\.csv$", recursive = TRUE, full.names = TRUE)
}
if (length(summary_paths) == 0) stop("No summary csv files found under ", opt$phase_root)

extract_seed <- function(x) {
  vals <- as.character(x)
  m <- regexec("seed_([0-9]+)", vals)
  reg <- regmatches(vals, m)
  out <- vapply(seq_along(reg), function(i) {
    r <- reg[[i]]
    if (length(r) >= 2) return(suppressWarnings(as.integer(r[[2]])))
    nums <- regmatches(vals[[i]], gregexpr("[0-9]+", vals[[i]]))[[1]]
    if (length(nums) == 0) return(NA_integer_)
    suppressWarnings(as.integer(utils::tail(nums, 1)))
  }, integer(1))
  out
}

normalize_factory <- function(origin_network, facility_id = NA_character_) {
  src <- tolower(trimws(paste(origin_network %||% "", facility_id %||% "")))
  if (grepl("kansas|topeka|hills|dry_factory_set", src)) return("kansas")
  if (grepl("texas|ennis|freshpet|refrigerated_factory_set", src)) return("texas")
  NA_character_
}

factory_label <- function(factory) {
  ifelse(factory == "kansas", "Hill's Topeka, KS", ifelse(factory == "texas", "Freshpet Ennis, TX", NA_character_))
}

infer_powertrain <- function(...) {
  vals <- unlist(list(...), use.names = FALSE)
  vals <- tolower(trimws(as.character(vals)))
  vals <- vals[nzchar(vals) & !is.na(vals)]
  if (length(vals) == 0) return(NA_character_)
  hit <- vals[grepl("bev|diesel", vals)]
  if (length(hit) == 0) return(NA_character_)
  if (any(grepl("bev", hit))) return("bev")
  if (any(grepl("diesel", hit))) return("diesel")
  NA_character_
}

extract_chunk_id <- function(...) {
  vals <- unlist(list(...), use.names = FALSE)
  vals <- as.character(vals)
  out <- vapply(vals, function(x) {
    mm <- regexec("(phase1|chunk_[0-9]+)", x)
    rr <- regmatches(x, mm)[[1]]
    if (length(rr) >= 2) return(rr[[2]])
    NA_character_
  }, character(1))
  idx <- which(!is.na(out) & nzchar(out))
  if (length(idx) == 0) return(NA_character_)
  out[[idx[[1]]]]
}

quant <- function(x, p) as.numeric(stats::quantile(x, p, na.rm = TRUE, names = FALSE, type = 7))

rows <- lapply(summary_paths, function(sp) {
  s <- data.table::fread(sp, showProgress = FALSE)
  if ("run_id" %in% names(s)) {
    s[, source_dir := dirname(sp)]
    return(s)
  }

  rp <- file.path(dirname(sp), "route_sim_runs.csv")
  if (!file.exists(rp)) stop("Missing route_sim_runs.csv for aggregated summary file ", sp)
  r <- data.table::fread(rp, showProgress = FALSE)
  if (!"run_id" %in% names(r)) stop("route_sim_runs.csv must include run_id: ", dirname(sp))
  stop("Summary file lacks run_id and cannot be used for crossed aggregation: ", sp)
})

d <- data.table::rbindlist(rows, fill = TRUE, use.names = TRUE)
if (nrow(d) == 0) stop("No rows loaded from ", opt$phase_root)

for (cn in c(
  "product_type", "origin_network", "facility_id", "powertrain", "reefer_state", "pair_id", "scenario_id", "scenario",
  "route_id", "status", "route_completed", "cold_chain_required", "distance_miles", "trip_duration_total_h", "congestion_delay_hours",
  "diesel_gal_propulsion", "diesel_gal_tru", "energy_kwh_propulsion", "energy_kwh_tru", "co2_kg_total",
  "product_mass_lb_per_truck", "kcal_delivered", "payload_lb", "charge_stops", "truckloads_per_1000kg_product",
  "trucker_hours_per_1000kcal", "charging_or_refueling_time_h", "driving_time_h", "traffic_delay_time_h"
)) {
  if (!cn %in% names(d)) d[, (cn) := NA]
}

d[, product_load := tolower(trimws(as.character(product_type)))]
d[, powertrain := tolower(trimws(as.character(powertrain)))]
d[(is.na(powertrain) | !nzchar(powertrain)), powertrain := vapply(
  seq_len(.N),
  function(i) infer_powertrain(run_id[[i]], pair_id[[i]], source_dir[[i]], scenario_id[[i]], scenario[[i]]),
  character(1)
)]
d[, factory := vapply(seq_len(.N), function(i) normalize_factory(origin_network[[i]], facility_id[[i]]), character(1))]
d[, factory_label := factory_label(factory)]
d[, reefer_state := {
  rr <- tolower(trimws(as.character(reefer_state)))
  cc <- as.logical(cold_chain_required)
  ifelse(rr %in% c("on", "off"), rr, ifelse(is.na(cc), NA_character_, ifelse(cc, "on", "off")))
}]
d[, shared_seed := extract_seed(pair_id)]
d[is.na(shared_seed), shared_seed := extract_seed(run_id)]
d[, replicate_id := data.table::frank(shared_seed, ties.method = "dense", na.last = "keep")]
d[, chunk_id := vapply(seq_len(.N), function(i) extract_chunk_id(source_dir[[i]], run_id[[i]], scenario_id[[i]]), character(1))]
d[, destination_name := "Petco Davis, CA"]
d[, trip_distance_miles := suppressWarnings(as.numeric(distance_miles))]
d[, trip_duration_hours := suppressWarnings(as.numeric(trip_duration_total_h))]
d[, refrigeration_runtime_hours := data.table::fifelse(
  reefer_state == "on",
  pmax(
    0,
    suppressWarnings(as.numeric(driving_time_h)) +
      suppressWarnings(as.numeric(traffic_delay_time_h)) +
      suppressWarnings(as.numeric(charging_or_refueling_time_h))
  ),
  0
)]
d[, diesel_gallons := suppressWarnings(as.numeric(diesel_gal_propulsion)) + suppressWarnings(as.numeric(diesel_gal_tru))]
d[, traction_electricity_kwh := suppressWarnings(as.numeric(energy_kwh_propulsion))]
d[, charging_stops := suppressWarnings(as.integer(charge_stops))]
d[, charging_time_hours := data.table::fifelse(
  powertrain == "bev",
  suppressWarnings(as.numeric(charging_or_refueling_time_h)),
  0
)]
d[, route_completed := as.logical(route_completed %||% FALSE)]
d[, total_trip_co2_kg := suppressWarnings(as.numeric(co2_kg_total))]
d[, payload_kg_delivered := suppressWarnings(as.numeric(product_mass_lb_per_truck)) * 0.45359237]
d[!is.finite(payload_kg_delivered) | payload_kg_delivered <= 0, payload_kg_delivered := suppressWarnings(as.numeric(payload_lb)) * 0.45359237]
d[, total_kcal_delivered := suppressWarnings(as.numeric(kcal_delivered))]
d[, layer_type := "controlled_crossed"]
d[, co2_per_1000kcal := data.table::fifelse(
  is.finite(total_trip_co2_kg) & is.finite(total_kcal_delivered) & total_kcal_delivered > 0,
  total_trip_co2_kg / total_kcal_delivered * 1000,
  NA_real_
)]
d[, scenario_cell := paste(factory, powertrain, reefer_state, product_load, sep = "__")]
d[, scenario_name := scenario_cell]

required_levels <- list(
  factory = c("kansas", "texas"),
  powertrain = c("diesel", "bev"),
  reefer_state = c("off", "on"),
  product_load = c("dry", "refrigerated")
)

fails <- character()
fail_row <- function(msg) fails <<- c(fails, msg)

ok <- d[
  factory %in% required_levels$factory &
    powertrain %in% required_levels$powertrain &
    reefer_state %in% required_levels$reefer_state &
    product_load %in% required_levels$product_load &
    is.finite(shared_seed)
]

expected <- data.table::as.data.table(expand.grid(required_levels, stringsAsFactors = FALSE))
present <- unique(ok[, .(factory, powertrain, reefer_state, product_load)])
missing <- expected[!present, on = c("factory", "powertrain", "reefer_state", "product_load")]
if (nrow(missing) > 0) {
  fail_row(paste0(
    "missing crossed scenario combinations: ",
    paste(apply(missing, 1, paste, collapse = "/"), collapse = "; ")
  ))
}

for (fac in required_levels$factory) {
  sub <- unique(ok[factory == fac, .(powertrain, reefer_state, product_load)])
  if (!all(required_levels$powertrain %in% sub$powertrain)) fail_row(paste0("factory=", fac, " missing one or more powertrain levels"))
  if (!all(required_levels$reefer_state %in% sub$reefer_state)) fail_row(paste0("factory=", fac, " missing one or more reefer_state levels"))
  if (!all(required_levels$product_load %in% sub$product_load)) fail_row(paste0("factory=", fac, " missing one or more product_load levels"))
}
for (pt in required_levels$powertrain) {
  sub <- unique(ok[powertrain == pt, .(factory, reefer_state, product_load)])
  if (!all(required_levels$factory %in% sub$factory)) fail_row(paste0("powertrain=", pt, " missing one or more factory levels"))
}

validation_path <- file.path(opt$outdir, "crossed_factory_transport_validation_report.txt")
if (length(fails) > 0 && strict) {
  writeLines(c(
    paste0("VALIDATION: FAIL (", opt$validation_label, ")"),
    unique(fails)
  ), con = validation_path)
  stop(paste(unique(fails), collapse = " | "))
}

rows_out <- ok[, .(
  run_id,
  layer_type,
  replicate_id,
  chunk_id,
  shared_seed,
  scenario_cell,
  scenario_name,
  factory,
  factory_label,
  powertrain,
  reefer_state,
  product_load,
  origin_network,
  facility_id,
  destination_name,
  route_id,
  status,
  route_completed,
  trip_distance_miles,
  trip_duration_hours,
  congestion_delay_hours,
  refrigeration_runtime_hours,
  diesel_gallons,
  traction_electricity_kwh,
  charging_stops,
  charging_time_hours,
  total_trip_co2_kg,
  payload_kg_delivered,
  total_kcal_delivered,
  co2_per_1000kcal,
  truckloads_per_1000kg_product,
  trucker_hours_per_1000kcal,
  source_dir
)]
data.table::setorder(rows_out, replicate_id, factory, powertrain, reefer_state, product_load)

metrics <- c(
  "co2_per_1000kcal",
  "total_trip_co2_kg",
  "trip_distance_miles",
  "trip_duration_hours",
  "congestion_delay_hours",
  "refrigeration_runtime_hours",
  "diesel_gallons",
  "traction_electricity_kwh",
  "payload_kg_delivered",
  "truckloads_per_1000kg_product",
  "trucker_hours_per_1000kcal"
)

summary_parts <- lapply(metrics, function(metric) {
  rows_out[, {
    x <- suppressWarnings(as.numeric(get(metric)))
    .(
      metric = metric,
      n = sum(is.finite(x)),
      mean = mean(x, na.rm = TRUE),
      median = stats::median(x, na.rm = TRUE),
      p05 = quant(x, 0.05),
      p50 = quant(x, 0.50),
      p95 = quant(x, 0.95)
    )
  }, by = .(scenario_cell, factory, factory_label, powertrain, reefer_state, product_load)]
})
summary_out <- data.table::rbindlist(summary_parts, use.names = TRUE, fill = TRUE)
summary_out[, layer_type := "controlled_crossed"]
data.table::setorder(summary_out, scenario_cell, metric)

make_effect_decomp <- function(data, effect_name, level_a, level_b, hold_cols, vary_col) {
  keep <- data[get(vary_col) %in% c(level_a, level_b)]
  if (nrow(keep) == 0) return(data.table::data.table())
  out <- lapply(metrics, function(metric) {
    wide <- data.table::dcast(
      keep,
      as.formula(paste(paste(c("shared_seed", hold_cols), collapse = " + "), "~", vary_col)),
      value.var = metric
    )
    if (!(level_a %in% names(wide) && level_b %in% names(wide))) return(NULL)
    wide[, delta := suppressWarnings(as.numeric(get(level_a)) - as.numeric(get(level_b)))]
    wide <- wide[is.finite(delta)]
    if (nrow(wide) == 0) return(NULL)
    wide[, .(
      effect = effect_name,
      comparison = paste0(level_a, "_minus_", level_b),
      metric = metric,
      n_pairs = .N,
      mean_delta = mean(delta, na.rm = TRUE),
      median_delta = stats::median(delta, na.rm = TRUE),
      p05_delta = quant(delta, 0.05),
      p50_delta = quant(delta, 0.50),
      p95_delta = quant(delta, 0.95)
    ), by = hold_cols]
  })
  out <- Filter(Negate(is.null), out)
  if (length(out) == 0) return(data.table::data.table())
  data.table::rbindlist(out, fill = TRUE, use.names = TRUE)
}

effect_out <- data.table::rbindlist(list(
  make_effect_decomp(rows_out, "factory", "kansas", "texas", c("powertrain", "reefer_state", "product_load"), "factory"),
  make_effect_decomp(rows_out, "powertrain", "diesel", "bev", c("factory", "reefer_state", "product_load"), "powertrain"),
  make_effect_decomp(rows_out, "reefer_state", "off", "on", c("factory", "powertrain", "product_load"), "reefer_state"),
  make_effect_decomp(rows_out, "product_load", "dry", "refrigerated", c("factory", "powertrain", "reefer_state"), "product_load")
), fill = TRUE, use.names = TRUE)
effect_out[, layer_type := "controlled_crossed"]

realistic <- rows_out[
  (factory == "kansas" & product_load == "dry" & reefer_state == "off") |
    (factory == "texas" & product_load == "refrigerated" & reefer_state == "on")
]
realistic[, layer_type := "realistic_lca"]
realistic[, scenario_name := ifelse(
  factory == "kansas",
  paste0("dry_", powertrain),
  paste0("refrigerated_", powertrain)
)]
data.table::setorder(realistic, replicate_id, scenario_name)

pair_summ <- data.table::dcast(realistic, replicate_id + shared_seed ~ scenario_name, value.var = "co2_per_1000kcal")
if (all(c("refrigerated_diesel", "dry_diesel") %in% names(pair_summ))) {
  pair_summ[, delta_diesel_co2_per_1000kcal := refrigerated_diesel - dry_diesel]
}
if (all(c("refrigerated_bev", "dry_bev") %in% names(pair_summ))) {
  pair_summ[, delta_bev_co2_per_1000kcal := refrigerated_bev - dry_bev]
}

power_summ <- realistic[, .(
  n = .N,
  mean = mean(co2_per_1000kcal, na.rm = TRUE),
  median = stats::median(co2_per_1000kcal, na.rm = TRUE),
  p05 = quant(co2_per_1000kcal, 0.05),
  p50 = quant(co2_per_1000kcal, 0.50),
  p95 = quant(co2_per_1000kcal, 0.95)
), by = .(scenario_name, powertrain)]

graphics_inputs <- power_summ[, .(
  scenario_name,
  mean_co2_per_1000kcal = mean,
  p05_co2_per_1000kcal = p05,
  p95_co2_per_1000kcal = p95
)]

data.table::fwrite(rows_out, file.path(opt$outdir, "crossed_factory_transport_scenarios.csv"))
data.table::fwrite(summary_out, file.path(opt$outdir, "crossed_factory_transport_summary.csv"))
data.table::fwrite(effect_out, file.path(opt$outdir, "transport_effect_decomposition.csv"))
data.table::fwrite(realistic, file.path(opt$outdir, "transport_sim_rows.csv"))
data.table::fwrite(pair_summ, file.path(opt$outdir, "transport_sim_paired_summary.csv"))
data.table::fwrite(power_summ, file.path(opt$outdir, "transport_sim_powertrain_summary.csv"))
data.table::fwrite(graphics_inputs, file.path(opt$outdir, "transport_sim_graphics_inputs.csv"))

if (length(fails) == 0) {
  writeLines(c(
    paste0("VALIDATION: PASS (", opt$validation_label, ")"),
    paste0("controlled_rows=", nrow(rows_out)),
    paste0("realistic_rows=", nrow(realistic)),
    paste0("scenario_cells=", data.table::uniqueN(rows_out$scenario_cell))
  ), con = validation_path)
} else {
  writeLines(c(
    paste0("VALIDATION: WARN (", opt$validation_label, ")"),
    unique(fails)
  ), con = validation_path)
}

cat("Wrote outputs under ", opt$outdir, "\n", sep = "")
