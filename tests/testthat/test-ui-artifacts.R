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

is_quarto_restricted_env_failure <- function(output_lines, status) {
  if (is.null(status) || identical(status, 0L)) {
    return(FALSE)
  }

  output <- paste(output_lines, collapse = "\n")
  grepl(
    paste(
      "quarto script failed: unrecognized architecture",
      "sysctl.*Operation not permitted",
      "bad CPU type in executable",
      sep = "|"
    ),
    output,
    ignore.case = TRUE
  )
}

test_that("quarto site render is available when Quarto is installed", {
  if (Sys.which("quarto") == "") skip("Quarto CLI not installed in this environment")
  if (!requireNamespace("leaflet", quietly = TRUE)) skip("leaflet package not installed")

  out <- system2("quarto", c("render", "site/"), stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")

  if (is_quarto_restricted_env_failure(out, status)) {
    skip("Quarto installed but not runnable in restricted environment")
  }

  expect_true(is.null(status) || identical(status, 0L), info = paste(out, collapse = "\n"))
})

test_that("quarto restricted environment failures are detected", {
  out <- c(
    "sysctl: sysctl fmt -1 1024 1: Operation not permitted",
    "quarto script failed: unrecognized architecture"
  )
  expect_true(is_quarto_restricted_env_failure(out, status = 1L))
})

test_that("quarto unrelated failures are not marked as restricted environment", {
  out <- "ERROR: site input directory not found"
  expect_false(is_quarto_restricted_env_failure(out, status = 1L))
})
