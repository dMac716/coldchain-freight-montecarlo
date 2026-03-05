source(file.path("..", "..", "R", "sim", "01_build_route_segments.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "02_traffic_model.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "03_tru_load_model_37F.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "04_powertrain_energy.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "06_refuel_planner.R"), local = FALSE)
source(file.path("..", "..", "R", "sim", "07_event_simulator.R"), local = FALSE)
source(file.path("..", "..", "R", "08_driver_duty_cycle.R"), local = FALSE)
source(file.path("..", "..", "R", "08_load_model.R"), local = FALSE)

test_cfg_hos <- function() {
  list(
    cargo = list(payload_lb = list(distribution = list(type = "triangular", min = 22000, mode = 22000, max = 22000))),
    trailer = list(tare_weight_lb = list(distribution = list(type = "triangular", min = 15000, mode = 15000, max = 15000))),
    routing = list(weather = list(ambient_temp_f = list(distribution = list(type = "triangular", min = 70, mode = 70, max = 70)))),
    tractors = list(
      bev_ecascadia = list(
        usable_battery_kwh = 438,
        propulsion_energy_kwh_per_mile = list(distribution = list(type = "triangular", min = 1.8, mode = 1.8, max = 1.8)),
        soc_policy = list(soc_min = 0.15, soc_max = 0.85, soc_target_after_charge = 0.8)
      ),
      diesel_cascadia = list(mpg = list(distribution = list(type = "triangular", min = 7, mode = 7, max = 7)))
    ),
    refrigeration_model = list(
      setpoint_f = 37,
      ambient_sensitivity = list(
        duty_slope_per_f = list(distribution = list(type = "triangular", min = 0.01, mode = 0.01, max = 0.01)),
        power_slope_kw_per_f = list(distribution = list(type = "triangular", min = 0.2, mode = 0.2, max = 0.2))
      ),
      stop_events = list(enabled = FALSE, kwh_per_stop_equivalent = list(distribution = list(type = "triangular", min = 0, mode = 0, max = 0)))
    ),
    refrigeration_units = list(
      diesel_vector_tru = list(
        fuel_gal_per_engine_hr = list(distribution = list(type = "triangular", min = 0.5, mode = 0.5, max = 0.5)),
        duty_cycle_base = list(distribution = list(type = "triangular", min = 0.3, mode = 0.3, max = 0.3))
      ),
      electric_vector_ecool = list(
        tru_power_kw_base = list(distribution = list(type = "triangular", min = 4, mode = 4, max = 4)),
        duty_cycle_base = list(distribution = list(type = "triangular", min = 0.3, mode = 0.3, max = 0.3))
      )
    ),
    charging = list(
      queue_delay_minutes_by_hour = list(default = list(distribution = list(type = "triangular", min = 0, mode = 0, max = 0))),
      charge_curve = list(
        stage1_to_soc = 0.8,
        stage1_power_fraction_of_max = list(distribution = list(type = "triangular", min = 0.8, mode = 0.8, max = 0.8)),
        stage2_power_fraction_of_max = list(distribution = list(type = "triangular", min = 0.35, mode = 0.35, max = 0.35))
      )
    ),
    emissions = list(
      grid_intensity_gco2_per_kwh = list(distribution = list(type = "triangular", min = 400, mode = 400, max = 400)),
      diesel_co2_kg_per_gallon = list(baseline = 10.19)
    ),
    traffic = list(
      enabled = TRUE,
      hourly_speed_multiplier = list(default = list(distribution = list(type = "triangular", min = 1, mode = 1, max = 1))),
      peak_multiplier = list(distribution = list(type = "triangular", min = 1, mode = 1, max = 1)),
      peak_hours = list(morning = c(7, 8, 9), evening = c(16, 17, 18)),
      incident_delay = list(enabled = FALSE)
    ),
    diesel_refuel = list(
      tank_capacity_gal = 200,
      start_fuel_fraction = 0.9,
      reserve_fuel_fraction = 0.15,
      refuel_target_fraction = 0.9,
      fixed_stop_minutes = list(distribution = list(type = "triangular", min = 15, mode = 15, max = 15)),
      gallons_per_minute = list(distribution = list(type = "triangular", min = 10, mode = 10, max = 10))
    ),
    diesel_fuel_types = list(outbound = list(name = "ULSD", co2_kg_per_gallon = list(baseline = 10.19))),
    time_sim = list(start_datetime_local = "2026-03-04T00:00:00", duration_hours = 72),
    driver_time = list(
      pretrip_inspection_min = 15,
      posttrip_min = 10,
      load_unload_min = list(distribution = list(type = "triangular", min = 45, mode = 45, max = 45)),
      refuel_stop_min = list(distribution = list(type = "triangular", min = 15, mode = 15, max = 15)),
      charge_connector_overhead_min = list(distribution = list(type = "triangular", min = 8, mode = 8, max = 8))
    ),
    hos = list(
      enabled = TRUE,
      max_driving_hours = 11,
      max_on_duty_window_hours = 14,
      break_required_after_driving_hours = 8,
      break_duration_min = 30,
      rest_reset_hours = 10
    ),
    load_model = list(
      trailer = list(pallets_max = 26, payload_max_lb = list(distribution = list(type = "triangular", min = 43000, mode = 43000, max = 43000))),
      products = list(
        dry = list(unit_weight_lb = 30, bags_per_pallet = list(distribution = list(type = "triangular", min = 50, mode = 50, max = 50))),
        refrigerated = list(unit_weight_lb = 4.5, packs_per_case = 6, cases_per_pallet = list(distribution = list(type = "triangular", min = 75, mode = 75, max = 75)))
      )
    )
  )
}

test_that("schedule inserts break and rest when route exceeds HOS limits", {
  cfg <- test_cfg_hos()
  seg <- data.frame(
    route_id = "r_hos",
    seg_id = 1:14,
    lat = rep(38.5, 14),
    lng = rep(-121.7, 14),
    seg_miles = rep(50, 14),
    grade = rep(0, 14),
    elev_m = NA_real_,
    speed_limit_mph = NA_real_,
    bearing = NA_real_,
    admin_region = NA_character_,
    distance_miles_cum = cumsum(rep(50, 14)),
    stringsAsFactors = FALSE
  )
  sim <- simulate_route_day(seg, cfg, powertrain = "diesel", seed = 42, product_type = "refrigerated")
  expect_true(any(sim$event_log$event_type == "REST_BREAK"))
  expect_true(any(sim$event_log$event_type == "REST_RESET"))
  expect_equal(as.integer(sim$metadata$schedule$hos_violation_flag), 0L)
  expect_gt(as.numeric(sim$metadata$schedule$delivery_time_min), as.numeric(sim$metadata$schedule$driver_driving_min))
})

