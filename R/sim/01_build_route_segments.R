# Route segment builders for event simulation.

sim_pick_distribution <- function(spec, rng = NULL) {
  if (is.null(spec)) return(NA_real_)
  if (!is.null(spec$baseline)) return(as.numeric(spec$baseline))
  if (!is.null(spec$distribution)) spec <- spec$distribution
  typ <- tolower(as.character(spec$type %||% ""))
  if (typ %in% c("fixed", "constant")) {
    return(as.numeric(spec$value %||% spec$mean %||% spec$mode %||% spec$min %||% NA_real_))
  }
  if (typ == "triangular") {
    a <- as.numeric(spec$min)
    b <- as.numeric(spec$mode)
    c <- as.numeric(spec$max)
    if (!is.finite(a) || !is.finite(b) || !is.finite(c)) return(NA_real_)
    if (abs(c - a) < .Machine$double.eps) return(a)
    b <- min(max(b, a), c)
    u <- if (is.null(rng)) stats::runif(1) else rng$runif(1)
    f <- (b - a) / (c - a)
    if (u < f) {
      return(a + sqrt(u * (b - a) * (c - a)))
    }
    return(c - sqrt((1 - u) * (c - b) * (c - a)))
  }
  if (typ == "uniform") {
    a <- as.numeric(spec$min)
    c <- as.numeric(spec$max)
    if (is.null(rng)) return(stats::runif(1, a, c))
    return(rng$runif(1, a, c))
  }
  if (typ == "normal") {
    mu <- as.numeric(spec$mean %||% spec$mu %||% spec$p1 %||% NA_real_)
    sd <- as.numeric(spec$sd %||% spec$sigma %||% spec$p2 %||% 0)
    if (!is.finite(mu)) return(NA_real_)
    if (!is.finite(sd) || sd < 0) sd <- 0
    if (sd == 0) return(mu)
    if (is.null(rng) || is.null(rng$rnorm)) return(stats::rnorm(1, mean = mu, sd = sd))
    return(rng$rnorm(1, mean = mu, sd = sd))
  }
  if (typ == "lognormal") {
    meanlog <- as.numeric(spec$meanlog %||% spec$mu %||% spec$p1 %||% NA_real_)
    sdlog <- as.numeric(spec$sdlog %||% spec$sigma %||% spec$p2 %||% 0)
    if (!is.finite(meanlog)) return(NA_real_)
    if (!is.finite(sdlog) || sdlog < 0) sdlog <- 0
    if (sdlog == 0) return(exp(meanlog))
    z <- if (is.null(rng) || is.null(rng$rnorm)) stats::rnorm(1, mean = 0, sd = 1) else rng$rnorm(1, mean = 0, sd = 1)
    return(exp(meanlog + sdlog * z))
  }
  if (typ == "discrete") {
    vals <- suppressWarnings(as.numeric(unlist(spec$values %||% spec$support %||% numeric())))
    vals <- vals[is.finite(vals)]
    if (length(vals) == 0L) return(NA_real_)
    probs <- suppressWarnings(as.numeric(unlist(spec$probs %||% spec$weights %||% numeric())))
    if (length(probs) != length(vals) || any(!is.finite(probs)) || sum(probs) <= 0) {
      probs <- rep(1 / length(vals), length(vals))
    } else {
      probs <- pmax(0, probs)
      s <- sum(probs)
      if (!is.finite(s) || s <= 0) probs <- rep(1 / length(vals), length(vals)) else probs <- probs / s
    }
    u <- if (is.null(rng)) stats::runif(1) else rng$runif(1)
    cut <- cumsum(probs)
    idx <- which(u <= cut)[1]
    if (!is.finite(idx)) idx <- length(vals)
    return(as.numeric(vals[[idx]]))
  }
  if (!is.null(spec$value)) return(as.numeric(spec$value))
  NA_real_
}

`%||%` <- function(x, y) if (!is.null(x)) x else y

load_routes_cache <- function(path = "data/derived/routes_facility_to_petco.csv") {
  if (!file.exists(path)) stop("Routes cache missing: ", path)
  out <- utils::read.csv(path, stringsAsFactors = FALSE)
  req <- c("route_id", "facility_id", "distance_m", "duration_s", "encoded_polyline")
  miss <- setdiff(req, names(out))
  if (length(miss) > 0) stop("Routes cache missing columns: ", paste(miss, collapse = ", "))
  out
}

select_route_row <- function(routes_df, facility_id = NULL, route_rank = 1L) {
  d <- routes_df
  if (!is.null(facility_id)) {
    d <- d[d$facility_id == facility_id, , drop = FALSE]
  }
  if (nrow(d) == 0) stop("No routes available for requested facility.")
  if ("route_rank" %in% names(d)) {
    d <- d[order(d$route_rank), , drop = FALSE]
    d <- d[d$route_rank == route_rank, , drop = FALSE]
    if (nrow(d) == 0) d <- routes_df[order(routes_df$route_rank), , drop = FALSE]
  }
  d[1, , drop = FALSE]
}

load_elevation_profile <- function(path, route_id) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) return(NULL)
  e <- utils::read.csv(path, stringsAsFactors = FALSE)
  req <- c("route_id", "s_m", "elev_m")
  miss <- setdiff(req, names(e))
  if (length(miss) > 0) return(NULL)
  e <- e[e$route_id == route_id, c("s_m", "elev_m"), drop = FALSE]
  if (nrow(e) < 2) return(NULL)
  e[order(e$s_m), , drop = FALSE]
}

build_route_segments <- function(route_row, elevation_profile = NULL) {
  poly <- decode_polyline(as.character(route_row$encoded_polyline[[1]]))
  seg <- polyline_to_segments(poly)
  if (nrow(seg) == 0) stop("Decoded route has no segments.")

  seg$route_id <- as.character(route_row$route_id[[1]])
  seg$seg_id <- seq_len(nrow(seg))
  seg$lat <- seg$lat2
  seg$lng <- seg$lon2
  seg$seg_miles <- seg$segment_m / 1609.344
  seg$distance_miles_cum <- seg$cumulative_m / 1609.344
  seg$cum_miles <- seg$distance_miles_cum
  seg$grade <- 0
  seg$elev_m <- NA_real_

  if (!is.null(elevation_profile) && nrow(elevation_profile) >= 2) {
    elev <- stats::approx(
      x = elevation_profile$s_m,
      y = elevation_profile$elev_m,
      xout = c(0, seg$cumulative_m),
      rule = 2
    )$y
    ds <- seg$segment_m
    dh <- diff(elev)
    g <- dh / pmax(ds, 1)
    seg$grade <- g
    seg$elev_m <- elev[-1]
  }

  seg$speed_limit_mph <- NA_real_
  seg$bearing <- NA_real_
  seg$admin_region <- NA_character_

  seg[, c(
    "route_id", "seg_id", "lat", "lng", "seg_miles", "grade", "elev_m",
    "speed_limit_mph", "bearing", "admin_region", "distance_miles_cum", "cum_miles"
  )]
}
