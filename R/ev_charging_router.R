select_charging_waypoints <- function(route_segments, stations_df, target_spacing_km, max_offset_km = 25) {
  if (nrow(route_segments) == 0 || nrow(stations_df) == 0) return(character())
  total_km <- max(route_segments$cumulative_m, na.rm = TRUE) / 1000
  if (!is.finite(total_km) || total_km <= target_spacing_km) return(character())

  needed <- floor(total_km / target_spacing_km)
  if (needed < 1) return(character())

  targets_km <- seq(target_spacing_km * 0.75, by = target_spacing_km, length.out = needed)
  picks <- character()

  for (tkm in targets_km) {
    target_m <- tkm * 1000
    idx <- which.min(abs(route_segments$cumulative_m - target_m))
    lat_t <- route_segments$lat2[[idx]]
    lon_t <- route_segments$lon2[[idx]]

    d_km <- haversine_m(lat_t, lon_t, stations_df$lat, stations_df$lon) / 1000
    j <- which.min(d_km)
    if (length(j) == 1 && is.finite(d_km[[j]]) && d_km[[j]] <= max_offset_km) {
      picks <- c(picks, as.character(stations_df$station_id[[j]]))
    }
  }
  unique(picks)
}
