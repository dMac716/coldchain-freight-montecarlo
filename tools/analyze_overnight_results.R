#!/usr/bin/env Rscript

Sys.setenv(
  OMP_NUM_THREADS = "1",
  OPENBLAS_NUM_THREADS = "1",
  MKL_NUM_THREADS = "1",
  VECLIB_MAXIMUM_THREADS = "1",
  NUMEXPR_NUM_THREADS = "1"
)

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")
data.table::setDTthreads(1L)

option_list <- list(
  make_option(c("--runs_csv"), type = "character", default = "", help = "Merged runs CSV (required)"),
  make_option(c("--validation_roots"), type = "character", default = "", help = "Comma-separated validation roots; each may contain end_to_end_* folders"),
  make_option(c("--outdir"), type = "character", default = "outputs/analysis/overnight")
)
opt <- parse_args(OptionParser(option_list = option_list))

parse_csv_tokens <- function(x) {
  raw <- as.character(x %||% "")
  if (!nzchar(raw)) return(character())
  parts <- trimws(unlist(strsplit(raw, ",")))
  parts[nzchar(parts)]
}
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

if (!nzchar(opt$runs_csv) || !file.exists(opt$runs_csv)) {
  stop("--runs_csv is required and must exist")
}
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

runs <- data.table::fread(opt$runs_csv, showProgress = FALSE)
if (nrow(runs) == 0) stop("runs_csv is empty: ", opt$runs_csv)

for (cn in c("co2_kg_total", "energy_kwh_total", "diesel_gal_total")) {
  if (!cn %in% names(runs)) runs[, (cn) := NA_real_]
}
if (!"pair_id" %in% names(runs)) runs[, pair_id := NA_character_]
if (!"origin_network" %in% names(runs)) runs[, origin_network := NA_character_]
if (!"traffic_mode" %in% names(runs)) runs[, traffic_mode := NA_character_]
if (!"scenario" %in% names(runs)) runs[, scenario := NA_character_]
if (!"powertrain" %in% names(runs)) runs[, powertrain := NA_character_]
runs[, seed := suppressWarnings(as.integer(sub("^.*_([0-9]+)$", "\\1", as.character(run_id))))]

kpi_cols <- intersect(c("co2_kg_total", "energy_kwh_total", "diesel_gal_total", "queue_delay_minutes", "load_unload_min"), names(runs))
keys <- c("scenario", "powertrain", "origin_network", "traffic_mode")
kpi_n <- runs[, .(n_runs = .N), by = keys]
if (length(kpi_cols) > 0) {
  kpi_mean <- runs[, lapply(.SD, function(x) mean(as.numeric(x), na.rm = TRUE)), by = keys, .SDcols = kpi_cols]
  data.table::setnames(kpi_mean, old = kpi_cols, new = paste0(kpi_cols, "_mean"))
  kpi_p50 <- runs[, lapply(.SD, function(x) as.numeric(stats::quantile(as.numeric(x), 0.5, na.rm = TRUE, names = FALSE))), by = keys, .SDcols = kpi_cols]
  data.table::setnames(kpi_p50, old = kpi_cols, new = paste0(kpi_cols, "_p50"))
  kpi <- merge(kpi_n, kpi_mean, by = keys, all = TRUE)
  kpi <- merge(kpi, kpi_p50, by = keys, all = TRUE)
} else {
  kpi <- kpi_n
}
data.table::fwrite(kpi, file.path(opt$outdir, "kpi_topline.csv"))

origin_pairs <- runs[!is.na(pair_id) & nzchar(pair_id), .(
  co2_kg_total = as.numeric(co2_kg_total),
  energy_kwh_total = as.numeric(energy_kwh_total),
  diesel_gal_total = as.numeric(diesel_gal_total)
), by = .(scenario, powertrain, traffic_mode, pair_id, origin_network)]
origin_wide <- data.table::dcast(
  origin_pairs,
  scenario + powertrain + traffic_mode + pair_id ~ origin_network,
  value.var = c("co2_kg_total", "energy_kwh_total", "diesel_gal_total"),
  fun.aggregate = mean
)
if ("co2_kg_total_refrigerated_factory_set" %in% names(origin_wide) && "co2_kg_total_dry_factory_set" %in% names(origin_wide)) {
  origin_wide[, delta_co2_refrigerated_minus_dry := co2_kg_total_refrigerated_factory_set - co2_kg_total_dry_factory_set]
}
if ("energy_kwh_total_refrigerated_factory_set" %in% names(origin_wide) && "energy_kwh_total_dry_factory_set" %in% names(origin_wide)) {
  origin_wide[, delta_energy_kwh_refrigerated_minus_dry := energy_kwh_total_refrigerated_factory_set - energy_kwh_total_dry_factory_set]
}
data.table::fwrite(origin_wide, file.path(opt$outdir, "paired_delta_origin.csv"))

