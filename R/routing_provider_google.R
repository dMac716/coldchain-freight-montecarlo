.google_duration_to_seconds <- function(x) {
  if (is.null(x) || is.na(x) || !nzchar(x)) return(NA_real_)
  as.numeric(sub("s$", "", as.character(x)))
}

.normalize_google_api_key <- function(api_key) {
  k <- as.character(api_key)
  k <- trimws(k)
  k <- gsub("[\"']", "", k)
  k <- gsub("[[:space:]]+", "", k)
  if (!nzchar(k)) stop("GOOGLE_MAPS_API_KEY is required for provider=google.")
  k
}

.redact_key_in_url <- function(url) {
  gsub("(key=)[^&]+", "\\1REDACTED", url)
}

.curl_json <- function(args, context = "HTTP request", body_json = NULL) {
  debug <- identical(Sys.getenv("ROUTING_DEBUG", "0"), "1")
  if (debug) {
    cat("[routing-debug] context:", context, "\n")
    show_args <- args
    for (i in seq_along(show_args)) {
      if (grepl("^https?://", show_args[[i]])) show_args[[i]] <- .redact_key_in_url(show_args[[i]])
    }
    cat("[routing-debug] curl args:\n", paste(show_args, collapse = " "), "\n")
    if (!is.null(body_json)) cat("[routing-debug] request body:\n", body_json, "\n")
  }

  body_file <- tempfile(fileext = ".json")
  on.exit(unlink(body_file), add = TRUE)
  out <- suppressWarnings(system2("curl", c(args, "-o", body_file, "-w", "%{http_code}"), stdout = TRUE, stderr = TRUE))
  curl_exit <- attr(out, "status")
  http_code <- suppressWarnings(as.integer(tail(out, 1)))
  err_txt <- paste(head(out, -1), collapse = "\n")
  if (!is.null(curl_exit) && curl_exit != 0) {
    stop(context, " failed (curl exit=", curl_exit, "): ", err_txt)
  }

  if (!file.exists(body_file) || file.info(body_file)$size <= 0) {
    stop(context, " returned empty response body.")
  }
  body_txt <- paste(readLines(body_file, warn = FALSE), collapse = "\n")
  if (is.finite(http_code) && http_code >= 400) {
    stop(context, " failed (http=", http_code, "): ", body_txt)
  }
  jsonlite::fromJSON(body_txt)
}

compute_route_google <- function(
    origin,
    dest,
    profile = "driving",
    travel_mode = "DRIVE",
    routing_preference = "TRAFFIC_UNAWARE",
    compute_alternatives = FALSE,
    api_key = Sys.getenv("GOOGLE_MAPS_API_KEY", "")) {
  api_key <- .normalize_google_api_key(api_key)

  endpoint_base <- "https://routes.googleapis.com/directions/v2:computeRoutes"
  endpoint <- paste0(
    endpoint_base,
    "?key=", utils::URLencode(api_key, reserved = TRUE)
  )
  body <- list(
    origin = list(location = list(latLng = list(latitude = as.numeric(origin$lat), longitude = as.numeric(origin$lon)))),
    destination = list(location = list(latLng = list(latitude = as.numeric(dest$lat), longitude = as.numeric(dest$lon)))),
    travelMode = travel_mode,
    routingPreference = routing_preference,
    computeAlternativeRoutes = isTRUE(compute_alternatives),
    languageCode = "en-US",
    units = "METRIC"
  )

  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp), add = TRUE)
  body_json <- jsonlite::toJSON(body, auto_unbox = TRUE)
  writeLines(body_json, tmp)

  cmd <- c(
    "-sS", "-X", "POST", endpoint,
    "-H", "X-Goog-FieldMask:routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline",
    "-H", "Content-Type:application/json",
    "--data-binary", paste0("@", tmp)
  )
  js <- .curl_json(cmd, context = "Google Routes request", body_json = body_json)
  if (is.null(js$routes)) stop("Google Routes returned no routes.")

  routes <- js$routes
  if (is.data.frame(routes)) {
    if (nrow(routes) < 1) stop("Google Routes returned no routes.")
    dist_m <- suppressWarnings(as.numeric(routes$distanceMeters[[1]]))
    dur_s <- .google_duration_to_seconds(routes$duration[[1]])
    poly <- NA_character_
    if ("polyline.encodedPolyline" %in% names(routes)) {
      poly <- as.character(routes[["polyline.encodedPolyline"]][[1]])
    } else if ("polyline" %in% names(routes)) {
      p <- routes$polyline[[1]]
      if (is.list(p) && !is.null(p$encodedPolyline)) poly <- as.character(p$encodedPolyline)
    }
  } else if (is.list(routes) && length(routes) >= 1) {
    r <- routes[[1]]
    dist_m <- suppressWarnings(as.numeric(r$distanceMeters))
    dur_s <- .google_duration_to_seconds(r$duration)
    poly <- if (!is.null(r$polyline$encodedPolyline)) as.character(r$polyline$encodedPolyline) else NA_character_
  } else {
    stop("Google Routes returned unrecognized routes payload.")
  }

  list(
    distance_km = dist_m / 1000,
    duration_min = dur_s / 60,
    polyline = poly,
    meta = list(
      provider = "google",
      profile = profile,
      endpoint = endpoint_base,
      travel_mode = travel_mode,
      routing_preference = routing_preference,
      field_mask = "default_response_fields"
    )
  )
}
