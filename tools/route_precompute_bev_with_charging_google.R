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
  make_option(c("--output"), type = "character", default = "data/derived/bev_route_plans.csv")
)
opt <- parse_args(OptionParser(option_list = option_list))

routes <- utils::read.csv(opt$routes, stringsAsFactors = FALSE)
st <- utils::read.csv(opt$stations, stringsAsFactors = FALSE)
if (nrow(routes) == 0) stop("No routes found.")
if (nrow(st) == 0) stop("No stations found.")

rows <- list()
for (i in seq_len(nrow(routes))) {
  r <- routes[i, , drop = FALSE]
  poly_df <- decode_polyline(as.character(r$encoded_polyline[[1]]))
  seg <- polyline_to_segments(poly_df)
  d_km <- as.numeric(r$distance_m[[1]]) / 1000

  waypoint_ids <- if (is.finite(d_km) && d_km > as.numeric(opt$usable_range_km)) {
    select_charging_waypoints(seg, st, target_spacing_km = as.numeric(opt$usable_range_km), max_offset_km = 25)
  } else {
    character()
  }

  plan_sig <- paste(r$route_id[[1]], paste(waypoint_ids, collapse = ","), sep = "|")
  plan_id <- digest::digest(plan_sig, algo = "sha256", serialize = FALSE)

  rows[[length(rows) + 1]] <- data.frame(
    route_plan_id = plan_id,
    route_id = as.character(r$route_id[[1]]),
    facility_id = as.character(r$facility_id[[1]]),
    retail_id = as.character(r$retail_id[[1]]),
    waypoint_station_ids = paste(waypoint_ids, collapse = "|"),
    waypoint_count = length(waypoint_ids),
    total_distance_m = as.numeric(r$distance_m[[1]]),
    total_duration_s = as.numeric(r$duration_s[[1]]),
    provider = "google_routes_cached",
    timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors = FALSE
  )
}

out <- do.call(rbind, rows)
dir.create(dirname(opt$output), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, opt$output, row.names = FALSE)
cat("Wrote", opt$output, "\n")
