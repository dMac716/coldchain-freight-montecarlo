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
