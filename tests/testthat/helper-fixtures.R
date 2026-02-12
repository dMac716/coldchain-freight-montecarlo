# helper-fixtures.R
# Central fixtures and helpers for deterministic regression testing.

library(testthat)

fixture_inputs_small <- function() {
  list(
    FU_kcal = 1000,
    kcal_per_kg_dry = 3500,
    kcal_per_kg_reefer = 1300,
    pkg_kg_per_kg_dry = 0.05,
    pkg_kg_per_kg_reefer = 0.12,
    distance_miles = 1200,
    truck_g_per_ton_mile = 160,
    reefer_extra_g_per_ton_mile = 25,
    util_dry = 1.00,
    util_reefer = 1.05
  )
}

# Deterministic histogram config for tests
fixture_hist_config <- function() {
  list(
    metric = c("gco2_dry", "gco2_reefer", "diff_gco2", "ratio"),
    # Chosen to safely cover plausible ranges for fixtures
    min = c(0, 0, -10000, 0),
    max = c(50000, 50000, 50000, 5),
    bins = c(200, 200, 200, 200)
  )
}

# Golden outputs: store only for deterministic small case.
# Update ONLY when changes are intentional and justified.
fixture_golden <- function() {
  list(
    # Put expected deterministic outputs here once core functions exist.
    # Example placeholders:
    gco2_dry = NA_real_,
    gco2_reefer = NA_real_,
    diff_gco2 = NA_real_,
    ratio = NA_real_
  )
}
