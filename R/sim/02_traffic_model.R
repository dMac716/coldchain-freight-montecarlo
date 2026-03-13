# Hourly traffic and delay sampling.

hour_from_time <- function(t) {
  as.integer(format(t, "%H"))
}

is_peak_hour <- function(hour, traffic_cfg) {
  m <- traffic_cfg$peak_hours$morning %||% integer()
  e <- traffic_cfg$peak_hours$evening %||% integer()
  hour %in% c(as.integer(m), as.integer(e))
}

sample_traffic_multiplier <- function(t, traffic_cfg, rng = NULL) {
  if (is.null(traffic_cfg) || !isTRUE(traffic_cfg$enabled)) return(1)
  hour <- hour_from_time(t)
  base <- sim_pick_distribution(traffic_cfg$hourly_speed_multiplier$default, rng = rng)
  if (!is.finite(base)) base <- 1
  if (is_peak_hour(hour, traffic_cfg)) {
    peak <- sim_pick_distribution(traffic_cfg$peak_multiplier, rng = rng)
    if (is.finite(peak)) return(peak)
  }
  base
}

sample_incident_delay_minutes <- function(seg_miles, traffic_cfg, rng = NULL) {
  inc <- traffic_cfg$incident_delay %||% list(enabled = TRUE, chance_per_100_miles = 0.05)
  if (!isTRUE(inc$enabled %||% TRUE)) return(0)
  p <- as.numeric(inc$chance_per_100_miles %||% 0.05) * (seg_miles / 100)
  p <- max(0, min(1, p))
  u <- if (is.null(rng)) stats::runif(1) else rng$runif(1)
  if (u > p) return(0)
  dist <- inc$delay_minutes$distribution %||% list(type = "triangular", min = 10, mode = 20, max = 40)
  sim_pick_distribution(dist, rng = rng)
}

sample_queue_delay_minutes <- function(t, charging_cfg, traffic_cfg = NULL, rng = NULL) {
  by_hour <- charging_cfg$queue_delay_minutes_by_hour
  if (is.null(by_hour)) {
    d <- charging_cfg$queue_delay_minutes$distribution
    return(if (is.null(d)) 0 else sim_pick_distribution(d, rng = rng))
  }
  hour <- hour_from_time(t)
  peak <- !is.null(traffic_cfg) && is_peak_hour(hour, traffic_cfg)
  spec <- if (peak) by_hour$peak$distribution %||% by_hour$default$distribution else by_hour$default$distribution
  sim_pick_distribution(spec, rng = rng)
}
