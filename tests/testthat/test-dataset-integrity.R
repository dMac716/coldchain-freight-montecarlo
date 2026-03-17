## tests/testthat/test-dataset-integrity.R
## Validates analysis dataset integrity against known baselines.
## Catches indiscriminate merges that corrupt diesel baseline or include broken BEV runs.

repo_root <- rprojroot::find_root(rprojroot::has_file("_targets.R"))

# Known validated diesel baselines from March 16, 2026
# These must NOT change unless the model equations or input factors change.
DIESEL_BASELINE <- list(
  dry_co2_fu_mean     = 0.0283,   # +/- 5% tolerance
  refrig_co2_fu_mean  = 0.0480,
  dry_distance_mean   = 615,      # +/- 10% tolerance
  refrig_distance_mean = 616,
  dry_count_min       = 1700,     # minimum expected per origin_network

  refrig_count_min    = 21000
)

find_analysis_dataset <- function() {
  candidates <- c(
    file.path(repo_root, "artifacts", "analysis_final_2026-03-17", "analysis_dataset_combined_validated.csv.gz"),
    file.path(repo_root, "artifacts", "analysis_final_2026-03-17", "analysis_dataset.csv.gz"),
    Sys.glob(file.path(repo_root, "artifacts", "analysis_final_*", "analysis_dataset*.csv.gz"))
  )
  for (f in candidates) if (file.exists(f)) return(f)
  NULL
}

test_that("analysis dataset exists", {
  ds <- find_analysis_dataset()
  skip_if(is.null(ds), "No analysis dataset found")
  expect_true(file.exists(ds))
})

test_that("diesel baseline CO2/FU unchanged from validated values", {
  ds <- find_analysis_dataset()
  skip_if(is.null(ds), "No analysis dataset found")

  dt <- data.table::fread(cmd = sprintf("gunzip -c '%s'", ds), showProgress = FALSE)

  # Derive FU if missing
  if (all(is.na(dt$co2_per_1000kcal)) || sum(!is.na(dt$co2_per_1000kcal)) == 0) {
    dt[, payload_kg := payload_max_lb_draw * load_fraction * 0.453592]
    dt[, kcal_delivered := payload_kg * kcal_per_kg_product]
    dt[, co2_per_1000kcal := co2_kg_total / kcal_delivered * 1000]
  }

  diesel <- dt[powertrain == "diesel"]
  skip_if(nrow(diesel) == 0, "No diesel runs in dataset")

  dry_diesel <- diesel[product_type == "dry"]
  refrig_diesel <- diesel[product_type == "refrigerated"]

  if (nrow(dry_diesel) > 0) {
    dry_co2 <- mean(dry_diesel$co2_per_1000kcal, na.rm = TRUE)
    expect_true(
      abs(dry_co2 - DIESEL_BASELINE$dry_co2_fu_mean) / DIESEL_BASELINE$dry_co2_fu_mean < 0.05,
      info = sprintf("Dry diesel CO2/FU drifted: got %.4f, expected ~%.4f (+/-5%%)", dry_co2, DIESEL_BASELINE$dry_co2_fu_mean)
    )
  }

  if (nrow(refrig_diesel) > 0) {
    refrig_co2 <- mean(refrig_diesel$co2_per_1000kcal, na.rm = TRUE)
    expect_true(
      abs(refrig_co2 - DIESEL_BASELINE$refrig_co2_fu_mean) / DIESEL_BASELINE$refrig_co2_fu_mean < 0.05,
      info = sprintf("Refrig diesel CO2/FU drifted: got %.4f, expected ~%.4f (+/-5%%)", refrig_co2, DIESEL_BASELINE$refrig_co2_fu_mean)
    )
  }
})

test_that("diesel distances stable", {
  ds <- find_analysis_dataset()
  skip_if(is.null(ds), "No analysis dataset found")

  dt <- data.table::fread(cmd = sprintf("gunzip -c '%s'", ds), showProgress = FALSE)
  diesel <- dt[powertrain == "diesel"]
  skip_if(nrow(diesel) == 0, "No diesel runs")

  dry_dist <- mean(diesel[product_type == "dry"]$distance_miles, na.rm = TRUE)
  refrig_dist <- mean(diesel[product_type == "refrigerated"]$distance_miles, na.rm = TRUE)

  expect_true(abs(dry_dist - DIESEL_BASELINE$dry_distance_mean) / DIESEL_BASELINE$dry_distance_mean < 0.10,
              info = sprintf("Dry diesel distance drifted: %.0f vs expected ~%d", dry_dist, DIESEL_BASELINE$dry_distance_mean))
  expect_true(abs(refrig_dist - DIESEL_BASELINE$refrig_distance_mean) / DIESEL_BASELINE$refrig_distance_mean < 0.10,
              info = sprintf("Refrig diesel distance drifted: %.0f vs expected ~%d", refrig_dist, DIESEL_BASELINE$refrig_distance_mean))
})

test_that("diesel run counts meet minimums", {
  ds <- find_analysis_dataset()
  skip_if(is.null(ds), "No analysis dataset found")

  dt <- data.table::fread(cmd = sprintf("gunzip -c '%s'", ds), showProgress = FALSE)
  diesel <- dt[powertrain == "diesel"]
  skip_if(nrow(diesel) == 0, "No diesel runs")

  dry_n <- nrow(diesel[product_type == "dry"])
  refrig_n <- nrow(diesel[product_type == "refrigerated"])

  expect_gte(dry_n, DIESEL_BASELINE$dry_count_min,
             info = sprintf("Dry diesel count too low: %d < %d", dry_n, DIESEL_BASELINE$dry_count_min))
  expect_gte(refrig_n, DIESEL_BASELINE$refrig_count_min,
             info = sprintf("Refrig diesel count too low: %d < %d", refrig_n, DIESEL_BASELINE$refrig_count_min))
})

test_that("no BEV runs with charge_stops == 0 in final dataset (post-fix)", {
  ds <- find_analysis_dataset()
  skip_if(is.null(ds), "No analysis dataset found")

  dt <- data.table::fread(cmd = sprintf("gunzip -c '%s'", ds), showProgress = FALSE)
  bev <- dt[powertrain == "bev"]
  skip_if(nrow(bev) == 0, "No BEV runs")

  zero_charge <- nrow(bev[charge_stops == 0 | is.na(charge_stops)])
  pct_zero <- 100 * zero_charge / nrow(bev)

  # Allow up to 5% zero-charge (some very short routes may legitimately not need charging)
  expect_true(pct_zero < 5,
              info = sprintf("%.1f%% of BEV runs have charge_stops=0 — likely includes pre-fix broken runs", pct_zero))
})

test_that("BEV runs have realistic distances (> 1000 mi for full corridor)", {
  ds <- find_analysis_dataset()
  skip_if(is.null(ds), "No analysis dataset found")

  dt <- data.table::fread(cmd = sprintf("gunzip -c '%s'", ds), showProgress = FALSE)
  bev <- dt[powertrain == "bev"]
  skip_if(nrow(bev) == 0, "No BEV runs")

  mean_dist <- mean(bev$distance_miles, na.rm = TRUE)
  # Full corridor is ~1712 mi; post-fix BEV should average > 1000
  expect_true(mean_dist > 1000,
              info = sprintf("BEV mean distance %.0f mi is too low — likely includes truncated pre-fix runs", mean_dist))
})
