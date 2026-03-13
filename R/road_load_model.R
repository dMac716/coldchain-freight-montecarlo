compute_road_load_energy <- function(
    elevation_profile,
    total_duration_s,
    mass_kg,
    Crr,
    CdA,
    rho_air = 1.2,
    regen_eff = 0.6,
    drivetrain_eff = 0.9,
    include_aero = TRUE) {
  if (nrow(elevation_profile) < 2) {
    return(list(
      wheel_j = 0,
      regen_j = 0,
      net_wheel_j = 0,
      source_j = 0,
      distance_m = 0,
      avg_speed_m_s = 0
    ))
  }

  g <- 9.80665
  s <- elevation_profile$s_m
  h <- elevation_profile$elev_m
  ds <- diff(s)
  dh <- diff(h)
  ds[ds <= 0 | !is.finite(ds)] <- NA_real_
  keep <- is.finite(ds) & is.finite(dh)
  ds <- ds[keep]
  dh <- dh[keep]
  if (length(ds) == 0) {
    return(list(wheel_j = 0, regen_j = 0, net_wheel_j = 0, source_j = 0, distance_m = 0, avg_speed_m_s = 0))
  }

  grade <- dh / ds
  distance_m <- sum(ds)
  v <- if (is.finite(total_duration_s) && total_duration_s > 0) distance_m / total_duration_s else 0

  F_roll <- Crr * mass_kg * g
  F_grade <- mass_kg * g * grade
  F_aero <- if (isTRUE(include_aero)) 0.5 * rho_air * CdA * v^2 else 0

  W_pos <- (F_roll + pmax(F_grade, 0) + F_aero) * ds
  W_neg_grade <- pmax(-F_grade, 0) * ds
  regen_j <- sum(W_neg_grade) * regen_eff
  wheel_j <- sum(W_pos)
  net_wheel_j <- max(wheel_j - regen_j, 0)
  source_j <- if (is.finite(drivetrain_eff) && drivetrain_eff > 0) net_wheel_j / drivetrain_eff else NA_real_

  list(
    wheel_j = wheel_j,
    regen_j = regen_j,
    net_wheel_j = net_wheel_j,
    source_j = source_j,
    distance_m = distance_m,
    avg_speed_m_s = v
  )
}

joules_to_kwh <- function(j) j / 3.6e6