traffic_pairs <- runs[!is.na(pair_id) & nzchar(pair_id), .(
  scenario, powertrain, origin_network, pair_base = sub("_(stochastic|freeflow)$", "", as.character(pair_id)),
  traffic_mode, co2_kg_total = as.numeric(co2_kg_total), energy_kwh_total = as.numeric(energy_kwh_total)
)]
traffic_wide <- data.table::dcast(
  traffic_pairs,
  scenario + powertrain + origin_network + pair_base ~ traffic_mode,
  value.var = c("co2_kg_total", "energy_kwh_total"),
  fun.aggregate = mean
)
if ("co2_kg_total_stochastic" %in% names(traffic_wide) && "co2_kg_total_freeflow" %in% names(traffic_wide)) {
  traffic_wide[, delta_co2_stochastic_minus_freeflow := co2_kg_total_stochastic - co2_kg_total_freeflow]
}
if ("energy_kwh_total_stochastic" %in% names(traffic_wide) && "energy_kwh_total_freeflow" %in% names(traffic_wide)) {
  traffic_wide[, delta_energy_stochastic_minus_freeflow := energy_kwh_total_stochastic - energy_kwh_total_freeflow]
}
data.table::fwrite(traffic_wide, file.path(opt$outdir, "paired_delta_traffic.csv"))

pt_pairs <- runs[!is.na(seed), .(
  scenario, origin_network, traffic_mode, seed, powertrain,
  co2_kg_total = as.numeric(co2_kg_total), energy_kwh_total = as.numeric(energy_kwh_total), diesel_gal_total = as.numeric(diesel_gal_total)
)]
pt_wide <- data.table::dcast(
  pt_pairs,
  scenario + origin_network + traffic_mode + seed ~ powertrain,
  value.var = c("co2_kg_total", "energy_kwh_total", "diesel_gal_total"),
  fun.aggregate = mean
)
if ("co2_kg_total_bev" %in% names(pt_wide) && "co2_kg_total_diesel" %in% names(pt_wide)) {
  pt_wide[, delta_co2_bev_minus_diesel := co2_kg_total_bev - co2_kg_total_diesel]
}
if ("energy_kwh_total_bev" %in% names(pt_wide) && "energy_kwh_total_diesel" %in% names(pt_wide)) {
  pt_wide[, delta_energy_kwh_bev_minus_diesel := energy_kwh_total_bev - energy_kwh_total_diesel]
}
data.table::fwrite(pt_wide, file.path(opt$outdir, "paired_delta_powertrain.csv"))

time_cols <- c(
  "trip_duration_total_h", "driver_driving_min", "time_charging_min", "time_refuel_min",
  "time_traffic_delay_min", "driver_off_duty_min", "time_load_unload_min", "charge_stops", "refuel_stops"
)
for (cn in time_cols) if (!cn %in% names(runs)) runs[, (cn) := NA_real_]
route_time_breakdown <- runs[, lapply(.SD, function(x) mean(as.numeric(x), na.rm = TRUE)), by = .(
  scenario = as.character(scenario),
  powertrain = as.character(powertrain),
  origin_network = as.character(origin_network),
  traffic_mode = as.character(traffic_mode)
), .SDcols = time_cols]
data.table::fwrite(route_time_breakdown, file.path(opt$outdir, "route_time_breakdown.csv"))

