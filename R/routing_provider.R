compute_route_km <- function(provider, origin_latlon, dest_latlon, ...) {
  p <- tolower(trimws(as.character(provider)))
  if (identical(p, "osrm")) {
    return(compute_route_osrm(origin = origin_latlon, dest = dest_latlon, ...))
  }
  if (identical(p, "google")) {
    return(compute_route_google(origin = origin_latlon, dest = dest_latlon, ...))
  }
  stop("Unsupported routing provider: ", provider)
}
