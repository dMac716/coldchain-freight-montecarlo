compute_emissions_deterministic <- function(inputs) {
  validate_inputs(inputs)

  mass_dry_kg <- mass_per_fu_kg(
    FU_kcal = inputs$FU_kcal,
    kcal_per_kg = inputs$kcal_per_kg_dry,
    pkg_kg_per_kg_product = inputs$pkg_kg_per_kg_dry
  )
  mass_reefer_kg <- mass_per_fu_kg(
    FU_kcal = inputs$FU_kcal,
    kcal_per_kg = inputs$kcal_per_kg_reefer,
    pkg_kg_per_kg_product = inputs$pkg_kg_per_kg_reefer
  )

  gco2_dry <- kg_to_tons(mass_dry_kg) *
    inputs$distance_miles *
    inputs$truck_g_per_ton_mile *
    inputs$util_dry

  gco2_reefer <- kg_to_tons(mass_reefer_kg) *
    inputs$distance_miles *
    (inputs$truck_g_per_ton_mile + inputs$reefer_extra_g_per_ton_mile) *
    inputs$util_reefer

  diff_gco2 <- gco2_reefer - gco2_dry
  ratio <- if (gco2_dry == 0) NA_real_ else gco2_reefer / gco2_dry

  list(
    gco2_dry = gco2_dry,
    gco2_reefer = gco2_reefer,
    diff_gco2 = diff_gco2,
    ratio = ratio
  )
}

compute_emissions_intensity <- function(
    powertrain,
    default_payload_tons,
    co2_g_per_ton_mile = NA_real_,
    co2_g_per_mile = NA_real_,
    kwh_per_mile_tract = NA_real_,
    kwh_per_mile_tru = 0,
    grid_co2_g_per_kwh = NA_real_) {
  payload <- suppressWarnings(as.numeric(default_payload_tons))
  if (!is.finite(payload) || payload <= 0) {
    stop("default_payload_tons must be finite and > 0.")
  }

  powertrain <- tolower(trimws(powertrain))
  if (!powertrain %in% c("diesel", "bev")) {
    stop("powertrain must be one of: diesel, bev.")
  }

  if (powertrain == "diesel") {
    total_ton <- suppressWarnings(as.numeric(co2_g_per_ton_mile))
    total_mile <- suppressWarnings(as.numeric(co2_g_per_mile))
    if (!is.finite(total_ton) && is.finite(total_mile)) {
      total_ton <- total_mile / payload
    }
    if (!is.finite(total_ton) || total_ton < 0) {
      stop("Diesel intensity requires co2_g_per_ton_mile or co2_g_per_mile.")
    }
    if (!is.finite(total_mile)) total_mile <- total_ton * payload
    return(list(
      tractor_g_per_ton_mile = total_ton,
      tru_g_per_ton_mile = 0,
      total_g_per_ton_mile = total_ton,
      total_g_per_mile = total_mile
    ))
  }

  kwh_tract <- suppressWarnings(as.numeric(kwh_per_mile_tract))
  kwh_tru <- suppressWarnings(as.numeric(kwh_per_mile_tru))
  grid_ci <- suppressWarnings(as.numeric(grid_co2_g_per_kwh))
  if (!is.finite(kwh_tru)) kwh_tru <- 0
  if (!all(is.finite(c(kwh_tract, grid_ci)))) {
    stop("BEV intensity requires kwh_per_mile_tract and grid_co2_g_per_kwh.")
  }
  if (kwh_tract < 0 || kwh_tru < 0 || grid_ci < 0) {
    stop("BEV intensity terms must be >= 0.")
  }

  tractor_mile <- kwh_tract * grid_ci
  tru_mile <- kwh_tru * grid_ci
  total_mile <- tractor_mile + tru_mile

  list(
    tractor_g_per_ton_mile = tractor_mile / payload,
    tru_g_per_ton_mile = tru_mile / payload,
    total_g_per_ton_mile = total_mile / payload,
    total_g_per_mile = total_mile
  )
}
