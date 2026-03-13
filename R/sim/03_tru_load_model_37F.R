# Refrigeration load model at fixed 37F setpoint.

compute_tru_segment <- function(
    seg_miles,
    travel_hours,
    ambient_f,
    cfg,
    powertrain = c("bev", "diesel"),
    cold_chain_required = TRUE,
    rng = NULL) {
  powertrain <- match.arg(powertrain)
  if (!isTRUE(cold_chain_required)) {
    return(list(tru_kwh = 0, tru_gal = 0, tru_load_kw = 0))
  }
  setpoint <- as.numeric(cfg$refrigeration_model$setpoint_f %||% 37)
  dt <- max(0, as.numeric(ambient_f) - setpoint)

  slope_duty <- sim_pick_distribution(cfg$refrigeration_model$ambient_sensitivity$duty_slope_per_f, rng = rng)
  slope_kw <- sim_pick_distribution(cfg$refrigeration_model$ambient_sensitivity$power_slope_kw_per_f, rng = rng)

  if (powertrain == "bev") {
    base_kw <- sim_pick_distribution(cfg$refrigeration_units$electric_vector_ecool$tru_power_kw_base, rng = rng)
    duty <- sim_pick_distribution(cfg$refrigeration_units$electric_vector_ecool$duty_cycle_base, rng = rng)
    duty <- max(0, min(1, duty + slope_duty * dt))
    kw <- max(0, base_kw + slope_kw * dt)
    kwh <- kw * duty * travel_hours
    return(list(tru_kwh = kwh, tru_gal = 0, tru_load_kw = kw * duty))
  }

  gal_hr <- sim_pick_distribution(cfg$refrigeration_units$diesel_vector_tru$fuel_gal_per_engine_hr, rng = rng)
  duty <- sim_pick_distribution(cfg$refrigeration_units$diesel_vector_tru$duty_cycle_base, rng = rng)
  duty <- max(0, min(1, duty + slope_duty * dt))
  gal <- gal_hr * duty * travel_hours
  list(tru_kwh = 0, tru_gal = gal, tru_load_kw = NA_real_)
}

compute_stop_penalty_kwh <- function(cfg, rng = NULL) {
  if (!isTRUE(cfg$refrigeration_model$stop_events$enabled)) return(0)
  sim_pick_distribution(cfg$refrigeration_model$stop_events$kwh_per_stop_equivalent, rng = rng)
}
