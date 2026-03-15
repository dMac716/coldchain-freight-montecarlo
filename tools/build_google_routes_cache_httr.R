#!/usr/bin/env Rscript

# =============================================================================
# DEPRECATED — DO NOT USE FOR PRODUCTION CACHE GENERATION
# =============================================================================
# This script was superseded by tools/build_google_routes_cache_traffic.sh.
#
# Root cause: httr POST requests to the Google Routes v2 endpoint returned 403
# errors. Direct shell curl with explicit Authorization + X-Goog-Api-Key +
# X-Goog-User-Project headers is the only path validated to return 200s.
#
# Additionally, this script does not emit road_duration_minutes_static or
# routing_preference columns required by the bootstrap QA gate.
#
# See build_google_routes_cache.R header for the full production workflow,
# or run: bash tools/run_google_routes_cache_pipeline.sh
# =============================================================================

stop(paste0(
  "build_google_routes_cache_httr.R is DEPRECATED and must not be used for production cache generation.\n",
  "The httr path produces 403 errors from the Google Routes v2 endpoint.\n",
  "Use tools/build_google_routes_cache_traffic.sh instead."
))


# Define command-line options
option_list <- list(
  make_option(c("--flows_csv"), type = "character", default = "data/derived/faf_top_od_flows.csv"),
  make_option(c("--zones_csv"), type = "character", default = "data/derived/faf_zone_centroids.csv"),
  make_option(c("--out_cache_csv"), type = "character", default = "data/derived/google_routes_od_cache.csv"),
  make_option(c("--out_dist_csv"), type = "character", default = "data/derived/google_routes_distance_distributions.csv"),
  make_option(c("--out_meta_json"), type = "character", default = "data/derived/google_routes_metadata.json"),
  make_option(c("--api_key"), type = "character", default = ""),
  make_option(c("--auth_mode"), type = "character", default = "auto", help = "Auth mode: auto|oauth|api_key (default: auto; prefers OAuth)."),
  make_option(c("--user_project"), type = "character", default = "", help = "Billing/quota project for OAuth requests (used in X-Goog-User-Project)."),
  make_option(c("--max_pairs"), type = "integer", default = 400L),
  make_option(c("--sleep_ms"), type = "integer", default = 0L),
  make_option(c("--dry_run"), action = "store_true", default = FALSE)
)

opt <- parse_args(OptionParser(
  usage = "%prog [options]",
  description = "Build cached road-distance OD table and simulation distance distributions using Google Routes API (httr implementation).",
  option_list = option_list
))

# Helper functions
log_info <- function(...) message("[google_routes_httr] ", paste0(..., collapse = ""))

weighted_quantile <- function(x, w, probs) {
  # Compute weighted quantiles analogous to the R version
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
  ""
}

