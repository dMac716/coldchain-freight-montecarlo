source(file.path("..", "..", "R", "sim", "01_build_route_segments.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "02_traffic_model.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "07_event_simulator.R"), local = FALSE)
source(file.path("..", "..", "R", "08_load_model.R"), local = FALSE)

paired_cfg <- function() {
  list(
    cargo = list(payload_lb = list(distribution = list(type = "triangular", min = 20000, mode = 20000, max = 20000))),
    trailer = list(tare_weight_lb = list(distribution = list(type = "triangular", min = 15000, mode = 15000, max = 15000))),
    routing = list(weather = list(ambient_temp_f = list(distribution = list(type = "triangular", min = 70, mode = 70, max = 70)))),
    traffic = list(
      enabled = TRUE,
      hourly_speed_multiplier = list(default = list(distribution = list(type = "triangular", min = 1, mode = 1, max = 1))),
      peak_multiplier = list(distribution = list(type = "triangular", min = 1, mode = 1, max = 1)),
      peak_hours = list(morning = c(7, 8, 9), evening = c(16, 17, 18)),
      incident_delay = list(enabled = FALSE)
    ),
    charging = list(queue_delay_minutes_by_hour = list(default = list(distribution = list(type = "triangular", min = 0, mode = 0, max = 0)))),
    emissions = list(grid_intensity_gco2_per_kwh = list(distribution = list(type = "triangular", min = 400, mode = 400, max = 400))),
    tractors = list(diesel_cascadia = list(mpg = list(distribution = list(type = "triangular", min = 7, mode = 7, max = 7)))),
    driver_time = list(
      load_unload_min = list(distribution = list(type = "triangular", min = 45, mode = 45, max = 45)),
      refuel_stop_min = list(distribution = list(type = "triangular", min = 15, mode = 15, max = 15)),
      charge_connector_overhead_min = list(distribution = list(type = "triangular", min = 8, mode = 8, max = 8))
    ),
    load_model = list(
      trailer = list(pallets_max = 26, payload_max_lb = list(distribution = list(type = "triangular", min = 38000, mode = 43000, max = 45000))),
      products = list(
        dry = list(unit_weight_lb = 30, bags_per_pallet = list(distribution = list(type = "triangular", min = 40, mode = 50, max = 65))),
        refrigerated = list(unit_weight_lb = 4.5, packs_per_case = 6, cases_per_pallet = list(distribution = list(type = "triangular", min = 60, mode = 75, max = 90))
        )
      )
    )
  )
}

test_that("paired seed reuses load and driver-time draws across origin network comparisons", {
  cfg <- paired_cfg()
  exo <- sample_exogenous_draws(cfg, seed = 1001)

  expect_equal(exo$payload_max_lb_draw, sample_exogenous_draws(cfg, seed = 1001)$payload_max_lb_draw)
  expect_equal(exo$load_unload_min, sample_exogenous_draws(cfg, seed = 1001)$load_unload_min)
  expect_equal(exo$refuel_stop_min, sample_exogenous_draws(cfg, seed = 1001)$refuel_stop_min)
  expect_equal(exo$connector_overhead_min, sample_exogenous_draws(cfg, seed = 1001)$connector_overhead_min)

  ld_dry <- resolve_load_draw(seed = 1001, cfg = cfg, product_type = "dry", exogenous_draws = exo)
  ld_ref <- resolve_load_draw(seed = 1001, cfg = cfg, product_type = "refrigerated", exogenous_draws = exo)
  expect_equal(ld_dry$payload_max_lb_draw, ld_ref$payload_max_lb_draw)
})

