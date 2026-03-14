#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(digest)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--provider"), type = "character", default = "osrm", help = "Routing provider: osrm|google"),
  make_option(c("--retail_id"), type = "character", default = "PETCO_DAVIS_COVELL", help = "Retail node ID"),
  make_option(c("--profile"), type = "character", default = "driving", help = "Routing profile"),
  make_option(c("--output"), type = "character", default = "data/derived/road_distance_facility_to_retail.csv", help = "Output CSV"),
  make_option(c("--osrm_base_url"), type = "character", default = "http://127.0.0.1:5000", help = "OSRM server URL"),
  make_option(c("--travel_mode"), type = "character", default = "DRIVE", help = "Google Routes travel mode"),
  make_option(c("--routing_preference"), type = "character", default = "TRAFFIC_UNAWARE", help = "Google routing preference")
)
opt <- parse_args(OptionParser(option_list = option_list))

fac <- utils::read.csv("data/inputs_local/facilities.csv", stringsAsFactors = FALSE)
ret <- utils::read.csv("data/inputs_local/retail_nodes.csv", stringsAsFactors = FALSE)
dest <- subset(ret, retail_id == opt$retail_id)
if (nrow(dest) != 1) stop("retail_id not found or non-unique: ", opt$retail_id)
dest <- dest[1, , drop = FALSE]

if (nrow(fac) != 2) {
  warning("Expected 2 facilities for fixed-destination cache; found ", nrow(fac))
}

timestamp_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
provider <- tolower(trimws(opt$provider))

osrm_manifest <- list(osrm_docker_image = NA_character_, osrm_version = NA_character_, osm_snapshot_sha256 = NA_character_)
if (provider == "osrm") {
  mpath <- "data/osrm/osrm_snapshot_manifest.json"
  if (file.exists(mpath)) {
    osrm_manifest <- jsonlite::fromJSON(mpath)
  }
}

rows <- vector("list", nrow(fac))
for (i in seq_len(nrow(fac))) {
  o <- fac[i, , drop = FALSE]
  origin <- list(lat = as.numeric(o$lat[[1]]), lon = as.numeric(o$lon[[1]]))
  d <- list(lat = as.numeric(dest$lat[[1]]), lon = as.numeric(dest$lon[[1]]))
  if (!all(is.finite(unlist(origin))) || !all(is.finite(unlist(d)))) {
    stop("Missing lat/lon in facilities or retail nodes.")
  }

  route <- if (provider == "osrm") {
    compute_route_km("osrm", origin, d, profile = opt$profile, osrm_base_url = opt$osrm_base_url)
  } else if (provider == "google") {
    compute_route_km(
      "google", origin, d,
      profile = opt$profile,
      travel_mode = opt$travel_mode,
      routing_preference = opt$routing_preference,
      compute_alternatives = FALSE
    )
  } else {
    stop("Unsupported provider: ", provider)
  }

  rows[[i]] <- data.frame(
    facility_id = as.character(o$facility_id[[1]]),
    retail_id = as.character(dest$retail_id[[1]]),
    distance_km = as.numeric(route$distance_km),
    duration_min = as.numeric(route$duration_min),
    provider = provider,
    profile = opt$profile,
    timestamp_utc = timestamp_utc,
    osrm_docker_image = if (provider == "osrm") osrm_manifest$osrm_docker_image else NA_character_,
    osrm_version = if (provider == "osrm") osrm_manifest$osrm_version else NA_character_,
    osm_snapshot_sha256 = if (provider == "osrm") osrm_manifest$osm_snapshot_sha256 else NA_character_,
    google_routes_api_identifier = if (provider == "google") route$meta$endpoint else NA_character_,
    travel_mode = if (provider == "google") opt$travel_mode else NA_character_,
    routing_preference = if (provider == "google") opt$routing_preference else NA_character_,
    request_fingerprint_sha256 = digest::digest(jsonlite::toJSON(route$meta, auto_unbox = TRUE), algo = "sha256", serialize = FALSE),
    status = "OK",
    stringsAsFactors = FALSE
  )
}

out <- do.call(rbind, rows)
if (any(!is.finite(out$distance_km)) || any(out$distance_km <= 0)) stop("Distance computation failed for one or more rows.")
if (any(!is.finite(out$duration_min)) || any(out$duration_min <= 0)) stop("Duration computation failed for one or more rows.")

dir.create(dirname(opt$output), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, opt$output, row.names = FALSE)
cat("Wrote", opt$output, "\n")
