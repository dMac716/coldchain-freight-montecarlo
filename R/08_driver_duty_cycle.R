# Driver duty-cycle + HOS helpers.

hos_value <- function(cfg, key, fallback) {
  h <- cfg$hos %||% list()
  old <- switch(
    key,
    break_required_after_driving_hours = "break_after_driving_h",
    break_duration_min = "break_minutes",
    max_on_duty_window_hours = "max_on_duty_h",
    rest_reset_hours = "reset_off_duty_h",
    key
  )
  as.numeric(h[[key]] %||% h[[old]] %||% fallback)
}

init_hos_state <- function() {
  list(
    driving_since_reset_hours = 0,
    on_duty_window_since_reset_hours = 0,
    driving_since_last_break_hours = 0,
    shift_driving_h = 0,
    shift_on_duty_h = 0,
    break_taken = FALSE,
    rest_periods = 0L,
    num_break_30min = 0L,
    num_rest_10hr = 0L
  )
}

normalize_hos_state <- function(hos) {
  h <- hos %||% list()
  out <- init_hos_state()
  out$shift_driving_h <- as.numeric(h$shift_driving_h %||% out$shift_driving_h)
  out$shift_on_duty_h <- as.numeric(h$shift_on_duty_h %||% out$shift_on_duty_h)
  out$break_taken <- as.logical(h$break_taken %||% out$break_taken)
  out$rest_periods <- as.integer(h$rest_periods %||% out$rest_periods)
  out$num_break_30min <- as.integer(h$num_break_30min %||% out$num_break_30min)
  out$num_rest_10hr <- as.integer(h$num_rest_10hr %||% out$num_rest_10hr)
  out$driving_since_reset_hours <- as.numeric(h$driving_since_reset_hours %||% out$shift_driving_h)
  out$on_duty_window_since_reset_hours <- as.numeric(h$on_duty_window_since_reset_hours %||% out$shift_on_duty_h)
  out$driving_since_last_break_hours <- as.numeric(h$driving_since_last_break_hours %||% if (isTRUE(out$break_taken)) 0 else out$shift_driving_h)
  out
}

init_schedule_state <- function(cfg) {
  list(
    driving_min = 0,
    on_duty_not_driving_min = as.numeric(cfg$driver_time$pretrip_inspection_min %||% 0),
    off_duty_min = 0,
    time_charging_min = 0,
    time_refuel_min = 0,
    time_load_unload_min = 0,
    time_traffic_delay_min = 0,
    num_break_30min = 0L,
    num_rest_10hr = 0L,
    hos_violation_flag = 0L
  )
}

schedule_add_on_duty <- function(schedule, hos, minutes) {
  m <- max(0, as.numeric(minutes %||% 0))
  if (!is.finite(m) || m <= 0) return(list(schedule = schedule, hos = hos))
  schedule$on_duty_not_driving_min <- as.numeric(schedule$on_duty_not_driving_min) + m
  hos$on_duty_window_since_reset_hours <- as.numeric(hos$on_duty_window_since_reset_hours) + m / 60
  hos$shift_on_duty_h <- as.numeric(hos$shift_on_duty_h) + m / 60
  list(schedule = schedule, hos = hos)
}

schedule_add_driving <- function(schedule, hos, driving_minutes, traffic_delay_minutes = 0) {
  dm <- max(0, as.numeric(driving_minutes %||% 0))
  td <- max(0, as.numeric(traffic_delay_minutes %||% 0))
  if (is.finite(dm) && dm > 0) {
    schedule$driving_min <- as.numeric(schedule$driving_min) + dm
    hos$driving_since_reset_hours <- as.numeric(hos$driving_since_reset_hours) + dm / 60
    hos$driving_since_last_break_hours <- as.numeric(hos$driving_since_last_break_hours) + dm / 60
    hos$on_duty_window_since_reset_hours <- as.numeric(hos$on_duty_window_since_reset_hours) + dm / 60
    hos$shift_driving_h <- as.numeric(hos$shift_driving_h) + dm / 60
    hos$shift_on_duty_h <- as.numeric(hos$shift_on_duty_h) + dm / 60
  }
  if (is.finite(td) && td > 0) {
    schedule$time_traffic_delay_min <- as.numeric(schedule$time_traffic_delay_min) + td
  }
  list(schedule = schedule, hos = hos)
}

