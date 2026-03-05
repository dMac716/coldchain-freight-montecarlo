source(file.path("..", "..", "R", "sim", "10_run_bundle.R"), local = FALSE)

test_that("lci_apply_process_key_map remaps composition keys to explicit sheet mappings", {
  td <- tempfile("lci_map_")
  dir.create(td, recursive = TRUE)
  mp <- file.path(td, "lci_process_key_map.csv")
  utils::write.csv(
    data.frame(
      process_key = c("cooling", "beef"),
      sheet_name = c("Cooling Sheet", "Beef Sheet"),
      stringsAsFactors = FALSE
    ),
    mp,
    row.names = FALSE
  )

  intensity <- data.frame(
    sheet_name = c("Cooling Sheet", "Beef Sheet", "Other Sheet"),
    process_key = c("coolingsheet", "beefsheet", "othersheet"),
    co2e_kg_per_unit = c(1.1, 2.2, 3.3),
    stringsAsFactors = FALSE
  )

  cfg <- list(lci = list(process_key_map_path = mp))
  out <- lci_apply_process_key_map(intensity, cfg)

  expect_true(any(out$process_key == "cooling"))
  expect_true(any(out$process_key == "beef"))
  expect_equal(out$co2e_kg_per_unit[out$process_key == "cooling"][[1]], 1.1, tolerance = 1e-12)
  expect_equal(out$co2e_kg_per_unit[out$process_key == "beef"][[1]], 2.2, tolerance = 1e-12)
})
