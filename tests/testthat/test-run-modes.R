test_that("normalize_run_mode enforces allowed values", {
  expect_identical(normalize_run_mode("SMOKE_LOCAL"), "SMOKE_LOCAL")
  expect_identical(normalize_run_mode("real_run"), "REAL_RUN")
  expect_identical(normalize_run_mode(NULL), "SMOKE_LOCAL")
  expect_error(normalize_run_mode("prod"))
})

test_that("REAL_RUN data gates reject missing distance and uncalibrated histograms", {
  scenarios <- data.frame(
    scenario = "BASE",
    status = "MISSING_DISTANCE_DATA",
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
