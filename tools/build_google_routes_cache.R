#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

option_list <- list(
  make_option(c("--flows_csv"), type = "character", default = "data/derived/faf_top_od_flows.csv"),
  make_option(c("--zones_csv"), type = "character", default = "data/derived/faf_zone_centroids.csv"),
  make_option(c("--out_cache_csv"), type = "character", default = "data/derived/google_routes_od_cache.csv"),
  make_option(c("--out_dist_csv"), type = "character", default = "data/derived/google_routes_distance_distributions.csv"),
  make_option(c("--out_meta_json"), type = "character", default = "data/derived/google_routes_metadata.json"),
  make_option(c("--api_key"), type = "character", default = ""),
  make_option(c("--max_pairs"), type = "integer", default = 400L),
  make_option(c("--sleep_ms"), type = "integer", default = 0L),
  make_option(c("--dry_run"), action = "store_true", default = FALSE)
)

opt <- parse_args(OptionParser(
  usage = "%prog [options]",
  description = "Build cached road-distance OD table and simulation distance distributions using Google Routes API.",
  option_list = option_list
))

log_info <- function(...) message("[google_routes] ", paste0(..., collapse = ""))

weighted_quantile <- function(x, w, probs) {
  o <- order(x)
  x <- x[o]; w <- w[o]
  cw <- cumsum(w) / sum(w)
  vapply(probs, function(p) x[which(cw >= p)[1]], numeric(1))
}

distance_id_for_scenario <- function(s) {
  s <- toupper(trimws(s))
  if (s == "CENTRALIZED") return("dist_centralized_food_truck_2024")
  if (s == "REGIONALIZED") return("dist_regionalized_food_truck_2024")
  paste0("dist_", tolower(gsub("[^A-Za-z0-9]+", "_", s)), "_google_routes")
}

empty_dist_schema <- function() {
  data.frame(
    distance_distribution_id = character(),
    scenario_id = character(),
    source_zip = character(),
    commodity_filter = character(),
    mode_filter = character(),
    distance_model = character(),
    p05_miles = numeric(),
    p50_miles = numeric(),
    p95_miles = numeric(),
    mean_miles = numeric(),
    min_miles = numeric(),
    max_miles = numeric(),
    n_records = integer(),
    status = character(),
    source_id = character(),
    notes = character(),
    stringsAsFactors = FALSE
  )
}

get_api_key <- function() {
  key <- trimws(opt$api_key)
  if (nzchar(key)) return(key)
  key <- Sys.getenv("GOOGLE_MAPS_API_KEY", unset = "")
  if (nzchar(key)) return(trimws(key))
  stop("Missing API key. Provide --api_key or set GOOGLE_MAPS_API_KEY.")
}

