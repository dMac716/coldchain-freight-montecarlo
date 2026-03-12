test_that("normalize_run_mode enforces allowed values", {
  expect_identical(normalize_run_mode("SMOKE_LOCAL"), "SMOKE_LOCAL")
  expect_identical(normalize_run_mode("real_run"), "REAL_RUN")
  expect_identical(normalize_run_mode(NULL), "SMOKE_LOCAL")
  expect_error(normalize_run_mode("prod"))
})

test_that("normalize_distance_mode enforces allowed values and defaults", {
  expect_identical(normalize_distance_mode(NULL), "FAF_DISTRIBUTION")
  expect_identical(normalize_distance_mode("road_network_fixed_dest"), "ROAD_NETWORK_FIXED_DEST")
  expect_identical(normalize_distance_mode("ROAD_NETWORK_PHYSICS"), "ROAD_NETWORK_PHYSICS")
  expect_error(normalize_distance_mode("unknown_mode"))
})

test_that("REAL_RUN data gates reject missing distance and uncalibrated histograms", {
  scenarios <- data.frame(
    scenario_id = "BASE",
    status = "MISSING_DISTANCE_DATA",
    distance_distribution_id = "dist_base",
    stringsAsFactors = FALSE
  )
  hist_cfg <- data.frame(
    metric = c("gco2_dry"),
    min = 0,
    max = 1,
    bins = 10,
    status = "TO_CALIBRATE_AFTER_FIRST_REAL_RUN",
    stringsAsFactors = FALSE
  )
  expect_error(assert_mode_data_ready("REAL_RUN", scenarios, hist_cfg, scenario_name = "BASE"))
  expect_silent(assert_mode_data_ready("SMOKE_LOCAL", scenarios, hist_cfg, scenario_name = "BASE"))
})

test_that("REAL_RUN fails when variant or priors are NEEDS_SOURCE_VALUE", {
  scenarios <- data.frame(
    scenario_id = "CENTRALIZED",
    status = "OK",
    distance_distribution_id = "dist_ok",
    stringsAsFactors = FALSE
  )
  hist_cfg <- data.frame(
    metric = c("gco2_dry"),
    min = 0,
    max = 1,
    bins = 10,
    status = "CALIBRATED_FROM_PILOT",
    stringsAsFactors = FALSE
  )
  variant <- data.frame(
    variant_id = "CENTRALIZED_BEV_DRY",
    scenario_id = "CENTRALIZED",
    powertrain = "bev",
    trailer_type = "dry_van",
    refrigeration_mode = "none",
    status = "NEEDS_SOURCE_VALUE",
    stringsAsFactors = FALSE
  )
  inputs <- list(
    emissions_factors = data.frame(
      powertrain = "bev",
      trailer_type = "dry_van",
      refrigeration_mode = "none",
      status = "OK",
      stringsAsFactors = FALSE
    ),
    distance_distributions = data.frame(
      distance_distribution_id = "dist_ok",
      status = "OK",
      stringsAsFactors = FALSE
    )
  )

  priors <- as.list(setNames(rep(1, length(required_model_param_ids())), required_model_param_ids()))
  priors <- lapply(priors, function(x) list(status = "OK"))
  expect_error(assert_mode_data_ready("REAL_RUN", scenarios, hist_cfg,
    scenario_name = "CENTRALIZED", variant_row = variant, inputs = inputs, priors_map = priors
  ))

  variant$status <- "OK"
  priors$grid_co2_g_per_kwh <- list(status = "NEEDS_SOURCE_VALUE")
  expect_error(assert_mode_data_ready("REAL_RUN", scenarios, hist_cfg,
    scenario_name = "CENTRALIZED", variant_row = variant, inputs = inputs, priors_map = priors
  ))
})

test_that("hist coverage enforcement warns in smoke and fails in real", {
  h <- list(
    m = list(
      bin_edges = c(0, 1, 2),
      counts = c(5L, 5L),
      underflow = 1L,
      overflow = 1L
    )
  )
  n_list <- list(m = 12L)
  expect_warning(enforce_hist_coverage(h, n_list = n_list, mode = "SMOKE_LOCAL", threshold = 0.001))
  expect_error(enforce_hist_coverage(h, n_list = n_list, mode = "REAL_RUN", threshold = 0.001))
})

test_that("scenario matrix requires proposal dimension columns", {
  ok <- data.frame(
    variant_id = "X",
    scenario_id = "CENTRALIZED",
    product_mode = "DRY",
    spatial_structure = "CENTRALIZED",
    powertrain = "diesel",
    powertrain_config = "DIESEL_TRU_DIESEL",
    trailer_type = "dry_van",
    refrigeration_mode = "none",
    stringsAsFactors = FALSE
  )
  expect_silent(assert_variant_dimensions_present(ok))
  expect_error(assert_variant_dimensions_present(ok[, c("variant_id", "scenario_id"), drop = FALSE]))
})
