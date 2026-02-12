test_that("init_reproducibility_log creates log file", {
  
  log_file <- tempfile(fileext = ".json")
  
  result <- init_reproducibility_log(log_file)
  
  expect_true(file.exists(log_file))
  expect_equal(result, log_file)
  
  # Read and check structure
  log_data <- jsonlite::read_json(log_file)
  expect_true(!is.null(log_data$session_info))
  expect_true(!is.null(log_data$events))
  
  # Clean up
  unlink(log_file)
})


test_that("init_reproducibility_log includes session info", {
  
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file)
  
  log_data <- jsonlite::read_json(log_file)
  
  expect_true(!is.null(log_data$session_info$r_version))
  expect_true(!is.null(log_data$session_info$platform))
  expect_true(!is.null(log_data$session_info$timestamp))
  
  unlink(log_file)
})


test_that("log_event adds events to log", {
  
  log_file <- tempfile(fileext = ".json")
  init_reproducibility_log(log_file)
  
  log_event("test_event", list(value = 42, name = "test"))
  log_event("another_event", list(status = "success"))
  
  log_data <- jsonlite::read_json(log_file)
  
  expect_equal(length(log_data$events), 2)
  expect_equal(log_data$events[[1]]$event_type, "test_event")
  expect_equal(log_data$events[[2]]$event_type, "another_event")
  
  unlink(log_file)
})


test_that("log_event handles missing log file gracefully", {
  
  # Clear option
  options(coldchainfreight.log_file = NULL)
  
  expect_warning(
    log_event("test", list()),
    "No log file initialized"
  )
})


test_that("get_reproducibility_hash generates consistent hash", {
  
  hash1 <- get_reproducibility_hash()
  hash2 <- get_reproducibility_hash()
  
  expect_type(hash1, "character")
  expect_equal(nchar(hash1), 32)  # MD5 hash length
  expect_equal(hash1, hash2)  # Should be identical in same session
})


test_that("init_reproducibility_log respects overwrite parameter", {
  
  log_file <- tempfile(fileext = ".json")
  
  init_reproducibility_log(log_file)
  log_event("first", list())
  
  # Try to init again without overwrite
  expect_error(
    init_reproducibility_log(log_file, overwrite = FALSE),
    "already exists"
  )
  
  # With overwrite should work
  init_reproducibility_log(log_file, overwrite = TRUE)
  log_data <- jsonlite::read_json(log_file)
  expect_equal(length(log_data$events), 0)  # Should be reset
  
  unlink(log_file)
})
