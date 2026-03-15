#!/usr/bin/env Rscript
#
# DEPRECATED — 2026-03-15
#
# This R script used system2("curl", ...) to call the Google Routes API.
# R's system2() mangles multi-word HTTP headers: "Authorization: Bearer <token>"
# gets split so "Bearer" is treated as a hostname, producing 403 errors.
#
# Use the shell replacement instead:
#   bash tools/route_precompute_google.sh --routing_preference TRAFFIC_AWARE_OPTIMAL
#
# The shell script also adds traffic-aware routing support (duration_s_static).

stop(paste(
  "tools/route_precompute_google.R is DEPRECATED due to R system2() header mangling",
  "causing 403 errors with the Google Routes API.",
  "",
  "Use the shell replacement:",
  "  bash tools/route_precompute_google.sh \\",
  "    --routing_preference TRAFFIC_AWARE_OPTIMAL \\",
  "    --output data/derived/routes_facility_to_petco.csv",
  "",
  "See tools/route_precompute_google.sh header for full usage.",
  sep = "\n"
))

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(digest)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--retail_id"), type = "character", default = "PETCO_DAVIS_COVELL"),
  make_option(c("--route_alts"), type = "integer", default = 3L),
  make_option(c("--travel_mode"), type = "character", default = "DRIVE"),
  make_option(c("--routing_preference"), type = "character", default = "TRAFFIC_UNAWARE"),
  make_option(c("--output"), type = "character", default = "data/derived/routes_facility_to_petco.csv")
)
opt <- parse_args(OptionParser(option_list = option_list))

api_key <- Sys.getenv("GOOGLE_MAPS_API_KEY", "")
if (!nzchar(api_key)) stop("GOOGLE_MAPS_API_KEY is required.")

fac <- utils::read.csv("data/inputs_local/facilities.csv", stringsAsFactors = FALSE)
ret <- utils::read.csv("data/inputs_local/retail_nodes.csv", stringsAsFactors = FALSE)
dest <- subset(ret, retail_id == opt$retail_id)
if (nrow(dest) != 1) stop("Retail node not found: ", opt$retail_id)
dest <- dest[1, , drop = FALSE]

endpoint_base <- "https://routes.googleapis.com/directions/v2:computeRoutes"
endpoint <- paste0(endpoint_base, "?key=", utils::URLencode(api_key, reserved = TRUE))
rows <- list()

