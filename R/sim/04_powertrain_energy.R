# Powertrain energy/fuel models.

compute_gross_lb <- function(payload_lb, trailer_tare_lb, tractor_weight_lb = 22000) {
  as.numeric(payload_lb) + as.numeric(trailer_tare_lb) + as.numeric(tractor_weight_lb)
}

compute_propulsion_kwh_segment <- function(
    seg_miles,
    speed_mph,
    grade,
    payload_lb,
    trailer_tare_lb,
    tractor_weight_lb,
    coeff = list(base = 1.6, mass = 2.5e-5, grade = 0.7, speed2 = 2e-4, baseline_mass_lb = 60000)) {
  seg_miles <- as.numeric(seg_miles)
  speed_mph <- as.numeric(speed_mph)
  grade <- as.numeric(grade)
  if (!is.finite(seg_miles) || seg_miles <= 0) return(0)
  if (!is.finite(speed_mph) || speed_mph < 0) speed_mph <- 0
  if (!is.finite(grade)) grade <- 0

  gross_lb <- compute_gross_lb(payload_lb, trailer_tare_lb, tractor_weight_lb)
  if (!is.finite(gross_lb)) gross_lb <- as.numeric(coeff$baseline_mass_lb %||% 60000)
  base <- as.numeric(coeff$base %||% 1.6)
  a <- as.numeric(coeff$mass %||% 2.5e-5)
  b <- as.numeric(coeff$grade %||% 0.7)
  c <- as.numeric(coeff$speed2 %||% 2e-4)
  m0 <- as.numeric(coeff$baseline_mass_lb %||% 60000)
  per_mile <- base + a * (gross_lb - m0) + b * max(0, grade) + c * speed_mph^2
  if (!is.finite(per_mile)) per_mile <- base
  max(0.05, per_mile) * seg_miles
}

compute_diesel_gal_segment <- function(seg_miles, mpg) {
  mpg <- max(0.1, as.numeric(mpg))
  seg_miles / mpg
}

compute_charge_minutes <- function(current_soc, target_soc, battery_kwh, max_power_kw, charge_curve, rng = NULL) {
  current_soc <- max(0, min(1, current_soc))
  target_soc <- max(current_soc, min(1, target_soc))
  if (target_soc <= current_soc) return(0)

  stage_soc <- as.numeric(charge_curve$stage1_to_soc %||% 0.8)
  p1f <- sim_pick_distribution(charge_curve$stage1_power_fraction_of_max, rng = rng)
  p2f <- sim_pick_distribution(charge_curve$stage2_power_fraction_of_max, rng = rng)
  p1 <- max(1, as.numeric(max_power_kw) * max(0.05, p1f))
  p2 <- max(0.5, as.numeric(max_power_kw) * max(0.01, p2f))

  e1 <- max(0, min(target_soc, stage_soc) - current_soc) * battery_kwh
  e2 <- max(0, target_soc - max(current_soc, stage_soc)) * battery_kwh
  (e1 / p1 + e2 / p2) * 60
}
