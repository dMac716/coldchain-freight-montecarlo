test_that("BigQuery identifier validation is conservative and safe", {
  source(file.path("..", "..", "tools", "faf_bq", "bq_utils.R"))

  expect_silent(validate_bq_identifier("project", "my-proj-123"))
  expect_error(validate_bq_identifier("project", "my_proj"))
  expect_error(validate_bq_identifier("project", "my.proj"))

  expect_silent(validate_bq_identifier("dataset", "my_dataset_1"))
  expect_error(validate_bq_identifier("dataset", "my-dataset"))
  expect_error(validate_bq_identifier("dataset", "ds;drop"))

  expect_silent(validate_bq_identifier("table", "faf_od_2024"))
  expect_error(validate_bq_identifier("table", "t;select 1"))
  expect_error(validate_bq_identifier("table", "t-name"))
})

