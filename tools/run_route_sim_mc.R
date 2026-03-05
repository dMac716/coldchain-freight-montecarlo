#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

source_files <- c(
  list.files("R", pattern = "\\.R$", full.names = TRUE),
  list.files("R/io", pattern = "\\.R$", full.names = TRUE),
  list.files("R/sim", pattern = "\\.R$", full.names = TRUE)
)
for (f in source_files) source(f, local = FALSE)

read_cfg <- function(path) {
  if (!requireNamespace("yaml", quietly = TRUE)) stop("yaml package required for route sim config")
  y <- yaml::read_yaml(path)
  if (!is.null(y$test_kit)) y$test_kit else y
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--config"), type = "character", default = "test_kit.yaml"),
  make_option(c("--routes"), type = "character", default = ""),
  make_option(c("--elevation"), type = "character", default = "data/derived/route_elevation_profiles.csv"),
  make_option(c("--facility_id"), type = "character", default = "FACILITY_REFRIG_ENNIS"),
  make_option(c("--scenario"), type = "character", default = "route_sim_demo"),
  make_option(c("--powertrain"), type = "character", default = "bev"),
  make_option(c("--trip_leg"), type = "character", default = "outbound"),
  make_option(c("--n"), type = "integer", default = 20L),
  make_option(c("--seed"), type = "integer", default = 123),
  make_option(c("--bundle_root"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--stations"), type = "character", default = ""),
  make_option(c("--plans"), type = "character", default = ""),
  make_option(c("--summary_out"), type = "character", default = "outputs/summaries/route_sim_summary.csv"),
  make_option(c("--runs_out"), type = "character", default = ""),
  make_option(c("--progress_file"), type = "character", default = ""),
  make_option(c("--worker_label"), type = "character", default = "")
)))

cfg <- read_cfg(opt$config)
routes_path <- if (nzchar(opt$routes)) opt$routes else as.character(cfg$routing$routes_geometry_path %||% "data/derived/routes_facility_to_petco.csv")
routes <- read_route_geometries(routes_path)
r <- select_route_row(routes, facility_id = opt$facility_id, route_rank = 1L)
elev <- load_elevation_profile(opt$elevation, route_id = r$route_id[[1]])
segments <- build_route_segments(r, elevation_profile = elev)

planned_stops <- data.frame()
selected_plan_id <- NA_character_
od_cache <- data.frame()
od_path <- as.character(cfg$routing$od_cache_path %||% "")
if (nzchar(od_path) && file.exists(od_path)) {
  od_cache <- read_od_cache(od_path)
}
if (tolower(opt$powertrain) == "bev") {
  stations_path <- if (nzchar(opt$stations)) opt$stations else as.character(cfg$charging$stations_path %||% "data/derived/ev_charging_stations_corridor.csv")
  plans_path <- if (nzchar(opt$plans)) opt$plans else as.character(cfg$charging$route_plans_path %||% "data/derived/bev_route_plans.csv")
  stations <- read_ev_stations(stations_path)
  plans <- read_bev_route_plans(plans_path)
  sel <- select_valid_plan_for_route(plans, stations, as.character(r$route_id[[1]]), segments, cfg$tractors$bev_ecascadia$soc_policy)
  planned_stops <- sel$projected
  selected_plan_id <- as.character(sel$plan$route_plan_id[[1]] %||% NA_character_)
}

rows <- list()
write_progress <- function(i, status) {
  if (!nzchar(opt$progress_file)) return(invisible(NULL))
  p <- data.frame(
    worker_label = as.character(opt$worker_label %||% ""),
    i = as.integer(i),
    n = as.integer(opt$n),
    status = as.character(status),
    timestamp_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
    stringsAsFactors = FALSE
  )
  dir.create(dirname(opt$progress_file), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(p, opt$progress_file, row.names = FALSE)
}

write_progress(0L, "STARTING")
for (i in seq_len(as.integer(opt$n))) {
  s <- as.integer(opt$seed) + i - 1L
  sim <- simulate_route_day(
    route_segments = segments,
    cfg = cfg,
    powertrain = tolower(opt$powertrain),
    scenario = opt$scenario,
    seed = s,
    trip_leg = tolower(opt$trip_leg),
    planned_stops = planned_stops,
    od_cache = od_cache
  )
  rid <- paste(opt$scenario, tolower(opt$powertrain), s, sep = "_")
  paths <- write_route_sim_outputs(sim, rid)
  write_run_bundle(
    sim = sim,
    context = list(
      run_id = rid,
      scenario = opt$scenario,
      facility_id = opt$facility_id,
      route_id = as.character(r$route_id[[1]]),
      route_plan_id = selected_plan_id,
      powertrain = tolower(opt$powertrain),
      trip_leg = tolower(opt$trip_leg),
      seed = s,
      mc_draws = as.integer(opt$n)
    ),
    cfg_resolved = cfg,
    tracks_path = paths$track_path,
    bundle_root = opt$bundle_root
  )
  total_co2 <- if (nrow(sim$sim_state) > 0) tail(sim$sim_state$co2_kg_cum, 1) else NA_real_
  status <- if (isTRUE(sim$metadata$plan_soc_violation)) "PLAN_SOC_VIOLATION" else "OK"
  rows[[i]] <- data.frame(
    run_id = rid,
    scenario = opt$scenario,
    powertrain = tolower(opt$powertrain),
    status = status,
    co2_kg_total = total_co2,
    stringsAsFactors = FALSE
  )
  write_progress(i, status)
}

runs <- do.call(rbind, rows)
sum_df <- summarize_route_sim_runs(runs)
dir.create(dirname(opt$summary_out), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(sum_df, opt$summary_out, row.names = FALSE)
if (nzchar(opt$runs_out)) {
  dir.create(dirname(opt$runs_out), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(runs, opt$runs_out, row.names = FALSE)
}
write_progress(as.integer(opt$n), "DONE")
cat("Wrote", opt$summary_out, "\n")
if (nzchar(opt$runs_out)) cat("Wrote", opt$runs_out, "\n")
