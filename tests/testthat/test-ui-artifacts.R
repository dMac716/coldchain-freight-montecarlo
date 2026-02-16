test_that("UI derived artifacts exist with required columns", {
  flow_path <- file.path("..", "..", "data", "derived", "faf_top_od_flows.csv")
  zone_path <- file.path("..", "..", "data", "derived", "faf_zone_centroids.csv")

  if (!file.exists(flow_path) || !file.exists(zone_path)) {
    skip("Derived UI artifacts not present; run tools/derive_ui_artifacts.R first")
  }

  flows <- utils::read.csv(flow_path, stringsAsFactors = FALSE)
  zones <- utils::read.csv(zone_path, stringsAsFactors = FALSE)

  expect_true(all(c("origin_id", "dest_id", "tons", "ton_miles", "distance_miles", "commodity_group", "scenario_id") %in% names(flows)))
  expect_true(all(c("zone_id", "name", "lat", "lon") %in% names(zones)))
})

test_that("faf_zone_centroids coordinates are bounded", {
  zone_path <- file.path("..", "..", "data", "derived", "faf_zone_centroids.csv")
  skip_if_not(file.exists(zone_path))
  zones <- utils::read.csv(zone_path, stringsAsFactors = FALSE)

  expect_true(all(is.finite(zones$lat)))
  expect_true(all(is.finite(zones$lon)))
  expect_true(all(zones$lat >= -90 & zones$lat <= 90))
  expect_true(all(zones$lon >= -180 & zones$lon <= 180))
})

test_that("flow zone ids exist in zone centroid table", {
  flow_path <- file.path("..", "..", "data", "derived", "faf_top_od_flows.csv")
  zone_path <- file.path("..", "..", "data", "derived", "faf_zone_centroids.csv")
  skip_if_not(file.exists(flow_path) && file.exists(zone_path))

  flows <- utils::read.csv(flow_path, stringsAsFactors = FALSE)
  zones <- utils::read.csv(zone_path, stringsAsFactors = FALSE)

  ids <- unique(as.character(zones$zone_id))
  expect_true(all(as.character(flows$origin_id) %in% ids))
  expect_true(all(as.character(flows$dest_id) %in% ids))
})

test_that("quarto site render is available when Quarto is installed", {
  if (Sys.which("quarto") == "") skip("Quarto CLI not installed in this environment")
  if (!requireNamespace("leaflet", quietly = TRUE)) skip("leaflet package not installed")

  out <- system2("quarto", c("render", "site/"), stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  expect_true(is.null(status) || identical(status, 0L), info = paste(out, collapse = "\n"))
})
