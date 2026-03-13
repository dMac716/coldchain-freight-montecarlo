#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(digest)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

redact_key <- function(x) {
  x <- gsub("(key=)[^&]+", "\\1REDACTED", x)
  gsub("(X-Goog-Api-Key:\\s*)[^ ]+", "\\1REDACTED", x, ignore.case = TRUE)
}

curl_json <- function(args, context, retries = 3L, body_json = NULL) {
  debug <- identical(Sys.getenv("ROUTING_DEBUG", "0"), "1")
  last_err <- NULL
  for (attempt in seq_len(max(1L, as.integer(retries)))) {
    if (debug) {
      show_args <- args
      show_args <- vapply(show_args, function(a) if (grepl("^https?://", a)) redact_key(a) else a, character(1))
      cat("[routing-debug] context:", context, "attempt=", attempt, "\n")
      cat("[routing-debug] curl args:\n", paste(show_args, collapse = " "), "\n")
      if (!is.null(body_json)) cat("[routing-debug] request body:\n", body_json, "\n")
    }
    body_file <- tempfile(fileext = ".json")
    on.exit(unlink(body_file), add = TRUE)
    out <- suppressWarnings(system2("curl", c(args, "-o", body_file, "-w", "%{http_code}"), stdout = TRUE, stderr = TRUE))
    code <- attr(out, "status")
    http_code <- suppressWarnings(as.integer(tail(out, 1)))
    err <- paste(head(out, -1), collapse = "\n")
    if (!is.null(code) && code != 0) {
      last_err <- paste0(context, " failed (curl exit=", code, "): ", err)
      Sys.sleep(0.3 * attempt)
      next
    }
    if (!file.exists(body_file) || file.info(body_file)$size <= 0) {
      last_err <- paste0(context, " returned empty response.")
      Sys.sleep(0.3 * attempt)
      next
    }
    body_txt <- paste(readLines(body_file, warn = FALSE), collapse = "\n")
    if (is.finite(http_code) && http_code >= 500) {
      last_err <- paste0(context, " failed (http=", http_code, "): ", body_txt)
      Sys.sleep(0.3 * attempt)
      next
    }
    if (is.finite(http_code) && http_code >= 400) {
      stop(context, " failed (http=", http_code, "): ", body_txt)
    }
    return(jsonlite::fromJSON(body_txt, simplifyDataFrame = FALSE))
  }
  stop(last_err)
}

as_place_records_new <- function(js) {
  if (is.null(js) || !"places" %in% names(js) || is.null(js$places)) return(list())
  places <- js$places
  if (is.list(places) && !is.null(names(places)) && "id" %in% names(places)) {
    return(list(places))
  }
  if (is.data.frame(places)) {
    out <- vector("list", nrow(places))
    for (i in seq_len(nrow(places))) out[[i]] <- as.list(places[i, , drop = FALSE])
    return(out)
  }
  if (is.list(places)) return(places)
  list()
}

first_non_empty_chr <- function(...) {
  xs <- list(...)
  for (x in xs) {
    if (is.null(x)) next
    v <- as.character(unlist(x, use.names = FALSE))
    v <- v[nzchar(v)]
    if (length(v) > 0) return(v[[1]])
  }
  NA_character_
}

first_num <- function(...) {
  xs <- list(...)
  for (x in xs) {
    if (is.null(x)) next
    v <- suppressWarnings(as.numeric(unlist(x, use.names = FALSE)))
    v <- v[is.finite(v)]
    if (length(v) > 0) return(v[[1]])
  }
  NA_real_
}

option_list <- list(
  make_option(c("--routes"), type = "character", default = "data/derived/routes_facility_to_petco.csv"),
  make_option(c("--anchor_step"), type = "integer", default = 6L, help = "Use every Nth polyline point as query anchor."),
  make_option(c("--radius_m"), type = "integer", default = 20000L),
  make_option(c("--api_mode"), type = "character", default = "new", help = "places api mode: new|legacy"),
  make_option(c("--place_type"), type = "character", default = "electric_vehicle_charging_station"),
  make_option(c("--keyword"), type = "character", default = ""),
  make_option(c("--min_kw"), type = "double", default = 0, help = "Minimum charging rate (kW) for filtering (Places New); <=0 disables this filter."),
  make_option(c("--connector_types"), type = "character", default = "", help = "Comma-separated Places New connector enums; empty disables connector filter."),
  make_option(c("--output"), type = "character", default = "data/derived/ev_charging_stations_corridor.csv")
)
opt <- parse_args(OptionParser(option_list = option_list))
api_key <- Sys.getenv("GOOGLE_MAPS_API_KEY", "")
if (!nzchar(api_key)) stop("GOOGLE_MAPS_API_KEY is required.")
api_mode <- tolower(trimws(opt$api_mode))
if (!api_mode %in% c("new", "legacy")) stop("--api_mode must be one of: new, legacy")