if (!"route_id" %in% names(runs)) runs[, route_id := NA_character_]
if (!"driver_on_duty_min" %in% names(runs)) runs[, driver_on_duty_min := NA_real_]
runs[, stop_time_min := rowSums(cbind(as.numeric(time_charging_min), as.numeric(time_refuel_min), as.numeric(time_load_unload_min)), na.rm = TRUE)]
pt_time <- runs[!is.na(seed), .(
  scenario, route_id = as.character(route_id), origin_network, traffic_mode, seed,
  powertrain = tolower(as.character(powertrain)),
  trip_duration_total_h = as.numeric(trip_duration_total_h),
  stop_time_min = as.numeric(stop_time_min),
  driver_on_duty_min = as.numeric(driver_on_duty_min)
)]
pt_time_wide <- data.table::dcast(
  pt_time,
  scenario + route_id + origin_network + traffic_mode + seed ~ powertrain,
  value.var = c("trip_duration_total_h", "stop_time_min", "driver_on_duty_min"),
  fun.aggregate = mean
)
if ("trip_duration_total_h_bev" %in% names(pt_time_wide) && "trip_duration_total_h_diesel" %in% names(pt_time_wide)) {
  pt_time_wide[, delta_trip_duration_h := trip_duration_total_h_bev - trip_duration_total_h_diesel]
}
if ("stop_time_min_bev" %in% names(pt_time_wide) && "stop_time_min_diesel" %in% names(pt_time_wide)) {
  pt_time_wide[, delta_stop_time_min := stop_time_min_bev - stop_time_min_diesel]
}
if ("driver_on_duty_min_bev" %in% names(pt_time_wide) && "driver_on_duty_min_diesel" %in% names(pt_time_wide)) {
  pt_time_wide[, delta_driver_on_duty_min := driver_on_duty_min_bev - driver_on_duty_min_diesel]
}
data.table::fwrite(pt_time_wide, file.path(opt$outdir, "pairwise_bev_vs_diesel_time_delta.csv"))

validation_roots <- parse_csv_tokens(opt$validation_roots)
lci_stage <- data.table::data.table()
lci_system <- data.table::data.table()
if (length(validation_roots) > 0) {
  ledger_files <- unique(unlist(lapply(validation_roots, function(root) {
    if (!dir.exists(root)) return(character())
    list.files(root, pattern = "merged_inventory_ledger\\.csv$", recursive = TRUE, full.names = TRUE)
  }), use.names = FALSE))

  if (length(ledger_files) > 0) {
    rows <- lapply(ledger_files, function(path) {
      d <- data.table::fread(path, showProgress = FALSE)
      if (nrow(d) == 0) return(NULL)
      d[, validation_root := dirname(dirname(path))]
      d[, scenario := sub("^end_to_end_", "", basename(dirname(path)))]
      d
    })
    rows <- Filter(Negate(is.null), rows)
    if (length(rows) > 0) {
      ledger <- data.table::rbindlist(rows, fill = TRUE, use.names = TRUE)
      if (!"dataset_key" %in% names(ledger)) ledger[, dataset_key := NA_character_]
      if (!"stage" %in% names(ledger)) ledger[, stage := NA_character_]
      if (!"system_id" %in% names(ledger)) ledger[, system_id := NA_character_]
      ledger[, complete_flag := as.integer(!is.na(dataset_key) & dataset_key != "" & dataset_key != "NEEDS_SOURCE_VALUE")]

      lci_stage <- ledger[, .(
        rows = .N,
        complete_rows = sum(complete_flag, na.rm = TRUE),
        completion_pct = 100 * sum(complete_flag, na.rm = TRUE) / .N
      ), by = .(validation_root, scenario, system_id, stage)]
      lci_system <- ledger[, .(
        rows = .N,
        complete_rows = sum(complete_flag, na.rm = TRUE),
        completion_pct = 100 * sum(complete_flag, na.rm = TRUE) / .N
      ), by = .(validation_root, scenario, system_id)]
    }
  }
}

data.table::fwrite(lci_stage, file.path(opt$outdir, "lci_completeness_by_stage.csv"))
data.table::fwrite(lci_system, file.path(opt$outdir, "lci_completeness_by_system.csv"))

slides_deltas <- data.table::rbindlist(list(
  if (nrow(origin_wide) > 0) data.table::data.table(delta_type = "origin", origin_wide) else NULL,
  if (nrow(traffic_wide) > 0) data.table::data.table(delta_type = "traffic", traffic_wide) else NULL,
  if (nrow(pt_wide) > 0) data.table::data.table(delta_type = "powertrain", pt_wide) else NULL
), fill = TRUE, use.names = TRUE)

data.table::fwrite(kpi, file.path(opt$outdir, "slides_ready_kpi.csv"))
data.table::fwrite(slides_deltas, file.path(opt$outdir, "slides_ready_paired_deltas.csv"))
data.table::fwrite(lci_stage, file.path(opt$outdir, "slides_ready_lci_completeness.csv"))
data.table::fwrite(route_time_breakdown, file.path(opt$outdir, "slides_ready_route_time_breakdown.csv"))

cat("Wrote", file.path(opt$outdir, "kpi_topline.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "paired_delta_origin.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "paired_delta_traffic.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "paired_delta_powertrain.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "route_time_breakdown.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "pairwise_bev_vs_diesel_time_delta.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "lci_completeness_by_stage.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "lci_completeness_by_system.csv"), "\n")
