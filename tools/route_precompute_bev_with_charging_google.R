#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(digest)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--routes"), type = "character", default = "data/derived/routes_facility_to_petco.csv"),
  make_option(c("--stations"), type = "character", default = "data/derived/ev_charging_stations_corridor.csv"),
  make_option(c("--usable_range_km"), type = "double", default = 350),
  make_option(c("--auto_generate_stations"), type = "character", default = "true", help = "Auto-generate --stations via tools/charging_stations_cache_google.R when missing"),
  make_option(c("--stations_anchor_step"), type = "integer", default = 6L),
  make_option(c("--stations_radius_m"), type = "integer", default = 20000L),
  make_option(c("--stations_api_mode"), type = "character", default = "new"),
  make_option(c("--stations_place_type"), type = "character", default = "electric_vehicle_charging_station"),
  make_option(c("--stations_keyword"), type = "character", default = ""),
  make_option(c("--stations_min_kw"), type = "double", default = 0),
  make_option(c("--stations_connector_types"), type = "character", default = ""),
  make_option(c("--output"), type = "character", default = "data/derived/bev_route_plans.csv")
)
opt <- parse_args(OptionParser(option_list = option_list))

parse_bool <- function(x, default = FALSE) {
  v <- tolower(trimws(as.character(x)))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Invalid boolean flag: ", x)
}

if (!file.exists(opt$routes)) {
  stop(
    "Routes CSV not found: ", opt$routes,
    ". Generate it first with: Rscript tools/route_precompute_google.R --output ", opt$routes
  )
}

if (!file.exists(opt$stations)) {
  if (!parse_bool(opt$auto_generate_stations, default = TRUE)) {
    stop(
      "Stations CSV not found: ", opt$stations,
      ". Generate it with: Rscript tools/charging_stations_cache_google.R --routes ",
      opt$routes, " --output ", opt$stations
    )
  }
  cat("Stations CSV missing; generating with tools/charging_stations_cache_google.R\n")
  cmd <- c(
    "tools/charging_stations_cache_google.R",
    "--routes", opt$routes,
    "--anchor_step", as.character(opt$stations_anchor_step),
    "--radius_m", as.character(opt$stations_radius_m),
    "--api_mode", as.character(opt$stations_api_mode),
    "--place_type", as.character(opt$stations_place_type),
    "--min_kw", as.character(opt$stations_min_kw)
  )
  if (nzchar(trimws(as.character(opt$stations_keyword)))) {
    cmd <- c(cmd, "--keyword", as.character(opt$stations_keyword))
  }
  if (nzchar(trimws(as.character(opt$stations_connector_types)))) {
    cmd <- c(cmd, "--connector_types", as.character(opt$stations_connector_types))
  }
  cmd <- c(cmd, "--output", opt$stations)
  out <- suppressWarnings(system2("Rscript", cmd, stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop(
      "Failed to auto-generate stations CSV at ", opt$stations, ".\n",
      paste(out, collapse = "\n")
    )
  }
  if (!file.exists(opt$stations)) {
    stop("Stations CSV was not created: ", opt$stations)
  }
}

routes <- utils::read.csv(opt$routes, stringsAsFactors = FALSE)
st <- utils::read.csv(opt$stations, stringsAsFactors = FALSE)
if (nrow(routes) == 0) stop("No routes found.")
if (nrow(st) == 0) stop("No stations found.")

# Normalise duration column names: the traffic-aware Google Routes cache emits
# road_duration_minutes / road_duration_minutes_static; the older cache and OSRM
# cache emit duration_s. Resolve both so downstream code uses duration_s_resolved.
resolve_duration_s <- function(r) {
  if ("duration_s" %in% names(r) && is.finite(as.numeric(r$duration_s[[1]]))) {
    return(as.numeric(r$duration_s[[1]]))
  }
  if ("road_duration_minutes" %in% names(r) && is.finite(as.numeric(r$road_duration_minutes[[1]]))) {
    return(as.numeric(r$road_duration_minutes[[1]]) * 60)
  }
  NA_real_
}
resolve_duration_s_static <- function(r) {
  # Shell route precompute outputs duration_s_static (seconds); traffic OD cache
  # outputs road_duration_minutes_static (minutes). Check both.
  if ("duration_s_static" %in% names(r) && is.finite(as.numeric(r$duration_s_static[[1]]))) {
    return(as.numeric(r$duration_s_static[[1]]))
  }
  if ("road_duration_minutes_static" %in% names(r) && is.finite(as.numeric(r$road_duration_minutes_static[[1]]))) {
    return(as.numeric(r$road_duration_minutes_static[[1]]) * 60)
  }
  NA_real_
}
resolve_distance_m <- function(r) {
  if ("distance_m" %in% names(r) && is.finite(as.numeric(r$distance_m[[1]]))) {
    return(as.numeric(r$distance_m[[1]]))
  }
  if ("road_distance_miles" %in% names(r) && is.finite(as.numeric(r$road_distance_miles[[1]]))) {
    return(as.numeric(r$road_distance_miles[[1]]) * 1609.344)
  }
  NA_real_
}

rows <- list()
for (i in seq_len(nrow(routes))) {
  r <- routes[i, , drop = FALSE]
  poly_df <- decode_polyline(as.character(r$encoded_polyline[[1]]))
  seg <- polyline_to_segments(poly_df)
  d_m   <- resolve_distance_m(r)
  d_km  <- if (is.finite(d_m)) d_m / 1000 else NA_real_
  dur_s <- resolve_duration_s(r)
  dur_s_static <- resolve_duration_s_static(r)

  if (!is.finite(d_m) || d_m <= 0) {
    warning("Skipping route_id=", r$route_id[[1]], ": non-positive or missing distance.")
    next
  }

  waypoint_ids <- if (is.finite(d_km) && d_km > as.numeric(opt$usable_range_km)) {
    select_charging_waypoints(seg, st, target_spacing_km = as.numeric(opt$usable_range_km), max_offset_km = 25)
  } else {
    character()
  }

  plan_sig <- paste(r$route_id[[1]], paste(waypoint_ids, collapse = ","), sep = "|")
  plan_id <- digest::digest(plan_sig, algo = "sha256", serialize = FALSE)

  routing_pref <- if ("routing_preference" %in% names(r)) as.character(r$routing_preference[[1]]) else NA_character_

  rows[[length(rows) + 1]] <- data.frame(
    route_plan_id = plan_id,
    route_id = as.character(r$route_id[[1]]),
    facility_id = as.character(r$facility_id[[1]]),
    retail_id = as.character(r$retail_id[[1]]),
    waypoint_station_ids = paste(waypoint_ids, collapse = "|"),
    waypoint_count = length(waypoint_ids),
    total_distance_m = d_m,
    total_duration_s = dur_s,
    total_duration_s_static = dur_s_static,
    routing_preference = routing_pref,
    provider = "google_routes_cached",
    timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors = FALSE
  )
}

out <- do.call(rbind, rows)
dir.create(dirname(opt$output), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, opt$output, row.names = FALSE)
cat("Wrote", opt$output, "\n")
