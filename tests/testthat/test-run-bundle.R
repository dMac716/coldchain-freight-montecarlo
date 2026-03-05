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
      payload_lb = c(20000, 20000),
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
    context = list(
      run_id = "test_run_1",
      scenario = "s1",
      route_id = "r1",
      product_type = "dry",
      origin_network = "dry_factory_set",
      powertrain = "bev",
      trip_leg = "outbound",
      seed = 123,
      mc_draws = 1
    ),
    cfg_resolved = list(
      nutrition = list(
        dry = list(
          kcal_per_kg = list(distribution = list(type = "triangular", min = 3500, mode = 3500, max = 3500)),
          protein_g_per_kg = list(distribution = list(type = "triangular", min = 260, mode = 260, max = 260))
        )
      ),
      costs = list(
        diesel_price_per_gal = 4.0,
        electricity_price_per_kwh = 0.18,
        driver_cost_per_hour = 35.0,
        base_price_per_kcal = list(dry = 0.0022, refrigerated = 0.0083)
      )
    ),
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
  sm <- utils::read.csv(out$summaries_path, stringsAsFactors = FALSE)
  expect_equal(runs$run_id, "test_run_1")
  expect_true(nzchar(runs$inputs_hash))
  expect_equal(runs$product_type, "dry")
  expect_true(is.finite(sm$co2_per_1000kcal[[1]]))
  expect_true(is.finite(sm$co2_per_kg_protein[[1]]))
  expect_true("traffic_mode" %in% names(sm))
  expect_true("pair_id" %in% names(sm))
  expect_true(is.finite(sm$transport_cost_per_1000kcal[[1]]))
  expect_true(is.finite(sm$delivered_price_per_kcal[[1]]))
  expect_true(is.finite(sm$price_index[[1]]))
  expect_true(is.finite(sm$protein_per_1000kcal[[1]]))
  expect_true("co2_kg_upstream" %in% names(sm))
  expect_true("co2_kg_full" %in% names(sm))
  expect_true("co2_full_per_1000kcal" %in% names(sm))
  expect_true("co2_full_per_kg_protein" %in% names(sm))
  expect_true(is.na(sm$co2_kg_upstream[[1]]))
  expect_true(is.na(sm$co2_kg_full[[1]]))
  # Unit-chain consistency checks.
  expect_equal(sm$co2_per_1000kcal[[1]], sm$co2_kg_total[[1]] / (sm$kcal_delivered[[1]] / 1000), tolerance = 1e-10)
  expect_equal(sm$co2_per_kg_protein[[1]], sm$co2_kg_total[[1]] / sm$protein_kg_delivered[[1]], tolerance = 1e-10)
  expect_equal(sm$protein_per_1000kcal[[1]], (sm$protein_kg_delivered[[1]] * 1000) / sm$kcal_delivered[[1]], tolerance = 1e-10)
})
