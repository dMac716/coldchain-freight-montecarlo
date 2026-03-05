#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

# Local-only hardcoded paths.
MAP_PATH <- "/Users/dMac/Repos/coldchain-freight-montecarlo/sources/data/osm/"
DATA_PATH <- "/Users/dMac/Repos/coldchain-freight-montecarlo/data/derived/"

# Keep BLAS/OpenMP from oversubscribing shared hosts.
Sys.setenv(
  OMP_NUM_THREADS = "1",
  OPENBLAS_NUM_THREADS = "1",
  MKL_NUM_THREADS = "1",
  VECLIB_MAXIMUM_THREADS = "1",
  NUMEXPR_NUM_THREADS = "1"
)

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
  make_option(c("--elevation"), type = "character", default = file.path(DATA_PATH, "route_elevation_profiles.csv")),
  make_option(c("--facility_id"), type = "character", default = "FACILITY_REFRIG_ENNIS"),
  make_option(c("--scenario"), type = "character", default = "route_sim_demo"),
  make_option(c("--powertrain"), type = "character", default = "bev"),
  make_option(c("--product_type"), type = "character", default = ""),
  make_option(c("--origin_network"), type = "character", default = ""),
  make_option(c("--paired_origin_networks"), type = "character", default = "false"),
  make_option(c("--traffic_mode"), type = "character", default = "stochastic"),
  make_option(c("--paired_traffic_modes"), type = "character", default = "false"),
  make_option(c("--facility_id_dry"), type = "character", default = "FACILITY_DRY_TOPEKA"),
  make_option(c("--facility_id_refrigerated"), type = "character", default = "FACILITY_REFRIG_ENNIS"),
  make_option(c("--trip_leg"), type = "character", default = "outbound"),
  make_option(c("--n"), type = "integer", default = 20L),
  make_option(c("--seed"), type = "integer", default = 123),
  make_option(c("--bundle_root"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--stations"), type = "character", default = ""),
  make_option(c("--plans"), type = "character", default = ""),
  make_option(c("--summary_out"), type = "character", default = "outputs/summaries/route_sim_summary.csv"),
  make_option(c("--runs_out"), type = "character", default = ""),
  make_option(c("--progress_file"), type = "character", default = ""),
  make_option(c("--worker_label"), type = "character", default = ""),
  make_option(c("--throttle_seconds"), type = "double", default = 0)
)))

cfg <- read_cfg(opt$config)
paired_origin_networks <- tolower(as.character(opt$paired_origin_networks %||% "false")) %in% c("1", "true", "yes", "y")
paired_traffic_modes <- tolower(as.character(opt$paired_traffic_modes %||% "false")) %in% c("1", "true", "yes", "y")
traffic_mode_input <- tolower(as.character(opt$traffic_mode %||% "stochastic"))
if (!traffic_mode_input %in% c("stochastic", "freeflow")) {
  stop("--traffic_mode must be one of: stochastic, freeflow")
}
infer_product_type <- function() {
  if (nzchar(opt$product_type)) return(tolower(opt$product_type))
  sc <- tolower(opt$scenario)
  if (grepl("dry", sc, fixed = TRUE)) return("dry")
  if (grepl("refriger", sc, fixed = TRUE)) return("refrigerated")
  "refrigerated"
}
infer_origin_network <- function() {
  if (nzchar(opt$origin_network)) return(tolower(opt$origin_network))
  sc <- tolower(opt$scenario)
  if (grepl("from_dry", sc, fixed = TRUE) || grepl("dry_factory_set", sc, fixed = TRUE)) return("dry_factory_set")
  if (grepl("from_reefer", sc, fixed = TRUE) || grepl("refrigerated_factory_set", sc, fixed = TRUE)) return("refrigerated_factory_set")
  NA_character_
}
routes_path <- if (nzchar(opt$routes)) opt$routes else as.character(cfg$routing$routes_geometry_path %||% file.path(DATA_PATH, "routes_facility_to_petco.csv"))
routes <- read_route_geometries(routes_path)
od_cache <- data.frame()
od_path <- as.character(cfg$routing$od_cache_path %||% file.path(DATA_PATH, "google_routes_od_cache.csv"))
if (nzchar(od_path) && file.exists(od_path)) {
  od_cache <- read_od_cache(od_path)
}

stations <- data.frame()
plans <- data.frame()
if (tolower(opt$powertrain) == "bev") {
  stations_path <- if (nzchar(opt$stations)) opt$stations else as.character(cfg$charging$stations_path %||% file.path(DATA_PATH, "ev_charging_stations_corridor.csv"))
  plans_path <- if (nzchar(opt$plans)) opt$plans else as.character(cfg$charging$route_plans_path %||% file.path(DATA_PATH, "bev_route_plans.csv"))
  stations <- read_ev_stations(stations_path)
  plans <- read_bev_route_plans(plans_path)
}

build_facility_context <- function(facility_id) {
  r <- select_route_row(routes, facility_id = facility_id, route_rank = 1L)
  elev <- load_elevation_profile(opt$elevation, route_id = r$route_id[[1]])
  segments <- build_route_segments(r, elevation_profile = elev)
  planned_stops <- data.frame()
  selected_plan_id <- NA_character_
  if (tolower(opt$powertrain) == "bev") {
    sel <- select_valid_plan_for_route(plans, stations, as.character(r$route_id[[1]]), segments, cfg$tractors$bev_ecascadia$soc_policy)
    planned_stops <- sel$projected
    selected_plan_id <- as.character(sel$plan$route_plan_id[[1]] %||% NA_character_)
  }
  list(
    facility_id = facility_id,
    route_row = r,
    segments = segments,
    planned_stops = planned_stops,
    selected_plan_id = selected_plan_id
  )
}

