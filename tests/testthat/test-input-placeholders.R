test_that("products and factors contain no placeholder markers", {
  products <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "products.csv"), stringsAsFactors = FALSE)
  factors <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "factors.csv"), stringsAsFactors = FALSE)

  expect_false(any(grepl("PLACEHOLDER", unlist(products), fixed = TRUE)))
  expect_false(any(grepl("PLACEHOLDER", unlist(factors), fixed = TRUE)))
})

test_that("scenarios and histogram remain explicitly pending where expected", {
  scenarios <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "scenarios.csv"), stringsAsFactors = FALSE)
  hist_cfg <- utils::read.csv(file.path("..", "..", "data", "inputs_local", "histogram_config.csv"), stringsAsFactors = FALSE)

  base_row <- subset(scenarios, scenario == "BASE")
  expect_equal(nrow(base_row), 1)
  expect_identical(base_row$status[[1]], "MISSING_DISTANCE_DATA")

  expect_true(all(hist_cfg$status == "TO_CALIBRATE_AFTER_FIRST_REAL_RUN"))
})
