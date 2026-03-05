source_files_io <- list.files(file.path("..", "..", "R", "io"), pattern = "\\.R$", full.names = TRUE)
source_files_sim <- list.files(file.path("..", "..", "R", "sim"), pattern = "\\.R$", full.names = TRUE)
for (f in c(source_files_io, source_files_sim)) source(f, local = FALSE)

base_cfg <- function() {
  list(
    cargo = list(payload_lb = list(distribution = list(type = "triangular", min = 8000, mode = 22000, max = 42000))),
    trailer = list(tare_weight_lb = list(distribution = list(type = "triangular", min = 13000, mode = 15000, max = 17000))),
    routing = list(weather = list(ambient_temp_f = list(distribution = list(type = "triangular", min = 60, mode = 70, max = 80)))),
    refrigeration_model = list(
      setpoint_f = 37,
      ambient_sensitivity = list(
        duty_slope_per_f = list(distribution = list(type = "triangular", min = 0.01, mode = 0.015, max = 0.02)),
        power_slope_kw_per_f = list(distribution = list(type = "triangular", min = 0.1, mode = 0.2, max = 0.3))
      ),
      stop_events = list(enabled = TRUE, kwh_per_stop_equivalent = list(distribution = list(type = "triangular", min = 0.3, mode = 0.8, max = 1.6)))
    ),
    refrigeration_units = list(
      electric_vector_ecool = list(
        tru_power_kw_base = list(distribution = list(type = "triangular", min = 2.5, mode = 5, max = 9)),
        duty_cycle_base = list(distribution = list(type = "triangular", min = 0.25, mode = 0.45, max = 0.7))
      ),
      diesel_vector_tru = list(
        fuel_gal_per_engine_hr = list(distribution = list(type = "triangular", min = 0.4, mode = 1.01, max = 1.57)),
        duty_cycle_base = list(distribution = list(type = "triangular", min = 0.25, mode = 0.45, max = 0.7))
      )
    ),
    tractors = list(
      bev_ecascadia = list(
        usable_battery_kwh = 438,
        propulsion_energy_kwh_per_mile = list(distribution = list(type = "triangular", min = 1.4, mode = 1.8, max = 2.2)),
        soc_policy = list(soc_min = 0.15, soc_max = 0.50, soc_target_after_charge = 0.80)
      ),
      diesel_cascadia = list(mpg = list(distribution = list(type = "triangular", min = 2.0, mode = 2.0, max = 2.0)))
    ),
    charging = list(
      connector_required = "CCS",
      min_station_power_kw = 50,
      max_detour_miles = 10,
      selection_policy = "min_total_time",
      queue_delay_minutes_by_hour = list(
        default = list(distribution = list(type = "triangular", min = 0, mode = 0, max = 0)),
        peak = list(distribution = list(type = "triangular", min = 0, mode = 0, max = 0))
      ),
      charge_curve = list(
        stage1_to_soc = 0.80,
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
      peak_hours = list(morning = c(7, 8, 9), evening = c(16, 17, 18)),
      peak_multiplier = list(distribution = list(type = "triangular", min = 1, mode = 1, max = 1)),
      incident_delay = list(enabled = FALSE)
    ),
    stops = list(
      pickup_dwell_minutes = list(distribution = list(type = "triangular", min = 0, mode = 0, max = 0)),
      delivery_dwell_minutes = list(distribution = list(type = "triangular", min = 0, mode = 0, max = 0))
    ),
    diesel_refuel = list(
      tank_capacity_gal = 200,
      start_fuel_fraction = 0.20,
      reserve_fuel_fraction = 0.15,
      refuel_target_fraction = 0.90,
      fixed_stop_minutes = list(distribution = list(type = "triangular", min = 10, mode = 10, max = 10)),
      gallons_per_minute = list(distribution = list(type = "triangular", min = 10, mode = 10, max = 10))
    ),
    diesel_fuel_types = list(
      outbound = list(name = "ULSD_B20", co2_kg_per_gallon = list(distribution = list(type = "triangular", min = 9.2, mode = 9.2, max = 9.2))),
      return = list(name = "ULSD", co2_kg_per_gallon = list(distribution = list(type = "triangular", min = 10.19, mode = 10.19, max = 10.19)))
    ),
    time_sim = list(start_datetime_local = "2026-03-04T00:00:00", duration_hours = 24)
  )
}

mock_segments <- function(n = 30, seg_miles = 12) {
  data.frame(
    route_id = "r1",
    seg_id = seq_len(n),
    lat = seq(38.5, 38.5 + 0.01 * n, length.out = n),
    lng = seq(-121.8, -121.6, length.out = n),
    seg_miles = rep(seg_miles, n),
    grade = rep(0, n),
    elev_m = NA_real_,
    speed_limit_mph = NA_real_,
    bearing = NA_real_,
    admin_region = NA_character_,
    distance_miles_cum = cumsum(rep(seg_miles, n)),
    stringsAsFactors = FALSE
  )
}

test_that("read_ev_stations supports lon->lng normalization and validates schema", {
  ok <- data.frame(
    station_id = c("s1", "s2"),
    lat = c(38.6, 38.7),
    lon = c(-121.7, -121.6),
    power_kw = c(150, 120),
    max_charge_rate_kw = c(150, 120),
    connector_types = c("EV_CONNECTOR_TYPE_CCS_COMBO_1", "EV_CONNECTOR_TYPE_CCS_COMBO_1|EV_CONNECTOR_TYPE_J1772"),
    reliability = c(0.9, 0.95),
    access = c("public", "public"),
    stringsAsFactors = FALSE
  )
  tf <- tempfile(fileext = ".csv")
  utils::write.csv(ok, tf, row.names = FALSE)
  d <- read_ev_stations(tf)
  expect_true("lng" %in% names(d))
  expect_error(read_ev_stations(tempfile(fileext = ".missing")))
})

test_that("read_bev_route_plans parses waypoint ids and expand_route_plan_stops joins stations", {
  plans <- data.frame(
    route_plan_id = "p1",
    route_id = "r1",
    facility_id = "f1",
    retail_id = "x1",
    waypoint_station_ids = "s1|s2;s3",
    stringsAsFactors = FALSE
  )
  pf <- tempfile(fileext = ".csv")
  utils::write.csv(plans, pf, row.names = FALSE)
  p <- read_bev_route_plans(pf)
  expect_equal(p$waypoint_station_ids_vec[[1]], c("s1", "s2", "s3"))

  st <- data.frame(
    station_id = c("s1", "s2", "s3"),
    lat = c(1, 2, 3), lng = c(4, 5, 6),
    max_charge_rate_kw = c(150, 150, 150),
    connector_types = c("CCS", "CCS", "CCS"),
    stringsAsFactors = FALSE
  )
  ex <- expand_route_plan_stops(p, st)
  expect_equal(nrow(ex), 3)
})

test_that("read_route_geometries picks one row per route_id by rank", {
  d <- data.frame(
    route_id = c("r1", "r1", "r2"),
    facility_id = c("f", "f", "f"),
    retail_id = c("x", "x", "x"),
    route_rank = c(2, 1, 1),
    distance_m = c(10, 10, 20),
    duration_s = c(20, 20, 30),
    encoded_polyline = c("abc", "def", "ghi"),
    stringsAsFactors = FALSE
  )
  f <- tempfile(fileext = ".csv")
  utils::write.csv(d, f, row.names = FALSE)
  out <- read_route_geometries(f)
  expect_equal(sum(out$route_id == "r1"), 1)
  expect_equal(out$encoded_polyline[out$route_id == "r1"], "def")
})

test_that("BEV simulation follows planned stops and inserts charge events", {
  cfg <- base_cfg()
  cfg$tractors$bev_ecascadia$soc_policy$soc_max <- 0.85
  seg <- mock_segments(n = 40, seg_miles = 5)
  planned_stops <- data.frame(
    stop_idx = c(1, 2),
    station_id = c("s1", "s2"),
    lat = c(seg$lat[8], seg$lat[16]),
    lng = c(seg$lng[8], seg$lng[16]),
    max_charge_rate_kw = c(180, 180),
    stop_cum_miles = c(seg$distance_miles_cum[8], seg$distance_miles_cum[16]),
    stringsAsFactors = FALSE
  )
  sim <- simulate_route_day(seg, cfg, powertrain = "bev", seed = 123, planned_stops = planned_stops)
  expect_true(any(sim$event_log$event_type == "CHARGE_START"))
})

test_that("BEV simulation emits PLAN_SOC_VIOLATION on infeasible plan", {
  cfg <- base_cfg()
  seg <- mock_segments(n = 100, seg_miles = 15)
  planned_stops <- data.frame(
    stop_idx = 1,
    station_id = "s1",
    lat = seg$lat[80],
    lng = seg$lng[80],
    max_charge_rate_kw = 180,
    stop_cum_miles = seg$distance_miles_cum[80],
    stringsAsFactors = FALSE
  )
  sim <- simulate_route_day(seg, cfg, powertrain = "bev", seed = 123, planned_stops = planned_stops)
  expect_true(any(sim$event_log$event_type == "PLAN_SOC_VIOLATION"))
})

test_that("Diesel simulation inserts refuel events and uses directional fuel type", {
  cfg <- base_cfg()
  seg <- mock_segments(n = 80, seg_miles = 10)
  sim <- simulate_route_day(seg, cfg, powertrain = "diesel", seed = 123, trip_leg = "outbound")
  expect_true(any(sim$event_log$event_type == "REFUEL_START"))
  idx <- which(sim$sim_state$fuel_type_label != "")
  expect_true(length(idx) >= 1)
})

test_that("Simulation counters are monotonic and bounded to 24h", {
  cfg <- base_cfg()
  cfg$time_sim$duration_hours <- 1
  seg <- mock_segments(n = 300, seg_miles = 2)
  planned_stops <- data.frame(
    stop_idx = 1, station_id = "s1", lat = seg$lat[30], lng = seg$lng[30],
    max_charge_rate_kw = 180, stop_cum_miles = seg$distance_miles_cum[30],
    stringsAsFactors = FALSE
  )
  sim <- simulate_route_day(seg, cfg, powertrain = "bev", seed = 111, planned_stops = planned_stops)
  s <- sim$sim_state
  expect_true(all(diff(s$co2_kg_cum) >= -1e-9))
  expect_true(all(diff(s$distance_miles_cum) >= -1e-9))
  t0 <- as.POSIXct(cfg$time_sim$start_datetime_local, tz = "UTC")
  tmax <- max(as.POSIXct(s$t, tz = "UTC"))
  expect_true(as.numeric(difftime(tmax, t0, units = "hours")) <= 1.05)
})

test_that("OD cache hit increments od_cache_hit_count and detour_minutes_cum", {
  cfg <- base_cfg()
  cfg$stops$pickup_dwell_minutes <- list(distribution = list(type = "triangular", min = 0, mode = 0, max = 0))
  seg <- mock_segments(n = 20, seg_miles = 3)
  planned_stops <- data.frame(
    stop_idx = 1,
    station_id = "s1",
    route_id = "r1",
    route_plan_id = "p1",
    lat = seg$lat[5],
    lng = seg$lng[5],
    max_charge_rate_kw = 180,
    stop_cum_miles = seg$distance_miles_cum[5],
    stringsAsFactors = FALSE
  )
  od <- data.frame(
    origin_id = "s1",
    dest_id = "r1",
    road_distance_miles = 8,
    road_duration_minutes = 12,
    status = "OK",
    stringsAsFactors = FALSE
  )
  sim <- simulate_route_day(seg, cfg, powertrain = "bev", seed = 222, planned_stops = planned_stops, od_cache = od)
  s <- sim$sim_state
  expect_true(any(s$od_cache_hit_count > 0))
  expect_true(any(s$detour_minutes_cum > 0))
})

test_that("No OD cache keeps od_cache_hit_count at zero", {
  cfg <- base_cfg()
  seg <- mock_segments(n = 20, seg_miles = 3)
  planned_stops <- data.frame(
    stop_idx = 1,
    station_id = "s1",
    route_id = "r1",
    route_plan_id = "p1",
    lat = seg$lat[5],
    lng = seg$lng[5],
    max_charge_rate_kw = 180,
    stop_cum_miles = seg$distance_miles_cum[5],
    detour_miles = 0,
    stringsAsFactors = FALSE
  )
  sim <- simulate_route_day(seg, cfg, powertrain = "bev", seed = 333, planned_stops = planned_stops, od_cache = data.frame())
  s <- sim$sim_state
  expect_true(all(s$od_cache_hit_count == 0))
})

test_that("sample_exogenous_draws is deterministic by seed", {
  cfg <- base_cfg()
  d1 <- sample_exogenous_draws(cfg, seed = 4242)
  d2 <- sample_exogenous_draws(cfg, seed = 4242)
  expect_identical(d1, d2)
})

test_that("simulate_route_day reuses provided exogenous draws across runs", {
  cfg <- base_cfg()
  seg <- mock_segments(n = 20, seg_miles = 4)
  exo <- sample_exogenous_draws(cfg, seed = 9090)
  sim_a <- simulate_route_day(seg, cfg, powertrain = "bev", seed = 1, exogenous_draws = exo)
  sim_b <- simulate_route_day(seg, cfg, powertrain = "bev", seed = 2, exogenous_draws = exo)

  expect_equal(unique(sim_a$sim_state$payload_lb), unique(sim_b$sim_state$payload_lb))
  expect_equal(sim_a$metadata$exogenous_draws$ambient_f, sim_b$metadata$exogenous_draws$ambient_f)
  expect_equal(sim_a$metadata$exogenous_draws$traffic_multiplier, sim_b$metadata$exogenous_draws$traffic_multiplier)
  expect_equal(sim_a$metadata$exogenous_draws$queue_delay_minutes, sim_b$metadata$exogenous_draws$queue_delay_minutes)
  expect_equal(sim_a$metadata$exogenous_draws$grid_kg_per_kwh, sim_b$metadata$exogenous_draws$grid_kg_per_kwh)
})
