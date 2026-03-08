test_that("summarize_route_sim_outputs writes paired TEP and GSI summaries", {
  td <- tempfile("route_summary_")
  dir.create(td, recursive = TRUE)
  tracks_dir <- file.path(td, "tracks")
  events_dir <- file.path(td, "events")
  bundle_dir <- file.path(td, "bundle")
  outdir <- file.path(td, "analysis")
  dir.create(tracks_dir, recursive = TRUE)
  dir.create(events_dir, recursive = TRUE)
  dir.create(bundle_dir, recursive = TRUE)
  dir.create(outdir, recursive = TRUE)

  make_run <- function(run_id, pair_id, traffic_mode, origin_network, co2_total, co2_per_kg_protein) {
    tr <- data.frame(
      t = c("2026-03-05 00:00:00 UTC", "2026-03-05 01:00:00 UTC"),
      scenario = c("s1", "s1"),
      route_id = c("r1", "r1"),
      lat = c(38.5, 38.6),
      lng = c(-121.8, -121.7),
      distance_miles_cum = c(0, 100),
      co2_kg_cum = c(0, co2_total),
      propulsion_kwh_cum = c(0, 10),
      tru_kwh_cum = c(0, 2),
      diesel_gal_cum = c(0, 0),
      tru_gal_cum = c(0, 0),
      delay_minutes_cum = c(0, 5),
      stop_count = c(0, 1),
      charge_count = c(0, 0),
      refuel_count = c(0, 0),
      soc = c(0.8, 0.7),
      stringsAsFactors = FALSE
    )
    utils::write.csv(tr, file.path(tracks_dir, paste0(run_id, ".csv")), row.names = FALSE)

    ev <- data.frame(
      t_start = "2026-03-05 00:59:00 UTC",
      t_end = "2026-03-05 01:00:00 UTC",
      event_type = "ROUTE_COMPLETE",
      lat = 38.6,
      lng = -121.7,
      energy_delta_kwh = 0,
      fuel_delta_gal = 0,
      co2_delta_kg = 0,
      reason = "done",
      stringsAsFactors = FALSE
    )
    utils::write.csv(ev, file.path(events_dir, paste0(run_id, ".csv")), row.names = FALSE)

    bdir <- file.path(bundle_dir, run_id)
    dir.create(bdir, recursive = TRUE)
    bsum <- data.frame(
      run_id = run_id,
      pair_id = pair_id,
      scenario = "s1",
      traffic_mode = traffic_mode,
      product_type = "refrigerated",
      origin_network = origin_network,
      route_id = "r1",
      co2_per_kg_protein = co2_per_kg_protein,
      co2_per_1000kcal = 10,
      co2_kg_upstream = 1,
      co2_kg_full = 11,
      co2_full_per_1000kcal = 11,
      co2_full_per_kg_protein = 2,
      co2_full_g_per_g_protein = 2,
      transport_cost_total = 1,
      transport_cost_usd = 1,
      transport_cost_per_1000kcal = 0.1,
      transport_cost_per_kcal = 0.001,
      transport_cost_per_kg_protein = 0.3,
      delivered_price_per_kcal = 0.003,
      price_index = 1.2,
      protein_per_1000kcal = 0.1,
      kcal_delivered = 1000,
      mass_required_for_fu_kg = 0.5,
      protein_kg_delivered = 50,
      driving_time_h = 1,
      traffic_delay_time_h = 0.1,
      charging_or_refueling_time_h = 0,
      rest_time_h = 0,
      trip_duration_total_h = 1.1,
      truckloads_per_1e6_kcal = 2.0,
      truckloads_per_1000kg_product = 1.5,
      stringsAsFactors = FALSE
    )
    utils::write.csv(bsum, file.path(bdir, "summaries.csv"), row.names = FALSE)
  }

  make_run("r1", "p1", "stochastic", "dry_factory_set", 100, 1.0)
  make_run("r2", "p1", "stochastic", "refrigerated_factory_set", 120, 1.4)
  make_run("r3", "p1", "freeflow", "dry_factory_set", 90, 0.9)
  make_run("r4", "p1", "freeflow", "refrigerated_factory_set", 110, 1.3)

  cmd <- c(
    file.path("..", "..", "tools", "summarize_route_sim_outputs.R"),
    "--tracks_dir", tracks_dir,
    "--events_dir", events_dir,
    "--bundle_dir", bundle_dir,
    "--outdir", outdir
  )
  status <- system2("Rscript", cmd, stdout = TRUE, stderr = TRUE)
  expect_true(is.null(attr(status, "status")) || identical(attr(status, "status"), 0L))

  tep_sum <- file.path(outdir, "route_sim_traffic_penalty_summary.csv")
  gsi_sum <- file.path(outdir, "route_sim_geo_sensitivity_protein_summary.csv")
  expect_true(file.exists(tep_sum))
  expect_true(file.exists(gsi_sum))

  tep <- utils::read.csv(tep_sum, stringsAsFactors = FALSE)
  gsi <- utils::read.csv(gsi_sum, stringsAsFactors = FALSE)
  expect_true("p_traffic_emissions_penalty_gt_0" %in% names(tep))
  expect_true("p_gsi_gt_0" %in% names(gsi))

  summary_path <- file.path(outdir, "route_sim_summary_stats.csv")
  summary_df <- utils::read.csv(summary_path, stringsAsFactors = FALSE)
  expect_true("p05_truckloads_per_1e6_kcal" %in% names(summary_df))
  expect_true("p50_truckloads_per_1e6_kcal" %in% names(summary_df))
  expect_true("p95_truckloads_per_1000kg_product" %in% names(summary_df))
})
