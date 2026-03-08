#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

safe_read_csv <- function(path) {
  if (!file.exists(path) || !isTRUE(file.info(path)$size > 0)) return(data.frame())
  tryCatch(utils::read.csv(path, stringsAsFactors = FALSE), error = function(e) data.frame())
}

read_track <- function(path_gz) {
  if (!file.exists(path_gz) || !isTRUE(file.info(path_gz)$size > 0)) return(data.frame())
  con <- gzfile(path_gz, open = "rt")
  on.exit(close(con), add = TRUE)
  tryCatch(utils::read.csv(con, stringsAsFactors = FALSE), error = function(e) data.frame())
}

parse_utc <- function(x) {
  as.POSIXct(x, tz = "UTC")
}

infer_stop_type <- function(event_type) {
  et <- toupper(as.character(event_type %||% ""))
  if (grepl("CHARGE", et, fixed = TRUE)) return("charging")
  if (grepl("REFUEL", et, fixed = TRUE)) return("refuel")
  if (grepl("LOAD", et, fixed = TRUE) || grepl("UNLOAD", et, fixed = TRUE)) return("load_unload")
  if (grepl("REST", et, fixed = TRUE) || grepl("BREAK", et, fixed = TRUE)) return("rest")
  if (grepl("ROUTE_COMPLETE", et, fixed = TRUE)) return("complete")
  "transit"
}

nearest_state_at <- function(track, t_event) {
  if (nrow(track) == 0 || !is.finite(as.numeric(t_event))) return(list())
  tt <- parse_utc(track$t)
  idx <- which(tt <= t_event)
  if (length(idx) == 0) {
    i <- 1L
  } else {
    i <- idx[[length(idx)]]
  }
  as.list(track[i, , drop = FALSE])
}

option_list <- list(
  make_option(c("--bundle_dir"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--scenario"), type = "character", default = ""),
  make_option(c("--seed"), type = "integer", default = NA_integer_),
  make_option(c("--run_id"), type = "character", default = ""),
  make_option(c("--outdir"), type = "character", default = "outputs/presentation/hero_run")
)
opt <- parse_args(OptionParser(option_list = option_list))

if (!nzchar(opt$run_id) && (!nzchar(opt$scenario) || !is.finite(opt$seed))) {
  stop("Provide either --run_id or both --scenario and --seed")
}

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

bundle_dirs <- list.dirs(opt$bundle_dir, full.names = TRUE, recursive = FALSE)
if (length(bundle_dirs) == 0) stop("No bundle directories found under ", opt$bundle_dir)

selected <- NULL
for (bd in bundle_dirs) {
  pm_path <- file.path(bd, "params.json")
  if (!file.exists(pm_path)) next
  pm <- tryCatch(jsonlite::fromJSON(pm_path, simplifyVector = TRUE), error = function(e) list())
  rid <- as.character(pm$run_id %||% basename(bd))
  if (nzchar(opt$run_id)) {
    if (!identical(rid, opt$run_id)) next
  } else {
    if (!identical(as.character(pm$scenario %||% ""), as.character(opt$scenario))) next
    if (!identical(as.integer(pm$seed %||% NA_integer_), as.integer(opt$seed))) next
  }
  selected <- list(bundle_dir = bd, params = pm, run_id = rid)
  break
}

if (is.null(selected)) stop("No matching hero run found")

events <- safe_read_csv(file.path(selected$bundle_dir, "events.csv"))
track <- read_track(file.path(selected$bundle_dir, "tracks.csv.gz"))
if (nrow(events) == 0) stop("No events found for selected run")
if (nrow(track) == 0) stop("No track found for selected run")

t0 <- parse_utc(track$t[[1]])
events$t_start_ts <- parse_utc(events$t_start)

event_rows <- lapply(seq_len(nrow(events)), function(i) {
  ev <- events[i, , drop = FALSE]
  t_ev <- ev$t_start_ts[[1]]
  st <- nearest_state_at(track, t_ev)
  soc_or_fuel <- NA_real_
  if (is.finite(as.numeric(st$soc %||% NA_real_))) {
    soc_or_fuel <- as.numeric(st$soc)
  } else if (is.finite(as.numeric(st$fuel_gal %||% NA_real_))) {
    soc_or_fuel <- as.numeric(st$fuel_gal)
  }
  driver_clock <- if (is.finite(as.numeric(st$trip_duration_h_cum %||% NA_real_))) {
    as.numeric(st$trip_duration_h_cum)
  } else {
    NA_real_
  }
  data.frame(
    time_min = as.numeric(difftime(t_ev, t0, units = "mins")),
    lat = as.numeric(ev$lat[[1]]),
    lon = as.numeric(ev$lng[[1]]),
    event_type = as.character(ev$event_type[[1]]),
    stop_type = infer_stop_type(ev$event_type[[1]]),
    soc_or_fuel = soc_or_fuel,
    co2_cum = as.numeric(st$co2_kg_cum %||% NA_real_),
    miles_cum = as.numeric(st$distance_miles_cum %||% NA_real_),
    driver_clock = driver_clock,
    stringsAsFactors = FALSE
  )
})
hero_event_log <- do.call(rbind, event_rows)
utils::write.csv(hero_event_log, file.path(opt$outdir, "hero_event_log.csv"), row.names = FALSE)

line_coords <- lapply(seq_len(nrow(track)), function(i) {
  list(as.numeric(track$lng[[i]]), as.numeric(track$lat[[i]]))
})
route_feature <- list(
  type = "Feature",
  properties = list(
    run_id = selected$run_id,
    scenario = as.character(selected$params$scenario %||% NA_character_),
    seed = as.integer(selected$params$seed %||% NA_integer_)
  ),
  geometry = list(type = "LineString", coordinates = line_coords)
)

point_features <- lapply(seq_len(nrow(hero_event_log)), function(i) {
  r <- hero_event_log[i, , drop = FALSE]
  list(
    type = "Feature",
    properties = list(
      run_id = selected$run_id,
      time_min = as.numeric(r$time_min[[1]]),
      event_type = as.character(r$event_type[[1]]),
      stop_type = as.character(r$stop_type[[1]]),
      soc_or_fuel = as.numeric(r$soc_or_fuel[[1]]),
      co2_cum = as.numeric(r$co2_cum[[1]]),
      miles_cum = as.numeric(r$miles_cum[[1]]),
      driver_clock = as.numeric(r$driver_clock[[1]])
    ),
    geometry = list(type = "Point", coordinates = list(as.numeric(r$lon[[1]]), as.numeric(r$lat[[1]])))
  )
})

jsonlite::write_json(
  list(type = "FeatureCollection", features = list(route_feature)),
  path = file.path(opt$outdir, "hero_route_line.geojson"),
  auto_unbox = TRUE,
  pretty = TRUE,
  null = "null"
)

jsonlite::write_json(
  list(type = "FeatureCollection", features = point_features),
  path = file.path(opt$outdir, "hero_route_stops.geojson"),
  auto_unbox = TRUE,
  pretty = TRUE,
  null = "null"
)

jsonlite::write_json(
  list(
    run_id = selected$run_id,
    scenario = as.character(selected$params$scenario %||% NA_character_),
    seed = as.integer(selected$params$seed %||% NA_integer_),
    bundle_dir = selected$bundle_dir
  ),
  path = file.path(opt$outdir, "hero_run_manifest.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  null = "null"
)

cat("Wrote", opt$outdir, "\n")
