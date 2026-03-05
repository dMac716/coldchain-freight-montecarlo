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
  make_option(c("--powertrain"), type = "character", default = "bev"),
  make_option(c("--scenario"), type = "character", default = "route_sim_demo"),
  make_option(c("--trip_leg"), type = "character", default = "outbound"),
  make_option(c("--seed"), type = "integer", default = 123),
  make_option(c("--run_id"), type = "character", default = ""),
  make_option(c("--bundle_root"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--stations"), type = "character", default = ""),
  make_option(c("--plans"), type = "character", default = "")
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

sim <- simulate_route_day(
  route_segments = segments,
  cfg = cfg,
  powertrain = tolower(opt$powertrain),
  scenario = opt$scenario,
  seed = opt$seed,
  trip_leg = tolower(opt$trip_leg),
  planned_stops = planned_stops,
  od_cache = od_cache
)

rid <- if (nzchar(opt$run_id)) opt$run_id else paste(opt$scenario, tolower(opt$powertrain), opt$seed, sep = "_")
paths <- write_route_sim_outputs(sim, rid)
bundle <- write_run_bundle(
  sim = sim,
  context = list(
    run_id = rid,
    scenario = opt$scenario,
    facility_id = opt$facility_id,
    route_id = as.character(r$route_id[[1]]),
    route_plan_id = selected_plan_id,
    powertrain = tolower(opt$powertrain),
    trip_leg = tolower(opt$trip_leg),
    seed = as.integer(opt$seed),
    mc_draws = 1L
  ),
  cfg_resolved = cfg,
  tracks_path = paths$track_path,
  bundle_root = opt$bundle_root
)
cat("Wrote", paths$track_path, "\n")
cat("Wrote", paths$event_path, "\n")
cat("Wrote", bundle$bundle_dir, "\n")
