# Driver duty-cycle helpers (FMCSA-inspired simplified HOS model).

init_hos_state <- function() {
  list(
    shift_driving_h = 0,
    shift_on_duty_h = 0,
    break_taken = FALSE,
    rest_periods = 0L
  )
}

apply_hos_rules <- function(hos_state, tcur, counts, add_event_fn, lat, lng, cfg) {
  if (is.null(hos_state)) hos_state <- init_hos_state()
  break_after_h <- as.numeric(cfg$hos$break_after_driving_h %||% 8)
  break_min <- as.numeric(cfg$hos$break_minutes %||% 30)
  drive_max_h <- as.numeric(cfg$hos$max_driving_h %||% 11)
  shift_max_h <- as.numeric(cfg$hos$max_on_duty_h %||% 14)
  reset_h <- as.numeric(cfg$hos$reset_off_duty_h %||% 10)

  rest_h <- 0
  if (!isTRUE(hos_state$break_taken) && hos_state$shift_driving_h >= break_after_h) {
    t0 <- tcur
    t1 <- t0 + break_min * 60
    add_event_fn(t0, t1, "REST_BREAK", lat, lng, reason = "30min break after 8h driving")
    tcur <- t1
    rest_h <- rest_h + break_min / 60
    hos_state$break_taken <- TRUE
    counts$stop <- counts$stop + 1L
  }

  if (hos_state$shift_driving_h >= drive_max_h || hos_state$shift_on_duty_h >= shift_max_h) {
    t0 <- tcur
    t1 <- t0 + reset_h * 3600
    add_event_fn(t0, t1, "REST_RESET", lat, lng, reason = "HOS reset (11h drive or 14h on-duty)")
    tcur <- t1
    rest_h <- rest_h + reset_h
    hos_state$shift_driving_h <- 0
    hos_state$shift_on_duty_h <- 0
    hos_state$break_taken <- FALSE
    hos_state$rest_periods <- as.integer(hos_state$rest_periods %||% 0L) + 1L
    counts$stop <- counts$stop + 1L
  }

  list(hos_state = hos_state, tcur = tcur, rest_h = rest_h, counts = counts)
}
