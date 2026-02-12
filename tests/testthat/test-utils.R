test_that("print_chunk_summary works", {
  
  params <- list(
    distance_mean = 500, distance_sd = 100,
    payload_mean = 20, payload_sd = 5,
    temp_mean = 20, temp_sd = 5,
    fuel_efficiency_mean = 30, fuel_efficiency_sd = 5,
    refrigeration_prob = 0.3
  )
  
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file, overwrite = TRUE)
  
  chunk <- run_mc_chunk(1, 100, 12345, params)
  
  # Should not error
  expect_silent(print_chunk_summary(chunk))
})


test_that("validate_contribution_artifact checks required fields", {
  
  # Create a minimal valid artifact
  artifact <- list(
    simulation_id = "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6",
    timestamp = "2024-01-01T00:00:00Z",
    parameters = list(
      distance_mean = 500,
      distance_sd = 100,
      payload_mean = 20,
      payload_sd = 5,
      temp_mean = 20,
      temp_sd = 5,
      fuel_efficiency_mean = 30,
      fuel_efficiency_sd = 5,
      refrigeration_prob = 0.3
    ),
    base_seed = 42,
    n_chunks = 10,
    chunk_size = 1000,
    total_samples = 10000,
    summary_statistics = list(
      total_samples = 10000,
      n_dry = 7000,
      n_refrigerated = 3000,
      overall_mean_co2 = 500,
      overall_sd_co2 = 50
    ),
    reproducibility_hash = "b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7"
  )
  
  # Save to temp file
  temp_file <- tempfile(fileext = ".json")
  jsonlite::write_json(artifact, temp_file, auto_unbox = TRUE)
  
  # Should validate
  expect_true(validate_contribution_artifact(temp_file))
  
  # Clean up
  unlink(temp_file)
})


test_that("compare_simulations produces output", {
  
  result1 <- list(
    n = 1000,
    mean = 500,
    variance = 2500,
    skewness = 0.1,
    kurtosis = 0.05
  )
  
  result2 <- list(
    n = 1000,
    mean = 550,
    variance = 2600,
    skewness = 0.12,
    kurtosis = 0.06
  )
  
  # Should not error
  expect_silent(compare_simulations(result1, result2))
})
