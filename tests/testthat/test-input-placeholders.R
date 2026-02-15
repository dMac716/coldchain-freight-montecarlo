test_that("products and emissions factors contain no placeholder markers", {
  products <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "products.csv"), stringsAsFactors = FALSE)
  emissions <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "emissions_factors.csv"), stringsAsFactors = FALSE)

  expect_false(any(grepl("PLACEHOLDER", unlist(products), fixed = TRUE)))
  expect_false(any(grepl("PLACEHOLDER", unlist(emissions), fixed = TRUE)))
  expect_false(any(grepl("MISSING_", emissions$status, fixed = TRUE)))
})

test_that("scenario matrix contains no MISSING statuses", {
  matrix <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "scenario_matrix.csv"), stringsAsFactors = FALSE)
  expect_false(any(grepl("MISSING_", matrix$status, fixed = TRUE)))
})

test_that("products schema includes required locked-scope columns", {
  products <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "products.csv"), stringsAsFactors = FALSE)
  req <- c(
    "product_id", "preservation", "kcal_per_kg", "kcal_per_cup",
    "moisture_pct_as_fed", "packaging_mass_frac", "source_id", "source_page"
  )
  expect_true(all(req %in% names(products)))
})

test_that("scenarios have explicit statuses and histogram remains pending calibration", {
  scenarios <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "scenarios.csv"), stringsAsFactors = FALSE)
  hist_cfg <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "histogram_config.csv"), stringsAsFactors = FALSE)

  expect_true(all(c("CENTRALIZED", "REGIONALIZED", "SMOKE_LOCAL") %in% scenarios$scenario_id))
  expect_true(all(!is.na(scenarios$status) & nzchar(scenarios$status)))

  expect_true(all(hist_cfg$status == "TO_CALIBRATE_AFTER_FIRST_REAL_RUN"))
})
