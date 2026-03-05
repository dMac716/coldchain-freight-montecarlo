source(file.path("..", "..", "R", "02_units.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "10_run_bundle.R"), local = FALSE)

test_that("write_run_bundle emits required files and hashes", {
  td <- tempfile("bundle_")
  dir.create(td, recursive = TRUE)

  # fake simulation payload
  sim <- list(
    sim_state = data.frame(
      t = c("2026-03-05 00:00:00 UTC", "2026-03-05 01:00:00 UTC"),
      distance_miles_cum = c(0, 120),
      co2_kg_cum = c(0, 250),
      propulsion_kwh_cum = c(0, 180),
      tru_kwh_cum = c(0, 20),
      diesel_gal_cum = c(0, 0),
      tru_gal_cum = c(0, 0),
      delay_minutes_cum = c(0, 10),
      charge_count = c(0, 1),
      refuel_count = c(0, 0),
      fuel_type_label = c("", ""),
      stringsAsFactors = FALSE
    ),
    event_log = data.frame(
      t_start = "2026-03-05 00:00:00 UTC",
      t_end = "2026-03-05 00:10:00 UTC",
      event_type = "ROUTE_COMPLETE",
      lat = 38.5,
      lng = -121.7,
      energy_delta_kwh = 0,
      fuel_delta_gal = 0,
      co2_delta_kg = 0,
      reason = "done",
      stringsAsFactors = FALSE
    ),
    metadata = list(plan_soc_violation = FALSE)
  )

  # fake artifact inputs
  a1 <- file.path(td, "routes.csv")
  a2 <- file.path(td, "plans.csv")
  a3 <- file.path(td, "stations.csv")
  a4 <- file.path(td, "od.csv")
  utils::write.csv(data.frame(x = 1), a1, row.names = FALSE)
  utils::write.csv(data.frame(x = 2), a2, row.names = FALSE)
  utils::write.csv(data.frame(x = 3), a3, row.names = FALSE)
  utils::write.csv(data.frame(x = 4), a4, row.names = FALSE)

  track <- file.path(td, "track.csv")
  utils::write.csv(sim$sim_state, track, row.names = FALSE)

  out <- write_run_bundle(
    sim = sim,
    context = list(run_id = "test_run_1", scenario = "s1", route_id = "r1", powertrain = "bev", trip_leg = "outbound", seed = 123, mc_draws = 1),
    cfg_resolved = list(test = TRUE),
    artifact_paths = c(routes_geometry = a1, bev_route_plans = a2, ev_stations = a3, od_cache = a4),
    tracks_path = track,
    bundle_root = file.path(td, "bundles")
  )

  expect_true(file.exists(out$runs_path))
  expect_true(file.exists(out$summaries_path))
  expect_true(file.exists(out$events_path))
  expect_true(file.exists(out$params_path))
  expect_true(file.exists(out$artifacts_path))
  expect_true(file.exists(out$tracks_gz_path))

  runs <- jsonlite::fromJSON(out$runs_path)
  expect_equal(runs$run_id, "test_run_1")
  expect_true(nzchar(runs$inputs_hash))
})
