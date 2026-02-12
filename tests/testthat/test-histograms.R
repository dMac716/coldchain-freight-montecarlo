test_that("create_histogram creates valid histogram", {
  
  values <- rnorm(1000, 100, 20)
  hist <- create_histogram(values, "test")
  
  expect_equal(hist$type, "test")
  expect_equal(hist$n, 1000)
  expect_true(length(hist$breaks) > 0)
  expect_true(length(hist$counts) > 0)
  expect_equal(length(hist$counts), length(hist$breaks) - 1)
})


test_that("create_histogram handles empty input", {
  
  hist <- create_histogram(numeric(0), "empty")
  
  expect_equal(hist$type, "empty")
  expect_equal(hist$n, 0)
  expect_equal(length(hist$counts), 0)
})


test_that("merge_histograms combines counts correctly", {
  
  set.seed(123)
  h1 <- create_histogram(rnorm(100, 100, 10), "test", breaks = 20)
  h2 <- create_histogram(rnorm(100, 100, 10), "test", breaks = 20)
  
  merged <- merge_histograms(list(h1, h2))
  
  expect_equal(merged$n, h1$n + h2$n)
  expect_equal(merged$type, "test")
})


test_that("merge_histograms handles empty histograms", {
  
  h1 <- create_histogram(rnorm(100, 100, 10), "test")
  h2 <- create_histogram(numeric(0), "test")
  
  merged <- merge_histograms(list(h1, h2))
  
  expect_equal(merged$n, h1$n)
})


test_that("aggregate_histograms works with chunk results", {
  
  params <- list(
    distance_mean = 500, distance_sd = 100,
    payload_mean = 20, payload_sd = 5,
    temp_mean = 20, temp_sd = 5,
    fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
    refrigeration_prob = 0.3
  )
  
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file, overwrite = TRUE)
  
  chunk1 <- run_mc_chunk(1, 100, 111, params)
  chunk2 <- run_mc_chunk(2, 100, 222, params)
  
  chunks <- list(chunk1, chunk2)
  
  agg_dry <- aggregate_histograms(chunks, "dry")
  agg_refrig <- aggregate_histograms(chunks, "refrigerated")
  
  expect_true(agg_dry$n > 0)
  expect_equal(agg_dry$type, "dry")
  expect_equal(agg_refrig$type, "refrigerated")
})
