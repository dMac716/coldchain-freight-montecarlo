test_that("run_mc_chunk generates correct number of samples", {
  
  params <- list(
    distance_mean = 500, distance_sd = 100,
    payload_mean = 20, payload_sd = 5,
    temp_mean = 20, temp_sd = 5,
    fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
    refrigeration_prob = 0.3
  )
  
  # Initialize log for testing
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file, overwrite = TRUE)
  
  result <- run_mc_chunk(1, 100, 12345, params)
  
  expect_equal(result$chunk_id, 1)
  expect_equal(result$n_samples, 100)
  expect_equal(result$seed, 12345)
  expect_equal(nrow(result$results), 100)
})


test_that("run_mc_chunk is reproducible with same seed", {
  
  params <- list(
    distance_mean = 500, distance_sd = 100,
    payload_mean = 20, payload_sd = 5,
    temp_mean = 20, temp_sd = 5,
    fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
    refrigeration_prob = 0.3
  )
  
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file, overwrite = TRUE)
  
  result1 <- run_mc_chunk(1, 50, 98765, params)
  result2 <- run_mc_chunk(1, 50, 98765, params)
  
  expect_equal(result1$results$co2_emissions_kg, result2$results$co2_emissions_kg)
})


test_that("run_mc_chunk produces different results with different seeds", {
  
  params <- list(
    distance_mean = 500, distance_sd = 100,
    payload_mean = 20, payload_sd = 5,
    temp_mean = 20, temp_sd = 5,
    fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
    refrigeration_prob = 0.3
  )
  
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file, overwrite = TRUE)
  
  result1 <- run_mc_chunk(1, 50, 11111, params)
  result2 <- run_mc_chunk(2, 50, 22222, params)
  
  expect_false(identical(result1$results$co2_emissions_kg, result2$results$co2_emissions_kg))
})


test_that("run_mc_chunk includes moments", {
  
  params <- list(
    distance_mean = 500, distance_sd = 100,
    payload_mean = 20, payload_sd = 5,
    temp_mean = 20, temp_sd = 5,
    fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
    refrigeration_prob = 0.3
  )
  
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file, overwrite = TRUE)
  
  result <- run_mc_chunk(1, 100, 12345, params)
  
  expect_true(!is.null(result$moments))
  expect_true(!is.null(result$moments$mean))
  expect_true(!is.null(result$moments$variance))
  expect_equal(result$moments$n, 100)
})


test_that("run_mc_chunk includes histograms", {
  
  params <- list(
    distance_mean = 500, distance_sd = 100,
    payload_mean = 20, payload_sd = 5,
    temp_mean = 20, temp_sd = 5,
    fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
    refrigeration_prob = 0.3
  )
  
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file, overwrite = TRUE)
  
  result <- run_mc_chunk(1, 100, 12345, params)
  
  expect_true(!is.null(result$histogram_dry))
  expect_true(!is.null(result$histogram_refrigerated))
  expect_equal(result$histogram_dry$type, "dry")
  expect_equal(result$histogram_refrigerated$type, "refrigerated")
})
