test_that("FAF zip contains at least one CSV entry", {
  zip_path <- file.path("..", "..", "sources", "FAF5.7.1", "FAF5.7.1_2018-2024.zip")
  if (!file.exists(zip_path)) skip("FAF zip not present in test environment")

  listing <- utils::unzip(zip_path, list = TRUE)
  expect_true(any(grepl("\\.csv$", listing$Name, ignore.case = TRUE)))
})
