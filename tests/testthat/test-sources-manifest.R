test_that("sources manifest has unique source_id values", {
  manifest <- read_sources_manifest(file.path("..", "..", "sources", "sources_manifest.csv"))
  expect_equal(length(unique(manifest$source_id)), nrow(manifest))
})

test_that("every source PDF and FAF zip has a manifest entry", {
  manifest <- read_sources_manifest(file.path("..", "..", "sources", "sources_manifest.csv"))
  expected <- c(
    list.files(file.path("..", "..", "sources", "pdfs"), pattern = "\\.pdf$", full.names = FALSE),
    list.files(file.path("..", "..", "sources", "FAF5.7.1"), pattern = "\\.zip$", full.names = FALSE)
  )
  expected <- sort(expected)
  in_manifest <- sort(unique(manifest$filename))
  missing <- setdiff(expected, in_manifest)
  expect_true(
    length(missing) == 0,
    label = paste("Missing manifest entries:", paste(missing, collapse = ", "))
  )
})

test_that("source lookup helper resolves by filename", {
  manifest <- read_sources_manifest(file.path("..", "..", "sources", "sources_manifest.csv"))
  sid <- source_id_from_filename(
    "2025 SmartWay Online Logistics Tool Technical Documentation.pdf",
    manifest_df = manifest
  )
  expect_identical(sid, "smartway_olt_2025")
})
