# Decodes Google encoded polyline to a data frame with lat/lon.
decode_polyline <- function(polyline) {
  if (!nzchar(polyline)) return(data.frame(lat = numeric(), lon = numeric()))

  bytes <- utf8ToInt(polyline)
  len <- length(bytes)
  idx <- 1L
  lat <- 0L
  lon <- 0L
  out_lat <- numeric()
  out_lon <- numeric()

  decode_value <- function() {
    result <- 0L
    shift <- 0L
    repeat {
      if (idx > len) stop("Invalid encoded polyline.")
      b <- bytes[[idx]] - 63L
      idx <<- idx + 1L
      result <- bitwOr(result, bitwShiftL(bitwAnd(b, 0x1f), shift))
      shift <- shift + 5L
      if (b < 0x20) break
    }
    if (bitwAnd(result, 1L) != 0L) {
      -bitwShiftR(result, 1L) - 1L
    } else {
      bitwShiftR(result, 1L)
    }
  }

  while (idx <= len) {
    lat <- lat + decode_value()
    lon <- lon + decode_value()
    out_lat <- c(out_lat, lat / 1e5)
    out_lon <- c(out_lon, lon / 1e5)
  }

  data.frame(lat = out_lat, lon = out_lon, stringsAsFactors = FALSE)
}

haversine_m <- function(lat1, lon1, lat2, lon2) {
  r <- 6371000
  to_rad <- pi / 180
  p1 <- lat1 * to_rad
  p2 <- lat2 * to_rad
  dphi <- (lat2 - lat1) * to_rad
  dlambda <- (lon2 - lon1) * to_rad
  a <- sin(dphi / 2)^2 + cos(p1) * cos(p2) * sin(dlambda / 2)^2
  2 * r * atan2(sqrt(a), sqrt(1 - a))
}

polyline_to_segments <- function(poly_df) {
  if (nrow(poly_df) < 2) {
    return(data.frame(
      lat1 = numeric(), lon1 = numeric(), lat2 = numeric(), lon2 = numeric(),
      segment_m = numeric(), cumulative_m = numeric(),
      stringsAsFactors = FALSE
    ))
  }
  lat1 <- poly_df$lat[-nrow(poly_df)]
  lon1 <- poly_df$lon[-nrow(poly_df)]
  lat2 <- poly_df$lat[-1]
  lon2 <- poly_df$lon[-1]
  d <- haversine_m(lat1, lon1, lat2, lon2)
  data.frame(
    lat1 = lat1,
    lon1 = lon1,
    lat2 = lat2,
    lon2 = lon2,
    segment_m = d,
    cumulative_m = cumsum(d),
    stringsAsFactors = FALSE
  )
}
