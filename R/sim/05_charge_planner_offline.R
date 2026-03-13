# Offline charging plan execution helpers.

expand_route_plan_stops <- function(plans_df, stations_df) {
  rows <- list()
  ri <- 0L
  for (i in seq_len(nrow(plans_df))) {
    ids <- plans_df$waypoint_station_ids_vec[[i]]
    if (length(ids) == 0) next
    for (j in seq_along(ids)) {
      ri <- ri + 1L
      rows[[ri]] <- data.frame(
        route_id = as.character(plans_df$route_id[[i]]),
        route_plan_id = as.character(plans_df$route_plan_id[[i]]),
        stop_idx = as.integer(j),
        station_id = as.character(ids[[j]]),
        stringsAsFactors = FALSE
      )
    }
  }
  if (length(rows) == 0) return(data.frame())
  out <- do.call(rbind, rows)
  out <- merge(out, stations_df, by = "station_id", all.x = TRUE, sort = FALSE)
  if (any(!is.finite(out$lat) | !is.finite(out$lng))) {
    bad <- unique(out$station_id[!is.finite(out$lat) | !is.finite(out$lng)])
    stop("Route plan references stations missing coordinates: ", paste(bad, collapse = ", "))
  }
  if (any(!is.finite(out$max_charge_rate_kw) | out$max_charge_rate_kw <= 0)) {
    bad <- unique(out$station_id[!is.finite(out$max_charge_rate_kw) | out$max_charge_rate_kw <= 0])
    stop("Route plan references stations with invalid max_charge_rate_kw: ", paste(bad, collapse = ", "))
  }
  out
}

project_stop_to_route <- function(route_segments, stop_lat, stop_lng) {
  d <- haversine_m(stop_lat, stop_lng, route_segments$lat, route_segments$lng) / 1609.344
  j <- which.min(d)
  list(
    seg_id = as.integer(route_segments$seg_id[[j]]),
    stop_cum_miles = as.numeric(route_segments$distance_miles_cum[[j]]),
    detour_miles = as.numeric(d[[j]])
  )
}

project_plan_stops_to_route <- function(route_plan_stops, route_segments) {
  if (nrow(route_plan_stops) == 0) return(route_plan_stops)
  out <- route_plan_stops
  out$stop_cum_miles <- NA_real_
  out$seg_id <- NA_integer_
  out$detour_miles <- NA_real_
  for (i in seq_len(nrow(out))) {
    p <- project_stop_to_route(route_segments, out$lat[[i]], out$lng[[i]])
    out$stop_cum_miles[[i]] <- p$stop_cum_miles
    out$seg_id[[i]] <- p$seg_id
    out$detour_miles[[i]] <- p$detour_miles
  }
  out[order(out$stop_idx), , drop = FALSE]
}

validate_plan_feasibility <- function(route_plan_stops, route_segments, vehicle_policy) {
  if (nrow(route_plan_stops) == 0) {
    return(list(valid = FALSE, reason = "NO_STOPS"))
  }
  max_leg <- as.numeric(vehicle_policy$planning_leg_miles %||% 160)
  pts <- c(0, route_plan_stops$stop_cum_miles, max(route_segments$distance_miles_cum, na.rm = TRUE))
  legs <- diff(pts)
  bad <- which(legs > max_leg)
  if (length(bad) > 0) {
    return(list(valid = FALSE, reason = paste0("LEG_TOO_LONG:", paste(round(legs[bad], 3), collapse = "|"))))
  }
  list(valid = TRUE, reason = "OK")
}

select_plan_for_route <- function(plans_df, route_id) {
  d <- plans_df[plans_df$route_id == route_id, , drop = FALSE]
  if (nrow(d) == 0) return(d)
  if ("timestamp_utc" %in% names(d)) {
    d <- d[order(d$timestamp_utc, decreasing = TRUE), , drop = FALSE]
  }
  d[1, , drop = FALSE]
}

select_valid_plan_for_route <- function(plans_df, stations_df, route_id, route_segments, vehicle_policy) {
  cand <- plans_df[plans_df$route_id == route_id, , drop = FALSE]
  if (nrow(cand) == 0) stop("No BEV route plans found for route_id=", route_id)
  if ("timestamp_utc" %in% names(cand)) cand <- cand[order(cand$timestamp_utc, decreasing = TRUE), , drop = FALSE]
  errs <- character()
  for (i in seq_len(nrow(cand))) {
    one <- cand[i, , drop = FALSE]
    ok <- tryCatch({
      ex <- expand_route_plan_stops(one, stations_df)
      pr <- project_plan_stops_to_route(ex, route_segments)
      list(one = one, projected = pr)
    }, error = function(e) {
      errs <<- c(errs, paste0(one$route_plan_id[[1]], ": ", conditionMessage(e)))
      NULL
    })
    if (!is.null(ok)) return(ok)
  }
  stop("No valid BEV route plan for route_id=", route_id, ". Tried: ", paste(errs, collapse = " || "))
}

`%||%` <- function(x, y) if (!is.null(x)) x else y
