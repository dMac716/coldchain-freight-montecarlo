test_that("make_presentation_artifacts writes required snapshot outputs", {
  td <- tempfile("present_")
  dir.create(td, recursive = TRUE)
  bundle_dir <- file.path(td, "run_bundle")
  outdir <- file.path(td, "presentation")
  dir.create(bundle_dir, recursive = TRUE)

  make_bundle <- function(run_id, scenario, pair_id, origin_network, powertrain, seed, co2_1000, co2_protein) {
    bd <- file.path(bundle_dir, run_id)
    dir.create(bd, recursive = TRUE)
    sm <- data.frame(
      run_id = run_id,
      pair_id = pair_id,
      scenario = scenario,
      product_type = "refrigerated",
      origin_network = origin_network,
      route_id = "retail_1",
      co2_per_1000kcal = co2_1000,
      co2_per_kg_protein = co2_protein,
      delivery_time_min = 500,
      trucker_hours_per_1000kcal = 0.2,
      driver_driving_min = 300,
      time_charging_min = if (powertrain == "bev") 40 else 0,
      time_refuel_min = if (powertrain == "diesel") 20 else 0,
      driver_off_duty_min = 30,
      time_load_unload_min = 45,
      time_traffic_delay_min = 25,
      limiting_constraint = "cube",
      cube_utilization_pct = 85,
      payload_utilization_pct = 70,
      truckloads_per_1e6_kcal = 2.5,
      truckloads_per_1000kg_product = 1.8,
      stringsAsFactors = FALSE
    )
    utils::write.csv(sm, file.path(bd, "summaries.csv"), row.names = FALSE)
    jsonlite::write_json(list(
      run_id = run_id,
      scenario = scenario,
      seed = seed,
      powertrain = powertrain,
      facility_id = "FAC_1",
      config = list(
        load_model = list(trailer = list(pallets_max = 26)),
        driver_time = list(pretrip_inspection_min = 15),
        hos = list(enabled = TRUE)
      )
    ), file.path(bd, "params.json"), auto_unbox = TRUE, pretty = TRUE)
  }

  make_bundle("run_a", "SCEN_A", "pair_1", "dry_factory_set", "bev", 101, 10, 2.0)
  make_bundle("run_b", "SCEN_A", "pair_1", "refrigerated_factory_set", "bev", 101, 11, 2.4)
  make_bundle("run_c", "SCEN_A", "pair_2", "dry_factory_set", "diesel", 102, 12, 2.1)
  make_bundle("run_d", "SCEN_A", "pair_2", "refrigerated_factory_set", "diesel", 102, 13, 2.5)

  cmd <- c(
    file.path("..", "..", "tools", "make_presentation_artifacts.R"),
    "--bundle_dir", bundle_dir,
    "--outdir", outdir
  )
  status <- system2("Rscript", cmd, stdout = TRUE, stderr = TRUE)
  expect_true(is.null(attr(status, "status")) || identical(attr(status, "status"), 0L))

  expect_true(file.exists(file.path(outdir, "key_numbers.csv")))
  expect_true(file.exists(file.path(outdir, "assumptions_used.yaml")))
  expect_true(file.exists(file.path(outdir, "presentation_snapshot.md")))
  expect_true(file.exists(file.path(outdir, "co2_per_1000kcal_by_scenario.csv")))
  expect_true(file.exists(file.path(outdir, "co2_per_kg_protein_by_scenario.csv")))
  expect_true(file.exists(file.path(outdir, "delivery_time_min_by_scenario.csv")))
  expect_true(file.exists(file.path(outdir, "trucker_hours_per_1000kcal_by_scenario.csv")))
  expect_true(file.exists(file.path(outdir, "stop_time_breakdown_bev_vs_diesel.csv")))
  expect_true(file.exists(file.path(outdir, "load_diagnostics_scatter.csv")))

  key <- utils::read.csv(file.path(outdir, "key_numbers.csv"), stringsAsFactors = FALSE)
  expect_true("median_truckloads_per_1e6_kcal" %in% names(key))
  expect_true("median_truckloads_per_1000kg_product" %in% names(key))

  gsi <- utils::read.csv(file.path(outdir, "gsi_by_product_powertrain_spatial_retail.csv"), stringsAsFactors = FALSE)
  expect_true("GSI_kgco2" %in% names(gsi))
  expect_true("p_gsi_gt_0" %in% names(gsi))
})