service_account_info <- function() {
  cred_path <- trimws(Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS", unset = ""))
  if (!nzchar(cred_path)) {
    return(list(is_set = FALSE, path = "", is_valid = FALSE, reason = "not_set"))
  }
  if (!file.exists(cred_path)) {
    return(list(is_set = TRUE, path = cred_path, is_valid = FALSE, reason = "missing_file"))
  }
  cred_json <- tryCatch(fromJSON(cred_path, simplifyVector = TRUE), error = function(e) NULL)
  if (is.null(cred_json)) {
    return(list(is_set = TRUE, path = cred_path, is_valid = FALSE, reason = "invalid_json"))
  }
  cred_type <- if (!is.null(cred_json$type)) trimws(as.character(cred_json$type[[1]])) else ""
  if (!identical(cred_type, "service_account")) {
    return(list(is_set = TRUE, path = cred_path, is_valid = FALSE, reason = "wrong_type"))
  }
  list(is_set = TRUE, path = cred_path, is_valid = TRUE, reason = "ok")
}

oauth_error_message <- function(sa_info, details = character()) {
  detail_txt <- trimws(paste(details[nzchar(details)], collapse = " | "))
  if (isTRUE(sa_info$is_set) && !isTRUE(sa_info$is_valid)) {
    if (identical(sa_info$reason, "missing_file")) {
      return(paste0("GOOGLE_APPLICATION_CREDENTIALS is set but file was not found: ", sa_info$path))
    }
    if (identical(sa_info$reason, "invalid_json")) {
      return(paste0("GOOGLE_APPLICATION_CREDENTIALS must point to a valid service-account JSON file: ", sa_info$path))
    }
    if (identical(sa_info$reason, "wrong_type")) {
      return(paste0("GOOGLE_APPLICATION_CREDENTIALS must point to a service-account JSON file (type=service_account): ", sa_info$path))
    }
  }
  hint <- if (isTRUE(sa_info$is_set)) {
    "Activate service-account credentials first: gcloud auth activate-service-account --key-file=\"$GOOGLE_APPLICATION_CREDENTIALS\"."
  } else {
    "Set GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON and activate it with: gcloud auth activate-service-account --key-file=\"$GOOGLE_APPLICATION_CREDENTIALS\"."
  }
  paste0(
    "Unable to obtain Google OAuth access token for Routes API. ",
    hint,
    if (nzchar(detail_txt)) paste0(" gcloud details: ", detail_txt) else ""
  )
}

run_gcloud_token_cmd <- function(args) {
  if (!nzchar(Sys.which("gcloud"))) {
    return(list(ok = FALSE, token = "", detail = "gcloud not found on PATH"))
  }
  out <- suppressWarnings(system2("gcloud", args, stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (is.null(status)) status <- 0L
  token <- if (length(out) > 0) trimws(out[[length(out)]]) else ""
  if (identical(status, 0L) && nzchar(token)) {
    return(list(ok = TRUE, token = token, detail = ""))
  }
  detail <- trimws(paste(out, collapse = "\n"))
  if (!nzchar(detail)) detail <- "no output"
  list(ok = FALSE, token = "", detail = detail)
}

run_gcloud_value_cmd <- function(args) {
  if (!nzchar(Sys.which("gcloud"))) {
    return(list(ok = FALSE, value = "", detail = "gcloud not found on PATH"))
  }
  out <- suppressWarnings(system2("gcloud", args, stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (is.null(status)) status <- 0L
  lines <- trimws(out)
  lines <- lines[nzchar(lines)]
  value <- if (length(lines) > 0) lines[[length(lines)]] else ""
  if (identical(value, "(unset)")) value <- ""
  detail <- trimws(paste(out, collapse = "\n"))
  if (!nzchar(detail)) detail <- "no output"
  list(ok = identical(status, 0L) && nzchar(value), value = value, detail = detail)
}

get_oauth_access_token <- function(required = TRUE, sa_info = service_account_info()) {
  attempts <- list(
    list(label = "gcloud auth application-default print-access-token", args = c("auth", "application-default", "print-access-token")),
    list(label = "gcloud auth print-access-token", args = c("auth", "print-access-token"))
  )
  details <- character()
  for (a in attempts) {
    res <- run_gcloud_token_cmd(a$args)
    if (isTRUE(res$ok)) return(list(ok = TRUE, token = res$token, error = ""))
    first_line <- strsplit(as.character(res$detail), "\n", fixed = TRUE)[[1]][1]
    details <- c(details, paste0(a$label, ": ", trimws(first_line)))
  }
  msg <- oauth_error_message(sa_info = sa_info, details = details)
  if (isTRUE(required)) stop(msg)
  list(ok = FALSE, token = "", error = msg)
}

get_user_project <- function(user_project_arg = "", required = TRUE) {
  user_project <- trimws(user_project_arg)
  if (nzchar(user_project)) {
    return(list(ok = TRUE, value = user_project, source = "arg", error = ""))
  }
  for (env_name in c("GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT")) {
    user_project <- trimws(Sys.getenv(env_name, unset = ""))
    if (nzchar(user_project)) {
      return(list(ok = TRUE, value = user_project, source = env_name, error = ""))
    }
  }
  cfg <- run_gcloud_value_cmd(c("config", "get-value", "project", "--quiet"))
  if (isTRUE(cfg$ok)) {
    return(list(ok = TRUE, value = cfg$value, source = "gcloud_config", error = ""))
  }
  msg <- paste0(
    "Unable to determine Google quota project for OAuth. Provide --user_project, ",
    "set GOOGLE_CLOUD_PROJECT or GCLOUD_PROJECT, or run `gcloud config set project <PROJECT_ID>`."
  )
  if (isTRUE(required)) stop(msg)
  list(ok = FALSE, value = "", source = "", error = msg)
}

# Resolve authentication: choose OAuth or API key and possibly both
resolve_auth <- function(auth_mode, user_project = "", dry_run = FALSE) {
  mode <- tolower(trimws(auth_mode))
  if (!mode %in% c("auto", "oauth", "api_key")) {
    stop("--auth_mode must be one of: auto, oauth, api_key")
  }
  if (isTRUE(dry_run)) {
    return(list(mode_requested = mode, mode_used = "dry_run", auth_header = character(0), user_project = ""))
  }
  sa_info <- service_account_info()
  fallback_missing_api_key <- "API-key fallback is unavailable because GOOGLE_MAPS_API_KEY/--api_key is not set."
  # If explicitly API key
  if (identical(mode, "api_key")) {
    api_key <- get_api_key()
    if (!nzchar(api_key)) {
      stop("Missing API key. Provide --api_key or set GOOGLE_MAPS_API_KEY.")
    }
    return(list(mode_requested = mode, mode_used = "api_key", auth_header = paste0("X-Goog-Api-Key: ", api_key), user_project = ""))
  }
  # If explicitly OAuth
  if (identical(mode, "oauth")) {
    if (isTRUE(sa_info$is_set) && !isTRUE(sa_info$is_valid)) {
      stop(oauth_error_message(sa_info = sa_info))
    }
    oauth <- get_oauth_access_token(required = TRUE, sa_info = sa_info)
    project <- get_user_project(user_project_arg = user_project, required = TRUE)
    # include API key if available
    api_key <- get_api_key()
    hdrs <- c(paste0("Authorization: Bearer ", oauth$token))
    if (nzchar(api_key)) hdrs <- c(hdrs, paste0("X-Goog-Api-Key: ", api_key))
    return(list(
      mode_requested = mode,
      mode_used = "oauth",
      auth_header = hdrs,
      user_project = project$value
    ))
  }
  # mode auto
  if (isTRUE(sa_info$is_set) && !isTRUE(sa_info$is_valid)) {
    api_key <- get_api_key()
    if (nzchar(api_key)) {
      log_info("GOOGLE_APPLICATION_CREDENTIALS is invalid; using API-key fallback auth.")
      return(list(mode_requested = mode, mode_used = "api_key", auth_header = paste0("X-Goog-Api-Key: ", api_key), user_project = ""))
    }
    stop(oauth_error_message(sa_info = sa_info))
  }
  oauth <- get_oauth_access_token(required = FALSE, sa_info = sa_info)
  if (isTRUE(oauth$ok)) {
    project <- get_user_project(user_project_arg = user_project, required = FALSE)
    if (isTRUE(project$ok)) {
      api_key <- get_api_key()
      hdrs <- c(paste0("Authorization: Bearer ", oauth$token))
      if (nzchar(api_key)) hdrs <- c(hdrs, paste0("X-Goog-Api-Key: ", api_key))
      return(list(
        mode_requested = mode,
        mode_used = "oauth",
        auth_header = hdrs,
        user_project = project$value
      ))
    }
    api_key <- get_api_key()
    if (nzchar(api_key)) {
      log_info("OAuth token available but user project is missing; using API-key fallback auth.")
      return(list(mode_requested = mode, mode_used = "api_key", auth_header = paste0("X-Goog-Api-Key: ", api_key), user_project = ""))
    }
    stop(paste0(project$error, " ", fallback_missing_api_key))
  }
  api_key <- get_api_key()
  if (nzchar(api_key)) {
    log_info("OAuth unavailable; using API-key fallback auth.")
    return(list(mode_requested = mode, mode_used = "api_key", auth_header = paste0("X-Goog-Api-Key: ", api_key), user_project = ""))
  }
  stop(paste0(oauth$error, " ", fallback_missing_api_key))
}

# Function to call the Routes API using httr
call_route_httr <- function(lat1, lon1, lat2, lon2, auth_header, user_project = "") {
  # Build body list for JSON encoding
  body <- list(
    origin = list(location = list(latLng = list(latitude = lat1, longitude = lon1))),
    destination = list(location = list(latLng = list(latitude = lat2, longitude = lon2))),
    travelMode = "DRIVE",
    routingPreference = "TRAFFIC_UNAWARE",
    units = "IMPERIAL"
  )
  # Set up headers
  hdrs <- c(
    `X-Goog-FieldMask` = "routes.distanceMeters,routes.duration",
    `Content-Type` = "application/json"
  )
  if (nzchar(user_project)) {
    hdrs <- c(hdrs, `X-Goog-User-Project` = user_project)
  }
  # Parse auth_header vector
  if (length(auth_header) > 0) {
    for (h in auth_header) {
      if (startsWith(h, "Authorization:")) {
        val <- trimws(sub("Authorization:", "", h))
        # value should be "Bearer <token>"
        hdrs <- c(hdrs, Authorization = val)
      } else if (startsWith(h, "X-Goog-Api-Key:")) {
        val <- trimws(sub("X-Goog-Api-Key:", "", h))
        hdrs <- c(hdrs, `X-Goog-Api-Key` = val)
      }
    }
  }
  url <- "https://routes.googleapis.com/directions/v2:computeRoutes"
  # Send POST request with JSON body
  res <- tryCatch(
    httr::POST(
      url = url,
      body = body,
      encode = "json",
      httr::add_headers(.headers = hdrs)
    ),
    error = function(e) {
      return(structure(list(status_code = NA_integer_, error = as.character(e)), class = "response"))
    }
  )
  # Check for HTTP error
  if (is.null(res) || is.na(res$status_code) || res$status_code >= 400) {
    err <- if (!is.null(res$error)) res$error else tryCatch(httr::content(res, as = "text", encoding = "UTF-8"), error = function(e) "")
    return(list(ok = FALSE, miles = NA_real_, minutes = NA_real_, error = err))
  }
  # Parse JSON content
  content <- tryCatch(httr::content(res, as = "parsed", type = "application/json"), error = function(e) NULL)
  if (is.null(content) || is.null(content$routes) || length(content$routes) == 0) {
    return(list(ok = FALSE, miles = NA_real_, minutes = NA_real_, error = "No routes returned"))
  }
  r0 <- content$routes[[1]]
  dm <- suppressWarnings(as.numeric(r0$distanceMeters))
  dur <- suppressWarnings(as.numeric(sub("s$", "", as.character(r0$duration))))
  if (!is.finite(dm)) {
    return(list(ok = FALSE, miles = NA_real_, minutes = NA_real_, error = "Missing distanceMeters"))
  }
  list(ok = TRUE, miles = dm / 1609.344, minutes = if (is.finite(dur)) dur / 60 else NA_real_, error = "")
}

# Main script body
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

# Build OD pairs
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

auth <- resolve_auth(opt$auth_mode, user_project = opt$user_project, dry_run = isTRUE(opt$dry_run))

out_list <- vector("list", nrow(od))
for (i in seq_len(nrow(od))) {
  row <- od[i, , drop = FALSE]
  if (isTRUE(opt$dry_run)) {
    out_list[[i]] <- data.frame(
      origin_id = row$origin_id, dest_id = row$dest_id,
      road_distance_miles = NA_real_, road_duration_minutes = NA_real_,
      status = "DRY_RUN", error = "", stringsAsFactors = FALSE
    )
    next
  }
  res <- call_route_httr(
    row$origin_lat,
    row$origin_lon,
    row$dest_lat,
    row$dest_lon,
    auth$auth_header,
    user_project = auth$user_project
  )
  out_list[[i]] <- data.frame(
    origin_id = row$origin_id, dest_id = row$dest_id,
    road_distance_miles = if (isTRUE(res$ok)) res$miles else NA_real_,
    road_duration_minutes = if (isTRUE(res$ok)) res$minutes else NA_real_,
    status = if (isTRUE(res$ok)) "OK" else "ERROR",
    error = if (isTRUE(res$ok)) "" else as.character(res$error),
    stringsAsFactors = FALSE
  )
  if (opt$sleep_ms > 0) Sys.sleep(opt$sleep_ms / 1000)
}
cache <- do.call(rbind, out_list)
cache$generated_at_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
cache$api_provider <- "google_routes_v2_httr"

# Build distance distribution summary
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
    notes = "Weighted by tons from flows and Google Routes API cached OD distances.",
    stringsAsFactors = FALSE
  )
}
dist_df <- if (length(dist_rows) > 0) do.call(rbind, dist_rows) else empty_dist_schema()

# Write output files
dir.create(dirname(opt$out_cache_csv), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(cache, opt$out_cache_csv, row.names = FALSE)
utils::write.csv(dist_df, opt$out_dist_csv, row.names = FALSE)

meta <- list(
  generated_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  api_provider = "google_routes_v2_httr",
  auth_mode_requested = auth$mode_requested,
  auth_mode_used = auth$mode_used,
  user_project = auth$user_project,
  dry_run = isTRUE(opt$dry_run),
  pairs_requested = nrow(od),
  pairs_ok = sum(cache$status == "OK"),
  pairs_error = sum(cache$status != "OK")
)
writeLines(toJSON(meta, auto_unbox = TRUE, pretty = TRUE), opt$out_meta_json)

log_info("Wrote ", opt$out_cache_csv)
log_info("Wrote ", opt$out_dist_csv)
log_info("Wrote ", opt$out_meta_json)