enforce_hos_before_driving <- function(hos, schedule, tcur, counts, add_event_fn, lat, lng, cfg) {
  hos <- normalize_hos_state(hos)
  if (!isTRUE(as.logical(cfg$hos$enabled %||% TRUE))) {
    return(list(hos = hos, schedule = schedule, tcur = tcur, counts = counts))
  }

  break_after_h <- hos_value(cfg, "break_required_after_driving_hours", 8)
  break_min <- hos_value(cfg, "break_duration_min", 30)
  drive_max_h <- hos_value(cfg, "max_driving_hours", 11)
  shift_max_h <- hos_value(cfg, "max_on_duty_window_hours", 14)
  reset_h <- hos_value(cfg, "rest_reset_hours", 10)

  repeat {
    did_insert <- FALSE

    if (is.finite(hos$driving_since_last_break_hours) &&
      hos$driving_since_last_break_hours >= break_after_h) {
      t0 <- tcur
      t1 <- t0 + break_min * 60
      add_event_fn(t0, t1, "REST_BREAK", lat, lng, reason = "30-min break after cumulative driving limit")
      tcur <- t1
      schedule$on_duty_not_driving_min <- as.numeric(schedule$on_duty_not_driving_min) + break_min
      hos$on_duty_window_since_reset_hours <- as.numeric(hos$on_duty_window_since_reset_hours) + break_min / 60
      hos$shift_on_duty_h <- as.numeric(hos$shift_on_duty_h) + break_min / 60
      hos$driving_since_last_break_hours <- 0
      hos$break_taken <- TRUE
      schedule$num_break_30min <- as.integer(schedule$num_break_30min %||% 0L) + 1L
      hos$num_break_30min <- as.integer(hos$num_break_30min %||% 0L) + 1L
      counts$stop <- as.integer(counts$stop %||% 0L) + 1L
      did_insert <- TRUE
    }

    if (is.finite(hos$driving_since_reset_hours) &&
      is.finite(hos$on_duty_window_since_reset_hours) &&
      (hos$driving_since_reset_hours >= drive_max_h ||
        hos$on_duty_window_since_reset_hours >= shift_max_h)) {
      t0 <- tcur
      t1 <- t0 + reset_h * 3600
      add_event_fn(t0, t1, "REST_RESET", lat, lng, reason = "10-hour off-duty reset")
      tcur <- t1
      schedule$off_duty_min <- as.numeric(schedule$off_duty_min) + reset_h * 60
      hos$driving_since_reset_hours <- 0
      hos$on_duty_window_since_reset_hours <- 0
      hos$driving_since_last_break_hours <- 0
      hos$shift_driving_h <- 0
      hos$shift_on_duty_h <- 0
      hos$break_taken <- FALSE
      hos$rest_periods <- as.integer(hos$rest_periods %||% 0L) + 1L
      hos$num_rest_10hr <- as.integer(hos$num_rest_10hr %||% 0L) + 1L
      schedule$num_rest_10hr <- as.integer(schedule$num_rest_10hr %||% 0L) + 1L
      counts$stop <- as.integer(counts$stop %||% 0L) + 1L
      did_insert <- TRUE
    }

    if (!did_insert) break
  }

  list(hos = hos, schedule = schedule, tcur = tcur, counts = counts)
}

schedule_totals <- function(schedule) {
  driving_min <- as.numeric(schedule$driving_min %||% 0)
  on_duty_not_driving_min <- as.numeric(schedule$on_duty_not_driving_min %||% 0)
  off_duty_min <- as.numeric(schedule$off_duty_min %||% 0)
  driver_on_duty_min <- driving_min + on_duty_not_driving_min
  list(
    delivery_time_min = driving_min + on_duty_not_driving_min + off_duty_min,
    driver_driving_min = driving_min,
    driver_on_duty_min = driver_on_duty_min,
    driver_off_duty_min = off_duty_min,
    time_charging_min = as.numeric(schedule$time_charging_min %||% 0),
    time_refuel_min = as.numeric(schedule$time_refuel_min %||% 0),
    time_load_unload_min = as.numeric(schedule$time_load_unload_min %||% 0),
    time_traffic_delay_min = as.numeric(schedule$time_traffic_delay_min %||% 0),
    num_break_30min = as.integer(schedule$num_break_30min %||% 0L),
    num_rest_10hr = as.integer(schedule$num_rest_10hr %||% 0L),
    hos_violation_flag = as.integer(schedule$hos_violation_flag %||% 0L)
  )
}

apply_hos_rules <- function(hos_state, tcur, counts, add_event_fn, lat, lng, cfg) {
  if (is.null(hos_state)) hos_state <- init_hos_state()
  schedule <- init_schedule_state(cfg)
  out <- enforce_hos_before_driving(
    hos = hos_state,
    schedule = schedule,
    tcur = tcur,
    counts = counts,
    add_event_fn = add_event_fn,
    lat = lat,
    lng = lng,
    cfg = cfg
  )
  rest_h <- as.numeric(schedule_totals(out$schedule)$driver_off_duty_min) / 60
  list(hos_state = out$hos, tcur = out$tcur, rest_h = rest_h, counts = out$counts)
}
