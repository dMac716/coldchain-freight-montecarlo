# Offline EV charging stations loader/validator.

parse_connector_types <- function(x) {
  if (is.null(x) || !nzchar(as.character(x))) return(character())
  s <- trimws(as.character(x))
  if (grepl("^\\[", s)) {
    if (!requireNamespace("jsonlite", quietly = TRUE)) return(strsplit(gsub("[\\[\\]\"]", "", s), "[,|;]", perl = TRUE)[[1]])
    v <- tryCatch(jsonlite::fromJSON(s), error = function(e) NULL)
    if (is.null(v)) return(strsplit(gsub("[\\[\\]\"]", "", s), "[,|;]", perl = TRUE)[[1]])
    return(as.character(unlist(v, use.names = FALSE)))
  }
  parts <- strsplit(s, "[|;,]", perl = TRUE)[[1]]
  trimws(parts[nzchar(trimws(parts))])
}

read_ev_stations <- function(path) {
  if (!file.exists(path)) stop("EV stations file missing: ", path)
  d <- utils::read.csv(path, stringsAsFactors = FALSE)
  if ("lon" %in% names(d) && !"lng" %in% names(d)) names(d)[names(d) == "lon"] <- "lng"

  req <- c("station_id", "lat", "lng", "max_charge_rate_kw", "connector_types")
  miss <- setdiff(req, names(d))
  if (length(miss) > 0) stop("EV stations missing columns: ", paste(miss, collapse = ", "))
  if (anyDuplicated(d$station_id)) stop("station_id must be unique in EV stations")
  if (any(!is.finite(d$lat) | d$lat < -90 | d$lat > 90)) stop("lat out of range in EV stations")
  if (any(!is.finite(d$lng) | d$lng < -180 | d$lng > 180)) stop("lng out of range in EV stations")
  d$max_charge_rate_kw <- suppressWarnings(as.numeric(d$max_charge_rate_kw))
  d$max_charge_rate_kw_imputed <- FALSE
  bad_kw <- !is.finite(d$max_charge_rate_kw) | d$max_charge_rate_kw <= 0
  if (any(bad_kw)) {
    # Conservative fallback for incomplete station metadata so cached plans remain executable offline.
    d$max_charge_rate_kw[bad_kw] <- 50
    d$max_charge_rate_kw_imputed[bad_kw] <- TRUE
  }

  d$connector_types_raw <- as.character(d$connector_types)
  d$connector_types_list <- I(lapply(d$connector_types_raw, parse_connector_types))
  d
}