curl_json <- function(args, context) {
  debug <- identical(Sys.getenv("ROUTING_DEBUG", "0"), "1")
  if (debug) {
    show_args <- args
    show_args <- gsub("(key=)[^&]+", "\\1REDACTED", show_args)
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

for (i in seq_len(nrow(fac))) {
  o <- fac[i, , drop = FALSE]
  body <- list(
    origin = list(location = list(latLng = list(latitude = as.numeric(o$lat[[1]]), longitude = as.numeric(o$lon[[1]])))),
    destination = list(location = list(latLng = list(latitude = as.numeric(dest$lat[[1]]), longitude = as.numeric(dest$lon[[1]])))),
    travelMode = opt$travel_mode,
    routingPreference = opt$routing_preference,
    computeAlternativeRoutes = isTRUE(opt$route_alts > 1),
    languageCode = "en-US",
    units = "METRIC"
  )

  tmp <- tempfile(fileext = ".json")
  body_json <- jsonlite::toJSON(body, auto_unbox = TRUE)
  writeLines(body_json, tmp)
  if (identical(Sys.getenv("ROUTING_DEBUG", "0"), "1")) {
    cat("[routing-debug] request body:\n", body_json, "\n")
  }
  js <- curl_json(
    c(
      "-sS", "-X", "POST", endpoint,
      "-H", "X-Goog-FieldMask:routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline",
      "-H", "Content-Type:application/json",
      "--data-binary", paste0("@", tmp)
    ),
    context = paste0("Google Routes request for facility_id=", o$facility_id[[1]])
  )
  unlink(tmp)
  if (is.null(js$routes)) stop("No routes for facility: ", o$facility_id[[1]])
  routes <- js$routes
  if (is.data.frame(routes)) {
    dist_vec <- suppressWarnings(as.numeric(unlist(routes$distanceMeters)))
    dur_vec <- suppressWarnings(as.numeric(sub("s$", "", as.character(unlist(routes$duration)))))
    poly_vec <- rep(NA_character_, length(dist_vec))

    if ("polyline.encodedPolyline" %in% names(routes)) {
      pv <- as.character(unlist(routes[["polyline.encodedPolyline"]]))
      poly_vec[seq_len(min(length(poly_vec), length(pv)))] <- pv[seq_len(min(length(poly_vec), length(pv)))]
    } else if ("polyline" %in% names(routes)) {
      pcol <- routes$polyline
      if (is.data.frame(pcol) && "encodedPolyline" %in% names(pcol)) {
        pv <- as.character(unlist(pcol$encodedPolyline))
        poly_vec[seq_len(min(length(poly_vec), length(pv)))] <- pv[seq_len(min(length(poly_vec), length(pv)))]
      } else if (is.list(pcol)) {
        pv <- vapply(pcol, function(p) {
          if (is.list(p) && !is.null(p$encodedPolyline)) as.character(p$encodedPolyline) else NA_character_
        }, character(1))
        poly_vec[seq_len(min(length(poly_vec), length(pv)))] <- pv[seq_len(min(length(poly_vec), length(pv)))]
      }
    }

    keep <- is.finite(dist_vec) & is.finite(dur_vec)
    dist_vec <- dist_vec[keep]
    dur_vec <- dur_vec[keep]
    poly_vec <- poly_vec[keep]
    if (length(dist_vec) < 1) stop("No routes for facility: ", o$facility_id[[1]])

    get_dist <- function(k) dist_vec[[k]]
    get_dur <- function(k) dur_vec[[k]]
    get_poly <- function(k) poly_vec[[k]]
    n_routes <- length(dist_vec)
  } else if (is.list(routes) && length(routes) >= 1) {
    get_dist <- function(k) suppressWarnings(as.numeric(routes[[k]]$distanceMeters))
    get_dur <- function(k) suppressWarnings(as.numeric(sub("s$", "", as.character(routes[[k]]$duration))))
    get_poly <- function(k) {
      r <- routes[[k]]
      if (!is.null(r$polyline$encodedPolyline)) return(as.character(r$polyline$encodedPolyline))
      NA_character_
    }
    n_routes <- length(routes)
  } else {
    stop("Unrecognized routes payload for facility: ", o$facility_id[[1]])
  }

  n_take <- min(max(as.integer(opt$route_alts), 1L), n_routes)
  for (k in seq_len(n_take)) {
    dist_m <- get_dist(k)
    dur_s <- get_dur(k)
    poly <- get_poly(k)
    route_id <- digest::digest(paste(o$facility_id[[1]], dest$retail_id[[1]], poly, sep = "|"), algo = "sha256", serialize = FALSE)

    rows[[length(rows) + 1]] <- data.frame(
      route_id = route_id,
      facility_id = as.character(o$facility_id[[1]]),
      retail_id = as.character(dest$retail_id[[1]]),
      route_rank = k,
      distance_m = dist_m,
      duration_s = dur_s,
      encoded_polyline = poly,
      provider = "google_routes",
      travel_mode = opt$travel_mode,
      routing_preference = opt$routing_preference,
      endpoint = endpoint_base,
      timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      stringsAsFactors = FALSE
    )
  }
}

out <- do.call(rbind, rows)
out <- out[order(out$facility_id, out$route_rank), , drop = FALSE]
dir.create(dirname(opt$output), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, opt$output, row.names = FALSE)
cat("Wrote", opt$output, "\n")
