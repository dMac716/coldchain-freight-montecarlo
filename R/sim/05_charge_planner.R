# Offline charger dataset contract and charging stop selection.

load_chargers <- function(path, format = "csv") {
  fmt <- tolower(format)
  if (!file.exists(path)) stop("Charger dataset missing: ", path)
  if (fmt == "csv") return(utils::read.csv(path, stringsAsFactors = FALSE))
  if (fmt == "parquet") {
    if (!requireNamespace("arrow", quietly = TRUE)) stop("arrow package required for parquet chargers")
    return(as.data.frame(arrow::read_parquet(path), stringsAsFactors = FALSE))
  }
  if (fmt == "geojson") {
    if (!requireNamespace("jsonlite", quietly = TRUE)) stop("jsonlite required for geojson chargers")
    js <- jsonlite::fromJSON(path, simplifyDataFrame = FALSE)
    feats <- js$features %||% list()
    rows <- lapply(feats, function(f) {
      p <- f$properties %||% list()
      g <- f$geometry$coordinates %||% c(NA_real_, NA_real_)
      data.frame(
        charger_id = as.character(p$charger_id %||% p$id %||% NA_character_),
        lat = as.numeric(g[[2]]),
        lng = as.numeric(g[[1]]),
        route_id = as.character(p$route_id %||% NA_character_),
        corridor_id = as.character(p$corridor_id %||% NA_character_),
        power_kw = as.numeric(p$power_kw %||% NA_real_),
        connector = as.character(p$connector %||% NA_character_),
        reliability = as.numeric(p$reliability %||% NA_real_),
        access = as.character(p$access %||% "public"),
        site_name = as.character(p$site_name %||% NA_character_),
        stringsAsFactors = FALSE
      )
    })
    return(do.call(rbind, rows))
  }
  stop("Unsupported charger format: ", format)
}

validate_chargers <- function(df) {
  req <- c("charger_id", "lat", "lng", "power_kw", "connector", "reliability", "access")
  miss <- setdiff(req, names(df))
  if (length(miss) > 0) stop("Charger dataset missing columns: ", paste(miss, collapse = ", "))
  if (anyDuplicated(df$charger_id)) stop("charger_id must be unique")
  if (any(!is.finite(df$lat) | !is.finite(df$lng))) stop("lat/lng must be finite")
  if (any(df$reliability < 0 | df$reliability > 1, na.rm = TRUE)) stop("reliability must be 0..1")
  invisible(TRUE)
}

attach_chargers_to_route <- function(route_segments, chargers, route_id = NULL, max_detour_miles = 10) {
  d <- chargers
  if (!is.null(route_id) && "route_id" %in% names(d)) {
    keep <- is.na(d$route_id) | d$route_id == "" | d$route_id == route_id
    d <- d[keep, , drop = FALSE]
  }
  if (nrow(d) == 0) return(d)

  pts <- route_segments[, c("lat", "lng", "distance_miles_cum"), drop = FALSE]
  idx <- integer(nrow(d))
  detour <- numeric(nrow(d))
  along <- numeric(nrow(d))
  for (i in seq_len(nrow(d))) {
    dm <- haversine_m(d$lat[[i]], d$lng[[i]], pts$lat, pts$lng) / 1609.344
    j <- which.min(dm)
    idx[[i]] <- j
    detour[[i]] <- dm[[j]]
    along[[i]] <- pts$distance_miles_cum[[j]]
  }
  d$nearest_seg_id <- idx
  d$detour_miles <- detour
  d$along_route_miles <- along
  d[d$detour_miles <= as.numeric(max_detour_miles), , drop = FALSE]
}

select_next_charger <- function(
    sim_state,
    chargers_attached,
    charging_cfg,
    queue_delay_minutes = 0,
    rng = NULL) {
  if (nrow(chargers_attached) == 0) return(NULL)
  d <- chargers_attached
  cur_miles <- as.numeric(sim_state$distance_miles_cum)
  d <- d[d$along_route_miles > cur_miles, , drop = FALSE]
  if (nrow(d) == 0) return(NULL)

  req_conn <- as.character(charging_cfg$connector_required %||% "")
  min_kw <- as.numeric(charging_cfg$min_station_power_kw %||% 0)
  d <- d[d$power_kw >= min_kw | !is.finite(d$power_kw), , drop = FALSE]
  if (nzchar(req_conn)) d <- d[grepl(req_conn, d$connector, fixed = TRUE), , drop = FALSE]
  if (nrow(d) == 0) return(NULL)

  policy <- as.character(charging_cfg$selection_policy %||% "min_total_time")
  battery_kwh <- as.numeric(sim_state$battery_kwh)
  cur_soc <- as.numeric(sim_state$soc)
  target_soc <- as.numeric(sim_state$soc_target_after_charge)

  d$charge_minutes <- vapply(seq_len(nrow(d)), function(i) {
    compute_charge_minutes(
      current_soc = cur_soc,
      target_soc = target_soc,
      battery_kwh = battery_kwh,
      max_power_kw = as.numeric(d$power_kw[[i]] %||% 150),
      charge_curve = charging_cfg$charge_curve,
      rng = rng
    )
  }, numeric(1))
  d$detour_minutes <- (pmax(0, d$detour_miles) * 2 / 35) * 60
  d$total_minutes <- d$detour_minutes + as.numeric(queue_delay_minutes) + d$charge_minutes

  ord <- if (policy == "max_reliability") order(-d$reliability, d$total_minutes) else if (policy == "min_detour") order(d$detour_miles, d$total_minutes) else order(d$total_minutes)
  d[ord[1], , drop = FALSE]
}