facility_contexts <- if (paired_origin_networks) {
  list(
    dry_factory_set = build_facility_context(opt$facility_id_dry),
    refrigerated_factory_set = build_facility_context(opt$facility_id_refrigerated)
  )
} else {
  list(single = build_facility_context(opt$facility_id))
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
  exo <- sample_exogenous_draws(cfg, seed = s)
  pair_id_base <- paste0(opt$scenario, "_", tolower(opt$powertrain), "_seed_", s)

  exo_for_mode <- function(mode) {
    out <- exo
    if (identical(mode, "freeflow")) {
      out$traffic_multiplier <- 1.0
      out$queue_delay_minutes <- 0.0
    }
    out
  }

  run_one <- function(ctx, origin_network_label, traffic_mode_label) {
    exo_mode <- exo_for_mode(traffic_mode_label)
    pair_id <- if (paired_traffic_modes) {
      paste0(pair_id_base, "_", as.character(origin_network_label %||% infer_origin_network()))
    } else {
      pair_id_base
    }
    sim <- simulate_route_day(
      route_segments = ctx$segments,
      cfg = cfg,
      powertrain = tolower(opt$powertrain),
      scenario = opt$scenario,
      seed = s,
      trip_leg = tolower(opt$trip_leg),
      planned_stops = ctx$planned_stops,
      od_cache = od_cache,
      exogenous_draws = exo_mode
    )
    rid <- if (paired_origin_networks) {
      paste(opt$scenario, tolower(opt$powertrain), origin_network_label, traffic_mode_label, s, sep = "_")
    } else {
      paste(opt$scenario, tolower(opt$powertrain), traffic_mode_label, s, sep = "_")
    }
    paths <- write_route_sim_outputs(sim, rid)
    write_run_bundle(
      sim = sim,
      context = list(
        run_id = rid,
        scenario = opt$scenario,
        product_type = infer_product_type(),
        origin_network = as.character(origin_network_label %||% infer_origin_network()),
        traffic_mode = traffic_mode_label,
        facility_id = ctx$facility_id,
        route_id = as.character(ctx$route_row$route_id[[1]]),
        route_plan_id = ctx$selected_plan_id,
        powertrain = tolower(opt$powertrain),
        trip_leg = tolower(opt$trip_leg),
        seed = s,
        mc_draws = as.integer(opt$n),
        pair_id = pair_id
      ),
      cfg_resolved = cfg,
      tracks_path = paths$track_path,
      bundle_root = opt$bundle_root
    )
    total_co2 <- if (nrow(sim$sim_state) > 0) tail(sim$sim_state$co2_kg_cum, 1) else NA_real_
    status <- if (isTRUE(sim$metadata$plan_soc_violation)) "PLAN_SOC_VIOLATION" else "OK"
    data.frame(
      run_id = rid,
      pair_id = pair_id,
      scenario = opt$scenario,
      powertrain = tolower(opt$powertrain),
      origin_network = as.character(origin_network_label %||% infer_origin_network()),
      traffic_mode = traffic_mode_label,
      payload_lb = as.numeric(exo_mode$payload_lb %||% NA_real_),
      ambient_f = as.numeric(exo_mode$ambient_f %||% NA_real_),
      traffic_multiplier = as.numeric(exo_mode$traffic_multiplier %||% NA_real_),
      queue_delay_minutes = as.numeric(exo_mode$queue_delay_minutes %||% NA_real_),
      grid_kg_per_kwh = as.numeric(exo_mode$grid_kg_per_kwh %||% NA_real_),
      mpg = as.numeric(exo_mode$mpg %||% NA_real_),
      status = status,
      co2_kg_total = total_co2,
      stringsAsFactors = FALSE
    )
  }

  traffic_modes <- if (paired_traffic_modes) c("stochastic", "freeflow") else traffic_mode_input
  iter_status <- "OK"
  iter_statuses <- character()
  for (tm in traffic_modes) {
    if (paired_origin_networks) {
      r1 <- run_one(facility_contexts$dry_factory_set, "dry_factory_set", tm)
      r2 <- run_one(facility_contexts$refrigerated_factory_set, "refrigerated_factory_set", tm)
      rows[[length(rows) + 1L]] <- r1
      rows[[length(rows) + 1L]] <- r2
      iter_statuses <- c(iter_statuses, as.character(r1$status[[1]]), as.character(r2$status[[1]]))
    } else {
      r <- run_one(facility_contexts$single, infer_origin_network(), tm)
      rows[[length(rows) + 1L]] <- r
      iter_statuses <- c(iter_statuses, as.character(r$status[[1]] %||% "OK"))
    }
  }
  iter_status <- if (any(iter_statuses != "OK")) paste(unique(iter_statuses[iter_statuses != "OK"]), collapse = "|") else "OK"
  write_progress(i, iter_status)
  if (is.finite(opt$throttle_seconds) && as.numeric(opt$throttle_seconds) > 0) {
    Sys.sleep(as.numeric(opt$throttle_seconds))
  }
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
