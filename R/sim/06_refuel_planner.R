# Diesel refueling planning.

needs_refuel <- function(projected_fuel_gal, tank_capacity_gal, reserve_fuel_fraction) {
  projected_fuel_gal < (as.numeric(tank_capacity_gal) * as.numeric(reserve_fuel_fraction))
}

compute_refuel_event <- function(
    current_fuel_gal,
    diesel_refuel_cfg,
    fuel_type,
    queue_delay_minutes = 0,
    rng = NULL) {
  cap <- as.numeric(diesel_refuel_cfg$tank_capacity_gal)
  target <- as.numeric(diesel_refuel_cfg$refuel_target_fraction)
  gal_target <- cap * target
  gallons_added <- max(0, gal_target - as.numeric(current_fuel_gal))

  fixed_min <- sim_pick_distribution(diesel_refuel_cfg$fixed_stop_minutes, rng = rng)
  gpm <- max(0.1, sim_pick_distribution(diesel_refuel_cfg$gallons_per_minute, rng = rng))
  stop_minutes <- fixed_min + gallons_added / gpm + as.numeric(queue_delay_minutes)

  ef <- sim_pick_distribution(fuel_type$co2_kg_per_gallon, rng = rng)
  if (!is.finite(ef)) ef <- as.numeric(fuel_type$co2_kg_per_gallon$baseline %||% 10.19)

  list(
    gallons_added = gallons_added,
    stop_minutes = stop_minutes,
    fuel_type_name = as.character(fuel_type$name %||% "DIESEL"),
    co2_kg = gallons_added * ef,
    co2_kg_per_gal = ef
  )
}
