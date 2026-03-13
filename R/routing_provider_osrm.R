.osrm_route_url <- function(base_url, origin, dest, profile = "driving") {
  base <- sub("/$", "", base_url)
  # Use %3B instead of ';' separator to avoid shell/CLI tokenization edge cases.
  sprintf(
    "%s/route/v1/%s/%.7f,%.7f%%3B%.7f,%.7f?overview=full&geometries=polyline&steps=false",
    base, profile, origin$lon, origin$lat, dest$lon, dest$lat
  )
}

compute_route_osrm <- function(origin, dest, profile = "driving", osrm_base_url = "http://127.0.0.1:5000") {
  url <- .osrm_route_url(osrm_base_url, origin = origin, dest = dest, profile = profile)
  body_file <- tempfile(fileext = ".json")
  on.exit(unlink(body_file), add = TRUE)
  err <- suppressWarnings(system2("curl", c("-sS", "--fail", url, "-o", body_file), stdout = TRUE, stderr = TRUE))
  code <- attr(err, "status")
  if (!is.null(code) && code != 0) {
    stop("OSRM route request failed (curl exit=", code, "): ", paste(err, collapse = "\n"))
  }
  if (!file.exists(body_file) || file.info(body_file)$size <= 0) {
    stop("OSRM route request returned empty response.")
  }
  js <- jsonlite::fromJSON(paste(readLines(body_file, warn = FALSE), collapse = "\n"))
  if (is.null(js$routes) || length(js$routes) < 1) {
    stop("OSRM returned no routes.")
  }
  r <- js$routes[[1]]
  distance_km <- as.numeric(r$distance) / 1000
  duration_min <- as.numeric(r$duration) / 60
  list(
    distance_km = distance_km,
    duration_min = duration_min,
    polyline = if (!is.null(r$geometry)) as.character(r$geometry) else NA_character_,
    meta = list(
      provider = "osrm",
      profile = profile,
      osrm_base_url = osrm_base_url,
      code = if (!is.null(js$code)) as.character(js$code) else NA_character_
    )
  )
}
