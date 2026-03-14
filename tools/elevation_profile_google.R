#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

redact_key <- function(x) gsub("(key=)[^&]+", "\\1REDACTED", x)

curl_json <- function(args, context) {
  debug <- identical(Sys.getenv("ROUTING_DEBUG", "0"), "1")
  if (debug) {
    show_args <- args
    show_args <- vapply(show_args, function(a) if (grepl("^https?://", a)) redact_key(a) else a, character(1))
    cat("[routing-debug] context:", context, "\n")
    cat("[routing-debug] curl args:\n", paste(show_args, collapse = " "), "\n")
  }
  body_file <- tempfile(fileext = ".json")
  on.exit(unlink(body_file), add = TRUE)
  out <- suppressWarnings(system2("curl", c(args, "-o", body_file, "-w", "%{http_code}"), stdout = TRUE, stderr = TRUE))
  code <- attr(out, "status")
  http_code <- suppressWarnings(as.integer(tail(out, 1)))
  err <- paste(head(out, -1), collapse = "\n")
  if (!is.null(code) && code != 0) stop(context, " failed (curl exit=", code, "): ", err)
  if (!file.exists(body_file) || file.info(body_file)$size <= 0) stop(context, " returned empty response.")
  body_txt <- paste(readLines(body_file, warn = FALSE), collapse = "\n")
  if (is.finite(http_code) && http_code >= 400) stop(context, " failed (http=", http_code, "): ", body_txt)
  jsonlite::fromJSON(body_txt)
}

sample_along_polyline <- function(poly_df, sample_m = 250) {
  seg <- polyline_to_segments(poly_df)
  if (nrow(seg) == 0) return(data.frame(s_m = numeric(), lat = numeric(), lon = numeric()))
  total <- max(seg$cumulative_m)
  targets <- seq(0, total, by = sample_m)
  if (tail(targets, 1) < total) targets <- c(targets, total)

  out <- vector("list", length(targets))
  for (i in seq_along(targets)) {
    t <- targets[[i]]
    j <- which(seg$cumulative_m >= t)[1]
    prev_c <- if (j == 1) 0 else seg$cumulative_m[[j - 1]]
    frac <- if (seg$segment_m[[j]] > 0) (t - prev_c) / seg$segment_m[[j]] else 0
    lat <- seg$lat1[[j]] + frac * (seg$lat2[[j]] - seg$lat1[[j]])
    lon <- seg$lon1[[j]] + frac * (seg$lon2[[j]] - seg$lon1[[j]])
    out[[i]] <- data.frame(s_m = t, lat = lat, lon = lon, stringsAsFactors = FALSE)
  }
  do.call(rbind, out)
}

option_list <- list(
  make_option(c("--routes"), type = "character", default = "data/derived/routes_facility_to_petco.csv"),
  make_option(c("--sample_m"), type = "integer", default = 250L),
  make_option(c("--batch_points"), type = "integer", default = 80L),
  make_option(c("--output"), type = "character", default = "data/derived/route_elevation_profiles.csv")
)
opt <- parse_args(OptionParser(option_list = option_list))
api_key <- Sys.getenv("GOOGLE_MAPS_API_KEY", "")
if (!nzchar(api_key)) stop("GOOGLE_MAPS_API_KEY is required.")

routes <- utils::read.csv(opt$routes, stringsAsFactors = FALSE)
if (nrow(routes) == 0) stop("No routes found: ", opt$routes)

rows <- list()
for (i in seq_len(nrow(routes))) {
  r <- routes[i, , drop = FALSE]
  poly_df <- decode_polyline(as.character(r$encoded_polyline[[1]]))
  sampled <- sample_along_polyline(poly_df, sample_m = as.integer(opt$sample_m))
  if (nrow(sampled) == 0) next

  endpoint <- "https://maps.googleapis.com/maps/api/elevation/json"
  batch_n <- max(1L, as.integer(opt$batch_points))
  elev <- rep(NA_real_, nrow(sampled))
  starts <- seq(1L, nrow(sampled), by = batch_n)
  for (s in starts) {
    e <- min(s + batch_n - 1L, nrow(sampled))
    chunk <- sampled[s:e, , drop = FALSE]
    locs <- paste(sprintf("%.6f,%.6f", chunk$lat, chunk$lon), collapse = "|")
    url <- paste0(endpoint, "?locations=", utils::URLencode(locs, reserved = TRUE), "&key=", api_key)
    js <- curl_json(c("-sS", "--fail", url), context = paste0("Google Elevation request route_id=", r$route_id[[1]], " chunk=", s, "-", e))
    if (!identical(js$status, "OK")) stop("Elevation API failed for route_id=", r$route_id[[1]])
    vals <- as.numeric(js$results$elevation)
    if (length(vals) != nrow(chunk)) stop("Elevation result length mismatch for route_id=", r$route_id[[1]])
    elev[s:e] <- vals
    Sys.sleep(0.1)
  }
  if (any(!is.finite(elev))) stop("Missing elevation values for route_id=", r$route_id[[1]])

  rows[[length(rows) + 1]] <- data.frame(
    route_id = as.character(r$route_id[[1]]),
    s_m = sampled$s_m,
    lat = sampled$lat,
    lon = sampled$lon,
    elev_m = elev,
    provider = "google_elevation",
    sample_m = as.integer(opt$sample_m),
    timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors = FALSE
  )
}

out <- do.call(rbind, rows)
dir.create(dirname(opt$output), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, opt$output, row.names = FALSE)
cat("Wrote", opt$output, "\n")