call_route <- function(lat1, lon1, lat2, lon2, api_key) {
  body <- toJSON(list(
    origin = list(location = list(latLng = list(latitude = lat1, longitude = lon1))),
    destination = list(location = list(latLng = list(latitude = lat2, longitude = lon2))),
    travelMode = "DRIVE",
    routingPreference = "TRAFFIC_UNAWARE",
    units = "IMPERIAL"
  ), auto_unbox = TRUE)
  tf <- tempfile(fileext = ".json")
  writeLines(body, tf)
  on.exit(unlink(tf), add = TRUE)

  args <- c(
    "-sS",
    "-X", "POST",
    "https://routes.googleapis.com/directions/v2:computeRoutes",
    "-H", "Content-Type: application/json",
    "-H", paste0("X-Goog-Api-Key: ", api_key),
    "-H", "X-Goog-FieldMask: routes.distanceMeters,routes.duration",
    "--data-binary", paste0("@", tf)
  )
  out <- system2("curl", args, stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    return(list(ok = FALSE, error = paste(out, collapse = "\n")))
  }
  txt <- paste(out, collapse = "\n")
  obj <- tryCatch(fromJSON(txt, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(obj) || is.null(obj$routes) || length(obj$routes) == 0) {
    return(list(ok = FALSE, error = "No routes returned"))
  }
  r0 <- obj$routes[[1]]
  dm <- suppressWarnings(as.numeric(r0$distanceMeters))
  dur <- suppressWarnings(as.numeric(gsub("s$", "", as.character(r0$duration))))
  if (!is.finite(dm)) return(list(ok = FALSE, error = "Missing distanceMeters"))
  list(ok = TRUE, miles = dm / 1609.344, minutes = if (is.finite(dur)) dur / 60 else NA_real_)
}

if (!file.exists(opt$flows_csv)) stop("Flows CSV not found: ", opt$flows_csv)
if (!file.exists(opt$zones_csv)) stop("Zones CSV not found: ", opt$zones_csv)

flows <- utils::read.csv(opt$flows_csv, stringsAsFactors = FALSE)
zones <- utils::read.csv(opt$zones_csv, stringsAsFactors = FALSE)
for (nm in c("origin_id", "dest_id", "scenario_id", "tons")) {
  if (!(nm %in% names(flows))) stop("flows_csv missing required column: ", nm)
}
for (nm in c("zone_id", "lat", "lon")) {
  if (!(nm %in% names(zones))) stop("zones_csv missing required column: ", nm)
}
zones$zone_id <- as.character(zones$zone_id)
zones$lat <- suppressWarnings(as.numeric(zones$lat))
zones$lon <- suppressWarnings(as.numeric(zones$lon))

od <- unique(flows[, c("origin_id", "dest_id"), drop = FALSE])
if (nrow(od) > opt$max_pairs) od <- od[seq_len(opt$max_pairs), , drop = FALSE]

od$origin_id <- as.character(od$origin_id)
od$dest_id <- as.character(od$dest_id)
o <- zones[match(od$origin_id, zones$zone_id), c("lat", "lon")]
d <- zones[match(od$dest_id, zones$zone_id), c("lat", "lon")]
names(o) <- c("origin_lat", "origin_lon")
names(d) <- c("dest_lat", "dest_lon")
od <- cbind(od, o, d)
od <- od[is.finite(od$origin_lat) & is.finite(od$origin_lon) & is.finite(od$dest_lat) & is.finite(od$dest_lon), , drop = FALSE]

if (nrow(od) == 0) stop("No valid OD pairs after joining zone centroids.")

api_key <- if (isTRUE(opt$dry_run)) "" else get_api_key()
out <- vector("list", nrow(od))
for (i in seq_len(nrow(od))) {
  row <- od[i, , drop = FALSE]
  if (isTRUE(opt$dry_run)) {
    out[[i]] <- data.frame(
      origin_id = row$origin_id, dest_id = row$dest_id,
      road_distance_miles = NA_real_, road_duration_minutes = NA_real_,
      status = "DRY_RUN", error = "", stringsAsFactors = FALSE
    )
    next
  }
  res <- call_route(row$origin_lat, row$origin_lon, row$dest_lat, row$dest_lon, api_key)
  out[[i]] <- data.frame(
    origin_id = row$origin_id, dest_id = row$dest_id,
    road_distance_miles = if (isTRUE(res$ok)) res$miles else NA_real_,
    road_duration_minutes = if (isTRUE(res$ok)) res$minutes else NA_real_,
    status = if (isTRUE(res$ok)) "OK" else "ERROR",
    error = if (isTRUE(res$ok)) "" else as.character(res$error),
    stringsAsFactors = FALSE
  )
  if (opt$sleep_ms > 0) Sys.sleep(opt$sleep_ms / 1000)
}
cache <- do.call(rbind, out)
cache$generated_at_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
cache$api_provider <- "google_routes_v2"

joined <- merge(
  flows[, c("origin_id", "dest_id", "scenario_id", "tons"), drop = FALSE],
  cache[, c("origin_id", "dest_id", "road_distance_miles", "status"), drop = FALSE],
  by = c("origin_id", "dest_id"),
  all.x = FALSE
)
joined$tons <- suppressWarnings(as.numeric(joined$tons))
joined$road_distance_miles <- suppressWarnings(as.numeric(joined$road_distance_miles))
joined <- joined[is.finite(joined$tons) & joined$tons > 0 & is.finite(joined$road_distance_miles), , drop = FALSE]

dist_rows <- list()
for (s in unique(as.character(flows$scenario_id))) {
  x <- joined[joined$scenario_id == s, , drop = FALSE]
  if (nrow(x) == 0) next
  q <- weighted_quantile(x$road_distance_miles, x$tons, probs = c(0.05, 0.5, 0.95))
  mn <- sum(x$road_distance_miles * x$tons) / sum(x$tons)
  dist_rows[[length(dist_rows) + 1]] <- data.frame(
    distance_distribution_id = distance_id_for_scenario(s),
    scenario_id = s,
    source_zip = "google_routes_api_cached_od",
    commodity_filter = "food_sctg_01_08",
    mode_filter = "truck",
    distance_model = "triangular_fit",
    p05_miles = q[[1]], p50_miles = q[[2]], p95_miles = q[[3]],
    mean_miles = mn,
    min_miles = min(x$road_distance_miles, na.rm = TRUE),
    max_miles = max(x$road_distance_miles, na.rm = TRUE),
    n_records = nrow(x),
    status = "OK",
    source_id = "google_routes_api_cached_od",
    notes = "Weighted by tons from faf_top_od_flows.csv and Google Routes API cached OD distances.",
    stringsAsFactors = FALSE
  )
}
dist_df <- if (length(dist_rows) > 0) do.call(rbind, dist_rows) else empty_dist_schema()

dir.create(dirname(opt$out_cache_csv), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(cache, opt$out_cache_csv, row.names = FALSE)
utils::write.csv(dist_df, opt$out_dist_csv, row.names = FALSE)

meta <- list(
  generated_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  api_provider = "google_routes_v2",
  dry_run = isTRUE(opt$dry_run),
  pairs_requested = nrow(od),
  pairs_ok = sum(cache$status == "OK"),
  pairs_error = sum(cache$status != "OK")
)
writeLines(toJSON(meta, auto_unbox = TRUE, pretty = TRUE), opt$out_meta_json)

log_info("Wrote ", opt$out_cache_csv)
log_info("Wrote ", opt$out_dist_csv)
log_info("Wrote ", opt$out_meta_json)