routes <- utils::read.csv(opt$routes, stringsAsFactors = FALSE)
if (nrow(routes) == 0) stop("No routes found: ", opt$routes)

seen <- new.env(parent = emptyenv())
rows <- list()
request_errors <- character()
status_counts <- new.env(parent = emptyenv())
status_note <- function(st) {
  key <- if (!is.null(st) && nzchar(as.character(st))) as.character(st) else "UNKNOWN"
  cur <- if (exists(key, envir = status_counts, inherits = FALSE)) get(key, envir = status_counts) else 0L
  assign(key, cur + 1L, envir = status_counts)
}
for (i in seq_len(nrow(routes))) {
  poly <- decode_polyline(as.character(routes$encoded_polyline[[i]]))
  if (nrow(poly) == 0) next
  anchors <- poly[seq(1, nrow(poly), by = max(1L, as.integer(opt$anchor_step))), , drop = FALSE]
  for (j in seq_len(nrow(anchors))) {
    lat <- anchors$lat[[j]]
    lon <- anchors$lon[[j]]
    js <- NULL
    if (api_mode == "new") {
      conn <- trimws(unlist(strsplit(as.character(opt$connector_types), ",", fixed = TRUE)))
      conn <- conn[nzchar(conn)]
      body <- list(
        includedTypes = list(as.character(opt$place_type)),
        maxResultCount = 20,
        rankPreference = "DISTANCE",
        locationRestriction = list(
          circle = list(
            center = list(latitude = as.numeric(lat), longitude = as.numeric(lon)),
            radius = as.numeric(opt$radius_m)
          )
        )
      )
      ev_opts <- list()
      if (is.finite(as.numeric(opt$min_kw)) && as.numeric(opt$min_kw) > 0) {
        ev_opts$minimumChargingRateKw <- as.numeric(opt$min_kw)
      }
      if (length(conn) > 0) {
        ev_opts$connectorTypes <- as.list(conn)
      }
      if (length(ev_opts) > 0) {
        body$evOptions <- ev_opts
      }
      body_json <- jsonlite::toJSON(body, auto_unbox = TRUE)
      tmp <- tempfile(fileext = ".json")
      writeLines(body_json, tmp)
      js <- tryCatch(
        curl_json(
          c(
            "-sS", "-X", "POST", "https://places.googleapis.com/v1/places:searchNearby",
            "-H", paste0("X-Goog-Api-Key:", api_key),
            "-H", "X-Goog-FieldMask:places.id,places.displayName,places.location,places.evChargeOptions",
            "-H", "Content-Type:application/json",
            "--data-binary", paste0("@", tmp)
          ),
          context = paste0("Places(New) request at anchor ", i, ":", j),
          retries = 3L,
          body_json = body_json
        ),
        error = function(e) {
          msg <- conditionMessage(e)
          warning(msg, call. = FALSE)
          request_errors <<- c(request_errors, msg)
          status_note("REQUEST_ERROR")
          NULL
        }
      )
      unlink(tmp)
    } else {
      url <- paste0(
        "https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=",
        sprintf("%.6f,%.6f", lat, lon),
        "&radius=", as.integer(opt$radius_m),
        "&type=", utils::URLencode(opt$place_type, reserved = TRUE),
        if (nzchar(opt$keyword)) paste0("&keyword=", utils::URLencode(opt$keyword, reserved = TRUE)) else "",
        "&key=", api_key
      )
      js <- tryCatch(
        curl_json(c("-sS", "--fail", url), context = paste0("Google Places(Legacy) request at anchor ", i, ":", j), retries = 3L),
        error = function(e) {
          msg <- conditionMessage(e)
          warning(msg, call. = FALSE)
          request_errors <<- c(request_errors, msg)
          status_note("REQUEST_ERROR")
          NULL
        }
      )
    }
    if (is.null(js)) next
    if (api_mode == "new") {
      places <- as_place_records_new(js)
      if (length(places) == 0) {
        status_note("NO_PLACES_FIELD")
        next
      }
      status_note("OK")
      for (k in seq_along(places)) {
        p <- places[[k]]
        pid <- first_non_empty_chr(p$id, p[["places.id"]])
        if (!nzchar(pid) || exists(pid, envir = seen, inherits = FALSE)) next
        assign(pid, TRUE, envir = seen)

        pname <- first_non_empty_chr(
          p$displayName$text,
          p$displayName,
          p[["displayName.text"]]
        )
        plat <- first_num(
          p$location$latitude,
          p[["location.latitude"]]
        )
        plon <- first_num(
          p$location$longitude,
          p[["location.longitude"]]
        )

        max_kw <- NA_real_
        connectors <- NA_character_
        ag <- p$evChargeOptions$connectorAggregation
        if (is.data.frame(ag)) {
          ag <- lapply(seq_len(nrow(ag)), function(ii) as.list(ag[ii, , drop = FALSE]))
        }
        if (is.list(ag) && length(ag) > 0) {
          kws <- suppressWarnings(as.numeric(unlist(lapply(ag, function(x) x$maxChargeRateKw), use.names = FALSE)))
          kws <- kws[is.finite(kws)]
          if (length(kws) > 0) max_kw <- max(kws)
          cs <- unique(as.character(unlist(lapply(ag, function(x) x$type), use.names = FALSE)))
          cs <- cs[nzchar(cs)]
          if (length(cs) > 0) connectors <- paste(cs, collapse = "|")
        }

        rows[[length(rows) + 1]] <- data.frame(
          station_id = digest::digest(pid, algo = "sha1", serialize = FALSE),
          place_id = pid,
          name = pname,
          lat = plat,
          lon = plon,
          max_charge_rate_kw = max_kw,
          connector_types = connectors,
          provider = "google_places_new",
          radius_m = as.integer(opt$radius_m),
          timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
          stringsAsFactors = FALSE
        )
      }
    } else {
      st <- first_non_empty_chr(js$status)
      if (!is.na(st)) status_note(st)
      if (!is.na(st) && !st %in% c("OK", "ZERO_RESULTS")) {
        warning(
          paste0(
            "Places status at anchor ", i, ":", j, " -> ", st,
            if ("error_message" %in% names(js) && nzchar(first_non_empty_chr(js$error_message))) paste0(" (", first_non_empty_chr(js$error_message), ")") else ""
          ),
          call. = FALSE
        )
        next
      }
      if (!"results" %in% names(js) || is.null(js$results) || length(js$results) == 0) next
      results <- js$results
      if (is.list(results) && !is.null(names(results)) && "place_id" %in% names(results)) {
        results <- lapply(seq_along(results$place_id), function(ii) {
          list(
            place_id = results$place_id[[ii]],
            name = if (!is.null(results$name)) results$name[[ii]] else NA_character_,
            geometry = if (!is.null(results$geometry$location$lat)) {
              list(location = list(lat = results$geometry$location$lat[[ii]], lng = results$geometry$location$lng[[ii]]))
            } else NULL
          )
        })
      }
      for (k in seq_along(results)) {
        rr <- results[[k]]
        pid <- first_non_empty_chr(rr$place_id)
        if (exists(pid, envir = seen, inherits = FALSE)) next
        assign(pid, TRUE, envir = seen)
        rows[[length(rows) + 1]] <- data.frame(
          station_id = digest::digest(pid, algo = "sha1", serialize = FALSE),
          place_id = pid,
          name = first_non_empty_chr(rr$name),
          lat = first_num(rr$geometry$location$lat),
          lon = first_num(rr$geometry$location$lng),
          max_charge_rate_kw = NA_real_,
          connector_types = NA_character_,
          provider = "google_places_legacy",
          radius_m = as.integer(opt$radius_m),
          timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
          stringsAsFactors = FALSE
        )
      }
    }
  }
}

if (length(rows) == 0) {
  if (length(request_errors) > 0) {
    uq <- unique(request_errors)
    excerpt <- paste(head(uq, 3), collapse = " || ")
    stop("No charging stations found. Request errors observed: ", excerpt)
  }
  st_keys <- ls(status_counts)
  if (length(st_keys) == 0) {
    stop("No charging stations found. No Places responses were parsed.")
  }
  st_vals <- vapply(st_keys, function(k) get(k, envir = status_counts), integer(1))
  ord <- order(-st_vals)
  msg <- paste(paste0(st_keys[ord], "=", st_vals[ord]), collapse = ", ")
  stop("No charging stations found. Places status summary: ", msg)
}
out <- do.call(rbind, rows)
dir.create(dirname(opt$output), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, opt$output, row.names = FALSE)
cat("Wrote", opt$output, "\n")
