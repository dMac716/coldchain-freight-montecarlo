# Event-driven 24h route simulation.

new_rng <- function(seed) {
  if (exists("new_local_rng", mode = "function")) {
    return(new_local_rng(seed))
  }
  env <- new.env(parent = emptyenv())
  set.seed(as.integer(seed))
  env$runif <- function(...) stats::runif(...)
  env$rnorm <- function(...) stats::rnorm(...)
  env
}

new_row_buffer <- function(initial_capacity = 64L, grow_by = NULL) {
  capacity <- max(1L, as.integer(initial_capacity %||% 64L))
  grow_step <- max(16L, as.integer(grow_by %||% max(16L, ceiling(capacity / 2))))
  store <- vector("list", capacity)
  n <- 0L

  list(
    add = function(row) {
      if (n >= length(store)) {
        length(store) <<- length(store) + grow_step
      }
      n <<- n + 1L
      store[[n]] <<- row
      invisible(NULL)
    },
    collect = function() {
      if (n == 0L) return(data.frame())
      rows <- store[seq_len(n)]
      if (requireNamespace("data.table", quietly = TRUE)) {
        return(as.data.frame(data.table::rbindlist(rows, fill = TRUE, use.names = TRUE)))
      }
      do.call(rbind, rows)
    },
    count = function() n
  )
}

new_name_set <- function() {
  env <- new.env(parent = emptyenv())
  env$add <- function(values) {
    vals <- as.character(values %||% character())
    vals <- vals[nzchar(vals) & !is.na(vals)]
    if (length(vals) == 0L) return(invisible(NULL))
    for (val in vals) {
      env[[val]] <- TRUE
    }
    invisible(NULL)
  }
  env$values <- function() {
    out <- ls(env, all.names = TRUE)
    out[!out %in% c("add", "values")]
  }
  env
}

sample_exogenous_draws <- function(cfg, seed = 123) {
  rng <- new_rng(seed)
  trailer <- sample_trailer_capacity(seed = seed + 100L, test_kit = cfg)
  dry_pack <- sample_product_packaging(seed = seed + 101L, product_type = "dry", test_kit = cfg)
  ref_pack <- sample_product_packaging(seed = seed + 102L, product_type = "refrigerated", test_kit = cfg)
  ship <- cfg$load_model$shipment_assignment %||% list()
  list(
    payload_lb = sim_pick_distribution(cfg$cargo$payload_lb, rng = rng),
    trailer_tare_lb = sim_pick_distribution(cfg$trailer$tare_weight_lb, rng = rng),
    ambient_f = sim_pick_distribution(cfg$routing$weather$ambient_temp_f, rng = rng),
    traffic_multiplier = sample_traffic_multiplier(as.POSIXct("2026-01-01 12:00:00", tz = "UTC"), cfg$traffic, rng = rng),
    queue_delay_minutes = sample_queue_delay_minutes(as.POSIXct("2026-01-01 12:00:00", tz = "UTC"), cfg$charging, cfg$traffic, rng = rng),
    grid_kg_per_kwh = sim_pick_distribution(cfg$emissions$grid_intensity_gco2_per_kwh, rng = rng) / 1000,
    mpg = sim_pick_distribution(cfg$tractors$diesel_cascadia$mpg, rng = rng),
    payload_max_lb_draw = as.numeric(trailer$payload_max_lb),
    pallets_max = as.integer(trailer$pallets_max),
    unit_weight_lb_dry = as.numeric(dry_pack$unit_weight_lb),
    unit_weight_lb_refrigerated = as.numeric(ref_pack$unit_weight_lb),
    units_per_case_draw_dry = as.numeric(dry_pack$units_per_case_draw),
    units_per_case_draw_refrigerated = as.numeric(ref_pack$units_per_case_draw),
    cases_per_pallet_draw_dry = as.numeric(dry_pack$cases_per_pallet_draw),
    cases_per_pallet_draw_refrigerated = as.numeric(ref_pack$cases_per_pallet_draw),
    cases_per_layer_dry = as.numeric(dry_pack$cases_per_layer),
    cases_per_layer_refrigerated = as.numeric(ref_pack$cases_per_layer),
    layers_dry = as.numeric(dry_pack$layers),
    layers_refrigerated = as.numeric(ref_pack$layers),
    packing_efficiency_draw_dry = as.numeric(dry_pack$packing_efficiency_draw),
    packing_efficiency_draw_refrigerated = as.numeric(ref_pack$packing_efficiency_draw),
    pallet_tare_lb_draw = as.numeric(dry_pack$pallet_tare_lb_draw),
    case_tare_lb_draw_dry = as.numeric(dry_pack$case_tare_lb_draw),
    case_tare_lb_draw_refrigerated = as.numeric(ref_pack$case_tare_lb_draw),
    chosen_pack_pattern_refrigerated = as.character(ref_pack$chosen_pack_pattern %||% NA_character_),
    pack_pattern_index_refrigerated = as.integer(ref_pack$pack_pattern_index %||% NA_integer_),
    derived_case_L_in_dry = as.numeric(dry_pack$derived_case_L_in),
    derived_case_W_in_dry = as.numeric(dry_pack$derived_case_W_in),
    derived_case_H_in_dry = as.numeric(dry_pack$derived_case_H_in),
    derived_case_L_in_refrigerated = as.numeric(ref_pack$derived_case_L_in),
    derived_case_W_in_refrigerated = as.numeric(ref_pack$derived_case_W_in),
    derived_case_H_in_refrigerated = as.numeric(ref_pack$derived_case_H_in),
    load_unload_min = as.numeric(sim_pick_distribution(cfg$driver_time$load_unload_min, rng = rng)),
    refuel_stop_min = as.numeric(sim_pick_distribution(cfg$driver_time$refuel_stop_min, rng = rng)),
    connector_overhead_min = as.numeric(sim_pick_distribution(cfg$driver_time$charge_connector_overhead_min, rng = rng)),
    load_fraction_draw = as.numeric(sim_pick_distribution(ship$partial_load_fraction, rng = rng)),
    assigned_cases_draw = as.numeric(sim_pick_distribution(ship$assigned_cases, rng = rng))
  )
}

simulate_route_day <- function(
    route_segments,
    cfg,
    powertrain = c("bev", "diesel"),
    scenario = "scenario",
    truck_id = "TRUCK_1",
    seed = 123,
    trip_leg = c("outbound", "return"),
    base_speed_mph = 50,
    start_time = NULL,
    duration_hours = NULL,
    planned_stops = NULL,
    charging_candidates = NULL,
    od_cache = NULL,
    exogenous_draws = NULL,
    product_type = "refrigerated",
    cold_chain_required = NULL,
    load_assignment_policy = NULL,
    state_retention = c("full", "first_last"),
    retain_event_log = TRUE,
    retain_charge_details = TRUE,
    enforce_duration_limit = NULL) {
  powertrain <- match.arg(powertrain)
  trip_leg <- match.arg(trip_leg)
  state_retention <- match.arg(state_retention)
  rng <- new_rng(seed)

  start_time <- as.POSIXct(start_time %||% cfg$time_sim$start_datetime_local %||% "2026-03-04T00:00:00", tz = "UTC")
  duration_hours <- as.numeric(duration_hours %||% cfg$time_sim$duration_hours %||% 24)
  enforce_duration_limit <- isTRUE(enforce_duration_limit %||% cfg$time_sim$enforce_duration_limit %||% TRUE)
  end_time <- if (isTRUE(enforce_duration_limit) && is.finite(duration_hours) && duration_hours > 0) {
    start_time + duration_hours * 3600
  } else {
    as.POSIXct("2200-01-01 00:00:00", tz = "UTC")
  }
  product_type <- infer_product_type_from_text(product_type, default = "refrigerated")
  if (is.null(cold_chain_required) || length(cold_chain_required) == 0 || is.na(cold_chain_required[[1]])) {
    cold_chain_required <- isTRUE(cold_chain_required_from_product_type(product_type, default = TRUE))
  } else {
    cold_chain_required <- isTRUE(as.logical(cold_chain_required[[1]]))
  }

  payload_lb <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$payload_lb %||% NA_real_))) {
    as.numeric(exogenous_draws$payload_lb)
  } else sim_pick_distribution(cfg$cargo$payload_lb, rng = rng)
  trailer_tare_lb <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$trailer_tare_lb %||% NA_real_))) {
    as.numeric(exogenous_draws$trailer_tare_lb)
  } else sim_pick_distribution(cfg$trailer$tare_weight_lb, rng = rng)
  ambient_f <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$ambient_f %||% NA_real_))) {
    as.numeric(exogenous_draws$ambient_f)
  } else sim_pick_distribution(cfg$routing$weather$ambient_temp_f, rng = rng)
  if (!is.finite(ambient_f)) ambient_f <- 70

  load_draw <- resolve_load_draw(
    seed = as.integer(seed),
    cfg = cfg,
    product_type = product_type,
    exogenous_draws = exogenous_draws,
    load_assignment_policy = load_assignment_policy
  )
  nutrition <- list(kcal_per_kg_product = NA_real_, protein_g_per_kg_product = NA_real_)
  if (exists("resolve_food_profile", mode = "function")) {
    fi <- if (exists("read_food_inputs", mode = "function")) read_food_inputs("data") else NULL
    nutrition <- resolve_food_profile(product_type, food_inputs = fi, seed = as.integer(seed))
  }
  kcal_per_kg_product <- as.numeric(nutrition$kcal_per_kg_product %||% NA_real_)
  protein_g_per_kg_product <- as.numeric(nutrition$protein_g_per_kg_product %||% NA_real_)
  load_draw$kcal_per_truck <- if (is.finite(load_draw$product_mass_lb_per_truck) && is.finite(kcal_per_kg_product)) {
    kcal_per_kg_product * (load_draw$product_mass_lb_per_truck * 0.45359237)
  } else {
    NA_real_
  }
  load_draw$protein_kg_per_truck <- if (is.finite(load_draw$product_mass_lb_per_truck) && is.finite(protein_g_per_kg_product)) {
    (protein_g_per_kg_product / 1000) * (load_draw$product_mass_lb_per_truck * 0.45359237)
  } else {
    NA_real_
  }

  event_buffer <- if (isTRUE(retain_event_log)) new_row_buffer(initial_capacity = max(32L, nrow(route_segments) * 2L)) else NULL
  state_buffer <- if (identical(state_retention, "full")) new_row_buffer(initial_capacity = max(8L, nrow(route_segments))) else NULL
  charge_detail_buffer <- if (isTRUE(retain_charge_details)) new_row_buffer(initial_capacity = 16L) else NULL
  first_state_row <- NULL
  last_state_row <- NULL
  charge_qa_acc <- list(
    charging_attempts = 0L,
    compatible_chargers_considered = 0L,
    occupied_events = 0L,
    broken_events = 0L,
    total_wait_time_minutes = 0,
    max_wait_time_minutes = 0,
    added_refrigeration_runtime_minutes_waiting = 0,
    added_hos_delay_minutes_waiting = 0,
    failed_attempt_rows = 0L
  )
  usage_station_ids <- new_name_set()
  usage_connector_types <- new_name_set()
  usage_charger_types <- new_name_set()
  usage_charger_levels <- new_name_set()
  max_charge_rate_kw_min <- NA_real_
  max_charge_rate_kw_max <- NA_real_
  soc_min_observed <- NA_real_
  soc_max_observed <- NA_real_

  add_event <- function(t0, t1, type, lat, lng, energy_delta_kwh = 0, fuel_delta_gal = 0, co2_delta_kg = 0, reason = "") {
    if (!isTRUE(retain_event_log)) return(invisible(NULL))
    event_buffer$add(data.frame(
      t_start = as.character(t0),
      t_end = as.character(t1),
      event_type = as.character(type),
      lat = as.numeric(lat),
      lng = as.numeric(lng),
      energy_delta_kwh = as.numeric(energy_delta_kwh),
      fuel_delta_gal = as.numeric(fuel_delta_gal),
      co2_delta_kg = as.numeric(co2_delta_kg),
      reason = as.character(reason),
      stringsAsFactors = FALSE
    ))
    invisible(NULL)
  }

  add_state <- function(t, seg, speed_mph, soc, fuel_gal, prop_kwh, diesel_gal, tru_kwh, tru_gal, co2, delay_min, detour_min, od_hits, counts, driving_h, traffic_delay_h, service_h, rest_h, fuel_type = NA_character_, grid_kg_per_kwh = NA_real_) {
    trip <- compute_trip_time_rollup(driving_h, traffic_delay_h, service_h, rest_h)
    row <- data.frame(
      t = as.character(t),
      route_id = as.character(seg$route_id),
      truck_id = as.character(truck_id),
      scenario = as.character(scenario),
      lat = as.numeric(seg$lat),
      lng = as.numeric(seg$lng),
      distance_miles_cum = as.numeric(seg$distance_miles_cum),
      speed_mph = as.numeric(speed_mph),
      payload_lb = as.numeric(payload_lb),
      soc = as.numeric(soc),
      fuel_gal = as.numeric(fuel_gal),
      propulsion_kwh_cum = as.numeric(prop_kwh),
      diesel_gal_cum = as.numeric(diesel_gal),
      tru_kwh_cum = as.numeric(tru_kwh),
      tru_gal_cum = as.numeric(tru_gal),
      co2_kg_cum = as.numeric(co2),
      delay_minutes_cum = as.numeric(delay_min),
      driving_time_h_cum = as.numeric(driving_h),
      traffic_delay_h_cum = as.numeric(traffic_delay_h),
      service_time_h_cum = as.numeric(service_h),
      rest_time_h_cum = as.numeric(rest_h),
      trip_duration_h_cum = as.numeric(trip$trip_duration_h),
      detour_minutes_cum = as.numeric(detour_min),
      od_cache_hit_count = as.integer(od_hits),
      stop_count = as.integer(counts$stop),
      charge_count = as.integer(counts$charge),
      refuel_count = as.integer(counts$refuel),
      fuel_type_label = as.character(fuel_type),
      grid_kg_per_kwh = as.numeric(grid_kg_per_kwh),
      stringsAsFactors = FALSE
    )
    if (identical(state_retention, "full")) {
      state_buffer$add(row)
    }
    if (is.null(first_state_row)) first_state_row <<- row
    last_state_row <<- row
    soc_val <- suppressWarnings(as.numeric(row$soc[[1]]))
    if (is.finite(soc_val)) {
      soc_min_observed <<- if (is.finite(soc_min_observed)) min(soc_min_observed, soc_val) else soc_val
      soc_max_observed <<- if (is.finite(soc_max_observed)) max(soc_max_observed, soc_val) else soc_val
    }
    invisible(NULL)
  }

  append_charge_attempts <- function(df) {
    if (!is.data.frame(df) || nrow(df) == 0) return(invisible(NULL))
    wait_times <- suppressWarnings(as.numeric(df$wait_time_minutes))
    wait_times[!is.finite(wait_times)] <- 0
    compatible_counts <- suppressWarnings(as.numeric(df$compatible_candidates_considered))
    compatible_counts[!is.finite(compatible_counts)] <- 0
    failed_rows <- suppressWarnings(as.numeric(df$failed_attempt))
    failed_rows[!is.finite(failed_rows)] <- 0
    states <- tolower(as.character(df$state_drawn %||% NA_character_))
    charge_qa_acc$charging_attempts <<- as.integer(charge_qa_acc$charging_attempts) + nrow(df)
    charge_qa_acc$compatible_chargers_considered <<- as.integer(charge_qa_acc$compatible_chargers_considered) + as.integer(max(compatible_counts, na.rm = TRUE))
    charge_qa_acc$occupied_events <<- as.integer(charge_qa_acc$occupied_events) + as.integer(sum(states == "occupied", na.rm = TRUE))
    charge_qa_acc$broken_events <<- as.integer(charge_qa_acc$broken_events) + as.integer(sum(states == "broken", na.rm = TRUE))
    charge_qa_acc$total_wait_time_minutes <<- as.numeric(charge_qa_acc$total_wait_time_minutes) + sum(wait_times, na.rm = TRUE)
    charge_qa_acc$max_wait_time_minutes <<- max(as.numeric(charge_qa_acc$max_wait_time_minutes), max(wait_times, na.rm = TRUE), 0, na.rm = TRUE)
    charge_qa_acc$added_refrigeration_runtime_minutes_waiting <<- as.numeric(charge_qa_acc$added_refrigeration_runtime_minutes_waiting) + sum(wait_times, na.rm = TRUE)
    charge_qa_acc$added_hos_delay_minutes_waiting <<- as.numeric(charge_qa_acc$added_hos_delay_minutes_waiting) + sum(wait_times, na.rm = TRUE)
    charge_qa_acc$failed_attempt_rows <<- as.integer(charge_qa_acc$failed_attempt_rows) + as.integer(sum(failed_rows > 0, na.rm = TRUE))
    if (isTRUE(retain_charge_details)) {
      for (ii in seq_len(nrow(df))) {
        charge_detail_buffer$add(df[ii, , drop = FALSE])
      }
    }
    invisible(NULL)
  }

  counts <- list(stop = 0L, charge = 0L, refuel = 0L)
  schedule <- init_schedule_state(cfg)
  hos <- init_hos_state()
  tcur <- start_time
  add_event(tcur, tcur, "DEPART_DEPOT", route_segments$lat[[1]], route_segments$lng[[1]], reason = "start")

  load_unload_min <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$load_unload_min %||% NA_real_))) {
    as.numeric(exogenous_draws$load_unload_min)
  } else {
    as.numeric(sim_pick_distribution(cfg$driver_time$load_unload_min, rng = rng))
  }
  if (is.finite(load_unload_min) && load_unload_min > 0) {
    tnext <- tcur + load_unload_min * 60
    add_event(tcur, tnext, "LOAD_UNLOAD_START", route_segments$lat[[1]], route_segments$lng[[1]], reason = "pickup")
    lu <- schedule_add_on_duty(schedule, hos, load_unload_min)
    schedule <- lu$schedule
    hos <- lu$hos
    schedule$time_load_unload_min <- as.numeric(schedule$time_load_unload_min) + load_unload_min
    tcur <- tnext
    counts$stop <- counts$stop + 1L
  }

  prop_kwh <- 0
  diesel_gal <- 0
  tru_kwh <- 0
  tru_gal <- 0
  co2 <- 0
  delay_min <- 0
  detour_min <- 0
  od_hits <- 0L
  driving_h <- 0
  traffic_delay_h <- 0
  service_h <- 0
  rest_h <- 0

  battery_kwh <- as.numeric(cfg$tractors$bev_ecascadia$usable_battery_kwh %||% 438)
  soc <- if (powertrain == "bev") as.numeric(cfg$tractors$bev_ecascadia$soc_policy$soc_max %||% 0.85) else NA_real_
  soc_min <- as.numeric(cfg$tractors$bev_ecascadia$soc_policy$soc_min %||% 0.15)
  soc_target <- as.numeric(cfg$tractors$bev_ecascadia$soc_policy$soc_target_after_charge %||% 0.80)
  fuel_cap <- as.numeric(cfg$diesel_refuel$tank_capacity_gal %||% 200)
  fuel_gal <- if (powertrain == "diesel") fuel_cap * as.numeric(cfg$diesel_refuel$start_fuel_fraction %||% 0.9) else NA_real_

  mpg <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$mpg %||% NA_real_))) {
    as.numeric(exogenous_draws$mpg)
  } else sim_pick_distribution(cfg$tractors$diesel_cascadia$mpg, rng = rng)
  grid_kg_per_kwh <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$grid_kg_per_kwh %||% NA_real_))) {
    as.numeric(exogenous_draws$grid_kg_per_kwh)
  } else sim_pick_distribution(cfg$emissions$grid_intensity_gco2_per_kwh, rng = rng) / 1000

  coeff <- list(
    base = as.numeric(cfg$tractors$bev_ecascadia$propulsion_energy_kwh_per_mile$distribution$mode %||% 1.8),
    mass = 2.5e-5,
    grade = 0.7,
    speed2 = 2e-4,
    baseline_mass_lb = 60000
  )

  stops_plan <- if (is.null(planned_stops)) data.frame() else planned_stops
  if (nrow(stops_plan) > 0) stops_plan <- stops_plan[order(stops_plan$stop_idx), , drop = FALSE]
  next_stop_idx <- 1L
  plan_soc_violation <- FALSE
  allow_emergency_charge <- isTRUE(cfg$charging$allow_emergency_charge %||% FALSE)
  max_emergency_charges <- suppressWarnings(as.integer(cfg$charging$max_emergency_charges %||% 512L))
  if (!is.finite(max_emergency_charges) || max_emergency_charges < 1L) max_emergency_charges <- 512L
  stochastic_charge_enabled <- identical(powertrain, "bev") &&
    exists("charging_feature_enabled", mode = "function") &&
    isTRUE(charging_feature_enabled(cfg$charging))
  if (!is.data.frame(charging_candidates)) charging_candidates <- data.frame()

  log_charge_attempts <- function(df) {
    if (!exists("log_event", mode = "function") || !is.data.frame(df) || nrow(df) == 0) return(invisible(NULL))
    for (ii in seq_len(nrow(df))) {
      row <- df[ii, , drop = FALSE]
      msg <- paste0(
        "phase=", as.character(row$phase[[1]] %||% NA_character_),
        " stop_index=", as.character(row$stop_index[[1]] %||% NA_character_),
        " charger_id=", as.character(row$charger_id[[1]] %||% NA_character_),
        " station_id=", as.character(row$station_id[[1]] %||% NA_character_),
        " compatible=", tolower(as.character(row$compatible[[1]] %||% FALSE)),
        " reason=", as.character(row$incompatibility_reason[[1]] %||% NA_character_),
        " state=", as.character(row$state_drawn[[1]] %||% NA_character_),
        " wait_min=", formatC(as.numeric(row$wait_time_minutes[[1]] %||% 0), format = "f", digits = 2)
      )
      log_event(
        level = toupper(as.character(row$decision_status[[1]] %||% "INFO")),
        phase = "charge_decision",
        msg = msg
      )
    }
    invisible(NULL)
  }

  stop_detour_minutes <- function(stop_row) {
    fallback <- if ("detour_miles" %in% names(stop_row) && is.finite(stop_row$detour_miles[[1]])) {
      (as.numeric(stop_row$detour_miles[[1]]) * 2 / 35) * 60
    } else 0
    if (is.null(od_cache) || nrow(od_cache) == 0) return(list(minutes = fallback, hit = FALSE))
    keys <- unique(na.omit(c(
      as.character(stop_row$station_id[[1]] %||% NA_character_),
      as.character(stop_row$place_id[[1]] %||% NA_character_),
      as.character(stop_row$route_id[[1]] %||% NA_character_),
      as.character(stop_row$route_plan_id[[1]] %||% NA_character_)
    )))
    if (length(keys) < 2) return(list(minutes = fallback, hit = FALSE))
    hit <- od_cache[od_cache$origin_id %in% keys & od_cache$dest_id %in% keys, , drop = FALSE]
    if (nrow(hit) == 0) return(list(minutes = fallback, hit = FALSE))
    if ("status" %in% names(hit)) {
      hit <- hit[toupper(as.character(hit$status)) == "OK", , drop = FALSE]
      if (nrow(hit) == 0) return(list(minutes = fallback, hit = FALSE))
    }
    dur <- suppressWarnings(as.numeric(hit$road_duration_minutes))
    dur <- dur[is.finite(dur) & dur > 0]
    if (length(dur) == 0) return(list(minutes = fallback, hit = FALSE))
    list(minutes = min(dur), hit = TRUE)
  }

  charge_detour_minutes <- function(stop_row) {
    ddet <- stop_detour_minutes(stop_row)
    list(
      minutes = as.numeric(ddet$minutes %||% estimate_charge_detour_minutes(stop_row)),
      hit = isTRUE(ddet$hit)
    )
  }

  record_selected_charger <- function(stop_row) {
    station_kw <- coalesce_numeric_field(stop_row, c("max_charge_rate_kw", "power_kw"), default = NA_real_)
    station_id_i <- coalesce_character_field(stop_row, c("station_id", "charger_id"), default = NA_character_)
    connector_vals <- charger_connector_set(stop_row)
    charger_type_i <- coalesce_character_field(stop_row, c("charger_type", "station_class"), default = NA_character_)
    if (is.finite(station_kw)) {
      usage_charger_levels$add(if (station_kw >= 50) "dc_fast" else "level_2")
      max_charge_rate_kw_min <<- if (is.finite(max_charge_rate_kw_min)) min(max_charge_rate_kw_min, station_kw) else station_kw
      max_charge_rate_kw_max <<- if (is.finite(max_charge_rate_kw_max)) max(max_charge_rate_kw_max, station_kw) else station_kw
    }
    usage_station_ids$add(station_id_i)
    usage_connector_types$add(connector_vals)
    usage_charger_types$add(charger_type_i)
    invisible(NULL)
  }

  execute_emergency_virtual_charge <- function(seg, soc_value, vehicle_kw, connector_overhead_min, reason_label = "emergency_soc_recovery") {
    soc_for_charge <- max(0.01, min(0.99, as.numeric(soc_value)))
    cmin <- compute_charge_minutes(soc_for_charge, soc_target, battery_kwh, vehicle_kw, cfg$charging$charge_curve, rng = rng)
    counts$charge <<- counts$charge + 1L
    counts$stop <<- counts$stop + 1L
    add_kwh <- max(0, (soc_target - soc_for_charge) * battery_kwh)
    conn1 <- tcur + connector_overhead_min * 60
    add_event(tcur, conn1, "CHARGE_CONNECTOR_OVERHEAD", seg$lat[[1]], seg$lng[[1]], reason = reason_label)
    add_event(conn1, conn1, "CHARGE_START", seg$lat[[1]], seg$lng[[1]], energy_delta_kwh = 0, reason = reason_label)
    c1 <- conn1 + cmin * 60
    add_event(c1, c1, "CHARGE_END", seg$lat[[1]], seg$lng[[1]], energy_delta_kwh = add_kwh, reason = reason_label)

    delay_min <<- delay_min + connector_overhead_min + cmin
    seg_service_h <<- seg_service_h + resolve_service_time_hours("bev", connector_overhead_min + cmin)
    service_h <<- service_h + resolve_service_time_hours("bev", connector_overhead_min + cmin)
    sched1 <- schedule_add_on_duty(schedule, hos, connector_overhead_min + cmin)
    schedule <<- sched1$schedule
    hos <<- sched1$hos
    schedule$time_charging_min <<- as.numeric(schedule$time_charging_min) + cmin + connector_overhead_min
    tcur <<- c1
    soc <<- soc_target

    if (stochastic_charge_enabled && exists("build_charge_attempt_row", mode = "function")) {
      virtual_row <- data.frame(
        charger_id = "EMERGENCY_VIRTUAL",
        station_id = "EMERGENCY_VIRTUAL",
        station_class = "emergency_virtual",
        max_charge_rate_kw = as.numeric(vehicle_kw),
        detour_miles = 0,
        stringsAsFactors = FALSE
      )
      attempts_df <- build_charge_attempt_row(
        charger_row = virtual_row,
        eligibility = list(
          compatible = TRUE,
          charger_id = "EMERGENCY_VIRTUAL",
          station_id = "EMERGENCY_VIRTUAL",
          station_class = "emergency_virtual"
        ),
        phase = "emergency",
        attempt_index = 1L,
        state_drawn = "available",
        wait_time_minutes = 0,
        compatible_candidates_considered = 1L,
        decision_status = "emergency_virtual",
        pre_charge_soc = soc_for_charge
      )
      attempts_df <- finalize_charge_attempts(
        attempts_df,
        charge_duration_minutes = cmin,
        post_charge_soc = soc_target,
        hos_impact_minutes = connector_overhead_min + cmin,
        reefer_runtime_increment_minutes = connector_overhead_min + cmin
      )
      append_charge_attempts(attempts_df)
      log_charge_attempts(attempts_df)
    }
  }

  predict_energy_to_miles <- function(cur_dist, target_dist, speed_mph) {
    if (!is.finite(target_dist) || target_dist <= cur_dist) return(0)
    rows <- which(route_segments$distance_miles_cum > cur_dist & route_segments$distance_miles_cum <= target_dist)
    if (length(rows) == 0) return(0)
    e <- 0
    for (rr in rows) {
      sg <- route_segments[rr, , drop = FALSE]
      e_prop <- compute_propulsion_kwh_segment(
        seg_miles = sg$seg_miles[[1]],
        speed_mph = speed_mph,
        grade = sg$grade[[1]],
        payload_lb = payload_lb,
        trailer_tare_lb = trailer_tare_lb,
        tractor_weight_lb = 22000,
        coeff = coeff
      )
      tr <- compute_tru_segment(
        sg$seg_miles[[1]],
        sg$seg_miles[[1]] / max(speed_mph, 1),
        ambient_f,
        cfg,
        powertrain = "bev",
        cold_chain_required = cold_chain_required,
        rng = rng
      )
      e <- e + e_prop + tr$tru_kwh
    }
    e
  }

  for (i in seq_len(nrow(route_segments))) {
    seg <- route_segments[i, , drop = FALSE]
    if (tcur >= end_time) break
    seg_service_h <- 0

    hos_gate <- enforce_hos_before_driving(
      hos = hos,
      schedule = schedule,
      tcur = tcur,
      counts = counts,
      add_event_fn = add_event,
      lat = seg$lat[[1]],
      lng = seg$lng[[1]],
      cfg = cfg
    )
    hos <- hos_gate$hos
    schedule <- hos_gate$schedule
    tcur <- hos_gate$tcur
    counts <- hos_gate$counts

    mult <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$traffic_multiplier %||% NA_real_))) {
      as.numeric(exogenous_draws$traffic_multiplier)
    } else sample_traffic_multiplier(tcur, cfg$traffic, rng = rng)
    speed_mph <- max(5, as.numeric(base_speed_mph) * as.numeric(mult))
    travel_h <- seg$seg_miles[[1]] / speed_mph
    incident_min <- sample_incident_delay_minutes(seg$seg_miles[[1]], cfg$traffic, rng = rng)

    tru <- compute_tru_segment(
      seg$seg_miles[[1]],
      travel_h,
      ambient_f,
      cfg,
      powertrain = powertrain,
      cold_chain_required = cold_chain_required,
      rng = rng
    )

    fuel_type_label <- NA_character_
    if (powertrain == "bev") {
      # Optional SOC risk lookahead can be expensive on long routes; keep it off in
      # production Monte Carlo paths and rely on hard SOC checks + emergency handling.
      if (FALSE && nrow(stops_plan) > 0 && next_stop_idx <= nrow(stops_plan)) {
        next_stop_miles <- as.numeric(stops_plan$stop_cum_miles[[next_stop_idx]])
        e_need <- predict_energy_to_miles(seg$distance_miles_cum[[1]], next_stop_miles, speed_mph)
        if (is.finite(e_need) && (soc - e_need / battery_kwh) < soc_min) {
          add_event(tcur, tcur, "PLAN_SOC_RISK", seg$lat[[1]], seg$lng[[1]], reason = paste0("before_stop_idx=", next_stop_idx))
        }
      }

      e_seg <- compute_propulsion_kwh_segment(
        seg_miles = seg$seg_miles[[1]],
        speed_mph = speed_mph,
        grade = seg$grade[[1]],
        payload_lb = payload_lb,
        trailer_tare_lb = trailer_tare_lb,
        tractor_weight_lb = 22000,
        coeff = coeff
      )
      e_total <- e_seg + tru$tru_kwh
      soc <- soc - e_total / battery_kwh
      prop_kwh <- prop_kwh + e_seg
      tru_kwh <- tru_kwh + tru$tru_kwh
      co2 <- co2 + e_total * grid_kg_per_kwh

      if (soc < soc_min) {
        # Fail-safe: if the planned stop set cannot prevent SOC breach, insert an
        # immediate emergency charging dwell at the current segment so the route
        # can still be evaluated end-to-end for paired LCI comparisons.
        if (isTRUE(allow_emergency_charge)) {
          if (as.integer(counts$charge %||% 0L) >= max_emergency_charges) {
            plan_soc_violation <- TRUE
            add_event(tcur, tcur, "PLAN_SOC_VIOLATION", seg$lat[[1]], seg$lng[[1]], reason = "emergency_charge_cap_reached")
            break
          }
          connector_overhead_min <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$connector_overhead_min %||% NA_real_))) {
            as.numeric(exogenous_draws$connector_overhead_min)
          } else as.numeric(sim_pick_distribution(cfg$driver_time$charge_connector_overhead_min, rng = rng))
          if (!is.finite(connector_overhead_min) || connector_overhead_min < 0) connector_overhead_min <- 0
          vehicle_kw <- as.numeric(cfg$tractors$bev_ecascadia$max_charge_power_kw$single_port %||% 180)
          if (!is.finite(vehicle_kw) || vehicle_kw <= 0) vehicle_kw <- 150
          if (stochastic_charge_enabled && exists("resolve_stochastic_charge_decision", mode = "function")) {
            anchor_row <- data.frame(
              station_id = "EMERGENCY_ANCHOR",
              charger_id = "EMERGENCY_ANCHOR",
              lat = as.numeric(seg$lat[[1]]),
              lng = as.numeric(seg$lng[[1]]),
              stop_cum_miles = as.numeric(seg$distance_miles_cum[[1]]),
              max_charge_rate_kw = as.numeric(vehicle_kw),
              connector_types = paste(truck_connector_set(cfg$charging, cfg$tractors$bev_ecascadia), collapse = "|"),
              detour_miles = 0,
              stringsAsFactors = FALSE
            )
            charge_decision <- resolve_stochastic_charge_decision(
              anchor_row = anchor_row,
              charging_candidates = charging_candidates,
              charging_cfg = cfg$charging,
              tractor_cfg = cfg$tractors$bev_ecascadia,
              scenario = scenario,
              current_time = tcur,
              current_distance_miles = as.numeric(seg$distance_miles_cum[[1]]),
              current_soc = soc,
              battery_kwh = battery_kwh,
              soc_min = soc_min,
              speed_mph = speed_mph,
              predict_energy_fn = predict_energy_to_miles,
              phase = "emergency",
              stop_index = as.integer(counts$charge %||% 0L) + 1L,
              seed = as.integer(seed) + as.integer(counts$charge %||% 0L) * 1013L
            )
            if (is.data.frame(charge_decision$attempts) && nrow(charge_decision$attempts) > 0) {
              log_charge_attempts(charge_decision$attempts)
            }
            if (isTRUE(charge_decision$success)) {
              chosen_row <- charge_decision$chosen_row
              ddet <- charge_detour_minutes(chosen_row)
              dmin <- as.numeric(ddet$minutes %||% 0)
              if (isTRUE(ddet$hit)) od_hits <- od_hits + 1L
              qmin <- as.numeric(charge_decision$wait_time_minutes %||% 0)
              station_kw <- coalesce_numeric_field(chosen_row, c("max_charge_rate_kw", "power_kw"), default = vehicle_kw)
              record_selected_charger(chosen_row)
              max_kw <- min(station_kw, vehicle_kw, na.rm = TRUE)
              if (!is.finite(max_kw) || max_kw <= 0) max_kw <- vehicle_kw
              soc_for_charge <- max(0.01, min(0.99, as.numeric(soc)))
              cmin <- compute_charge_minutes(soc_for_charge, soc_target, battery_kwh, max_kw, cfg$charging$charge_curve, rng = rng)
              counts$charge <- counts$charge + 1L
              counts$stop <- counts$stop + 1L
              add_kwh <- max(0, (soc_target - soc_for_charge) * battery_kwh)
              charge_lat <- coalesce_numeric_field(chosen_row, c("lat"), default = as.numeric(seg$lat[[1]]))
              charge_lng <- coalesce_numeric_field(chosen_row, c("lng"), default = as.numeric(seg$lng[[1]]))

              t0 <- tcur + dmin * 60
              q1 <- t0 + qmin * 60
              if (qmin > 0) {
                add_event(t0, t0, "QUEUE_START", charge_lat, charge_lng, reason = "emergency_soc_recovery")
                add_event(q1, q1, "QUEUE_END", charge_lat, charge_lng, reason = "emergency_soc_recovery")
              }
              conn1 <- q1 + connector_overhead_min * 60
              add_event(q1, conn1, "CHARGE_CONNECTOR_OVERHEAD", charge_lat, charge_lng, reason = "emergency_soc_recovery")
              add_event(conn1, conn1, "CHARGE_START", charge_lat, charge_lng, energy_delta_kwh = 0, reason = "emergency_soc_recovery")
              c1 <- conn1 + cmin * 60
              add_event(c1, c1, "CHARGE_END", charge_lat, charge_lng, energy_delta_kwh = add_kwh, reason = "emergency_soc_recovery")

              delay_min <- delay_min + dmin + qmin + connector_overhead_min + cmin
              detour_min <- detour_min + dmin
              seg_service_h <- seg_service_h + resolve_service_time_hours("bev", dmin + qmin + connector_overhead_min + cmin)
              service_h <- service_h + resolve_service_time_hours("bev", dmin + qmin + connector_overhead_min + cmin)
              sched1 <- schedule_add_on_duty(schedule, hos, dmin + qmin + connector_overhead_min + cmin)
              schedule <- sched1$schedule
              hos <- sched1$hos
              schedule$time_charging_min <- as.numeric(schedule$time_charging_min) + cmin + connector_overhead_min
              tcur <- c1
              soc <- soc_target

              attempts_done <- finalize_charge_attempts(
                charge_decision$attempts,
                charge_duration_minutes = cmin,
                post_charge_soc = soc_target,
                hos_impact_minutes = dmin + qmin + connector_overhead_min + cmin,
                reefer_runtime_increment_minutes = dmin + qmin + connector_overhead_min + cmin
              )
              append_charge_attempts(attempts_done)
            } else {
              append_charge_attempts(charge_decision$attempts)
              execute_emergency_virtual_charge(
                seg = seg,
                soc_value = soc,
                vehicle_kw = vehicle_kw,
                connector_overhead_min = connector_overhead_min
              )
            }
          } else {
            qmin <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$queue_delay_minutes %||% NA_real_))) {
              as.numeric(exogenous_draws$queue_delay_minutes)
            } else sample_queue_delay_minutes(tcur, cfg$charging, cfg$traffic, rng = rng)
            soc_for_charge <- max(0.01, min(0.99, as.numeric(soc)))
            cmin <- compute_charge_minutes(soc_for_charge, soc_target, battery_kwh, vehicle_kw, cfg$charging$charge_curve, rng = rng)
            counts$charge <- counts$charge + 1L
            counts$stop <- counts$stop + 1L
            add_kwh <- max(0, (soc_target - soc_for_charge) * battery_kwh)

            q1 <- tcur + qmin * 60
            if (qmin > 0) {
              add_event(tcur, tcur, "QUEUE_START", seg$lat[[1]], seg$lng[[1]], reason = "emergency_soc_recovery")
              add_event(q1, q1, "QUEUE_END", seg$lat[[1]], seg$lng[[1]], reason = "emergency_soc_recovery")
            }
            conn1 <- q1 + connector_overhead_min * 60
            add_event(q1, conn1, "CHARGE_CONNECTOR_OVERHEAD", seg$lat[[1]], seg$lng[[1]], reason = "emergency_soc_recovery")
            add_event(conn1, conn1, "CHARGE_START", seg$lat[[1]], seg$lng[[1]], energy_delta_kwh = 0, reason = "emergency_soc_recovery")
            c1 <- conn1 + cmin * 60
            add_event(c1, c1, "CHARGE_END", seg$lat[[1]], seg$lng[[1]], energy_delta_kwh = add_kwh, reason = "emergency_soc_recovery")

            delay_min <- delay_min + qmin + connector_overhead_min + cmin
            seg_service_h <- seg_service_h + resolve_service_time_hours("bev", qmin + connector_overhead_min + cmin)
            service_h <- service_h + resolve_service_time_hours("bev", qmin + connector_overhead_min + cmin)
            sched1 <- schedule_add_on_duty(schedule, hos, qmin + connector_overhead_min + cmin)
            schedule <- sched1$schedule
            hos <- sched1$hos
            schedule$time_charging_min <- as.numeric(schedule$time_charging_min) + cmin + connector_overhead_min
            tcur <- c1
            soc <- soc_target
          }
        } else {
          plan_soc_violation <- TRUE
          add_event(tcur, tcur, "PLAN_SOC_VIOLATION", seg$lat[[1]], seg$lng[[1]], reason = "SOC below minimum")
          break
        }
      }

      if (nrow(stops_plan) > 0 && next_stop_idx <= nrow(stops_plan)) {
        stop_row <- stops_plan[next_stop_idx, , drop = FALSE]
        if (seg$distance_miles_cum[[1]] >= stop_row$stop_cum_miles[[1]]) {
          connector_overhead_min <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$connector_overhead_min %||% NA_real_))) {
            as.numeric(exogenous_draws$connector_overhead_min)
          } else as.numeric(sim_pick_distribution(cfg$driver_time$charge_connector_overhead_min, rng = rng))
          if (!is.finite(connector_overhead_min) || connector_overhead_min < 0) connector_overhead_min <- 0
          if (stochastic_charge_enabled && exists("resolve_stochastic_charge_decision", mode = "function")) {
            charge_decision <- resolve_stochastic_charge_decision(
              anchor_row = stop_row,
              charging_candidates = charging_candidates,
              charging_cfg = cfg$charging,
              tractor_cfg = cfg$tractors$bev_ecascadia,
              scenario = scenario,
              current_time = tcur,
              current_distance_miles = as.numeric(seg$distance_miles_cum[[1]]),
              current_soc = soc,
              battery_kwh = battery_kwh,
              soc_min = soc_min,
              speed_mph = speed_mph,
              predict_energy_fn = predict_energy_to_miles,
              phase = "planned",
              stop_index = next_stop_idx,
              seed = as.integer(seed) + next_stop_idx * 1009L
            )
            if (is.data.frame(charge_decision$attempts) && nrow(charge_decision$attempts) > 0) {
              log_charge_attempts(charge_decision$attempts)
            }
            if (isTRUE(charge_decision$success)) {
              chosen_row <- charge_decision$chosen_row
              ddet <- charge_detour_minutes(chosen_row)
              dmin <- as.numeric(ddet$minutes %||% 0)
              if (isTRUE(ddet$hit)) od_hits <- od_hits + 1L
              qmin <- as.numeric(charge_decision$wait_time_minutes %||% 0)
              vehicle_kw <- as.numeric(cfg$tractors$bev_ecascadia$max_charge_power_kw$single_port %||% 180)
              station_kw <- coalesce_numeric_field(chosen_row, c("max_charge_rate_kw", "power_kw"), default = vehicle_kw)
              record_selected_charger(chosen_row)
              max_kw <- min(station_kw, vehicle_kw, na.rm = TRUE)
              if (!is.finite(max_kw) || max_kw <= 0) max_kw <- vehicle_kw
              cmin <- compute_charge_minutes(soc, soc_target, battery_kwh, max_kw, cfg$charging$charge_curve, rng = rng)
              counts$charge <- counts$charge + 1L
              counts$stop <- counts$stop + 1L

              charge_lat <- coalesce_numeric_field(chosen_row, c("lat"), default = as.numeric(stop_row$lat[[1]]))
              charge_lng <- coalesce_numeric_field(chosen_row, c("lng"), default = as.numeric(stop_row$lng[[1]]))
              t0 <- tcur + dmin * 60
              q1 <- t0 + qmin * 60
              if (qmin > 0) {
                add_event(t0, t0, "QUEUE_START", charge_lat, charge_lng, reason = paste0("planned_stop_idx=", next_stop_idx))
                add_event(q1, q1, "QUEUE_END", charge_lat, charge_lng, reason = paste0("planned_stop_idx=", next_stop_idx))
              }
              add_kwh <- max(0, (soc_target - soc) * battery_kwh)
              conn1 <- q1 + connector_overhead_min * 60
              add_event(q1, conn1, "CHARGE_CONNECTOR_OVERHEAD", charge_lat, charge_lng, reason = paste0("planned_stop_idx=", next_stop_idx))
              add_event(conn1, conn1, "CHARGE_START", charge_lat, charge_lng, energy_delta_kwh = 0, reason = paste0("planned_stop_idx=", next_stop_idx))
              c1 <- conn1 + cmin * 60
              add_event(c1, c1, "CHARGE_END", charge_lat, charge_lng, energy_delta_kwh = add_kwh, reason = paste0("planned_stop_idx=", next_stop_idx))
              delay_min <- delay_min + dmin + qmin + connector_overhead_min + cmin
              detour_min <- detour_min + dmin
              seg_service_h <- resolve_service_time_hours("bev", dmin + qmin + connector_overhead_min + cmin)
              service_h <- service_h + seg_service_h
              sched1 <- schedule_add_on_duty(schedule, hos, dmin + qmin + connector_overhead_min + cmin)
              schedule <- sched1$schedule
              hos <- sched1$hos
              schedule$time_charging_min <- as.numeric(schedule$time_charging_min) + cmin + connector_overhead_min
              tcur <- c1
              soc <- soc_target

              attempts_done <- finalize_charge_attempts(
                charge_decision$attempts,
                charge_duration_minutes = cmin,
                post_charge_soc = soc_target,
                hos_impact_minutes = dmin + qmin + connector_overhead_min + cmin,
                reefer_runtime_increment_minutes = dmin + qmin + connector_overhead_min + cmin
              )
              append_charge_attempts(attempts_done)
            } else {
              append_charge_attempts(charge_decision$attempts)
              add_event(
                tcur,
                tcur,
                "CHARGE_ATTEMPT_FAILED",
                as.numeric(stop_row$lat[[1]]),
                as.numeric(stop_row$lng[[1]]),
                reason = paste0("planned_stop_idx=", next_stop_idx, ";", as.character(charge_decision$failure_reason %||% "unknown"))
              )
            }
          } else {
            qmin <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$queue_delay_minutes %||% NA_real_))) {
              as.numeric(exogenous_draws$queue_delay_minutes)
            } else sample_queue_delay_minutes(tcur, cfg$charging, cfg$traffic, rng = rng)
            ddet <- stop_detour_minutes(stop_row)
            dmin <- as.numeric(ddet$minutes)
            if (isTRUE(ddet$hit)) od_hits <- od_hits + 1L
            station_kw <- as.numeric(stop_row$max_charge_rate_kw[[1]])
            record_selected_charger(stop_row)
            vehicle_kw <- as.numeric(cfg$tractors$bev_ecascadia$max_charge_power_kw$single_port %||% 180)
            max_kw <- min(station_kw, vehicle_kw, na.rm = TRUE)
            cmin <- compute_charge_minutes(soc, soc_target, battery_kwh, max_kw, cfg$charging$charge_curve, rng = rng)
            counts$charge <- counts$charge + 1L
            counts$stop <- counts$stop + 1L

            t0 <- tcur + dmin * 60
            q1 <- t0 + qmin * 60
            if (qmin > 0) {
              add_event(t0, t0, "QUEUE_START", stop_row$lat[[1]], stop_row$lng[[1]], reason = paste0("planned_stop_idx=", next_stop_idx))
              add_event(q1, q1, "QUEUE_END", stop_row$lat[[1]], stop_row$lng[[1]], reason = paste0("planned_stop_idx=", next_stop_idx))
            }
            add_kwh <- max(0, (soc_target - soc) * battery_kwh)
            conn1 <- q1 + connector_overhead_min * 60
            add_event(q1, conn1, "CHARGE_CONNECTOR_OVERHEAD", stop_row$lat[[1]], stop_row$lng[[1]], reason = paste0("planned_stop_idx=", next_stop_idx))
            add_event(conn1, conn1, "CHARGE_START", stop_row$lat[[1]], stop_row$lng[[1]], energy_delta_kwh = 0, reason = paste0("planned_stop_idx=", next_stop_idx))
            c1 <- conn1 + cmin * 60
            add_event(c1, c1, "CHARGE_END", stop_row$lat[[1]], stop_row$lng[[1]], energy_delta_kwh = add_kwh, reason = paste0("planned_stop_idx=", next_stop_idx))
            delay_min <- delay_min + dmin + qmin + connector_overhead_min + cmin
            detour_min <- detour_min + dmin
            seg_service_h <- resolve_service_time_hours("bev", dmin + qmin + connector_overhead_min + cmin)
            service_h <- service_h + seg_service_h
            sched1 <- schedule_add_on_duty(schedule, hos, dmin + qmin + connector_overhead_min + cmin)
            schedule <- sched1$schedule
            hos <- sched1$hos
            schedule$time_charging_min <- as.numeric(schedule$time_charging_min) + cmin + connector_overhead_min
            tcur <- c1
            soc <- soc_target
          }
          next_stop_idx <- next_stop_idx + 1L
        }
      }
    } else {
      gal_seg <- compute_diesel_gal_segment(seg$seg_miles[[1]], mpg)
      diesel_gal <- diesel_gal + gal_seg
      fuel_gal <- fuel_gal - (gal_seg + tru$tru_gal)
      tru_gal <- tru_gal + tru$tru_gal
      co2 <- co2 + gal_seg * as.numeric(cfg$emissions$diesel_co2_kg_per_gallon$baseline %||% 10.19)
      co2 <- co2 + tru$tru_gal * as.numeric(cfg$emissions$diesel_co2_kg_per_gallon$baseline %||% 10.19)

      if (needs_refuel(fuel_gal, fuel_cap, cfg$diesel_refuel$reserve_fuel_fraction %||% 0.15)) {
        qmin <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$queue_delay_minutes %||% NA_real_))) {
          as.numeric(exogenous_draws$queue_delay_minutes)
        } else sample_queue_delay_minutes(tcur, cfg$charging, cfg$traffic, rng = rng)
        ft <- cfg$diesel_fuel_types[[trip_leg]] %||% list(name = "ULSD", co2_kg_per_gallon = list(baseline = 10.19))
        re <- compute_refuel_event(fuel_gal, cfg$diesel_refuel, ft, queue_delay_minutes = qmin, rng = rng)
        counts$refuel <- counts$refuel + 1L
        counts$stop <- counts$stop + 1L
        t0 <- tcur
        t1 <- t0 + re$stop_minutes * 60
        add_event(t0, t1, "REFUEL_START", seg$lat[[1]], seg$lng[[1]], fuel_delta_gal = re$gallons_added, co2_delta_kg = re$co2_kg, reason = "fuel reserve threshold")
        fuel_gal <- fuel_gal + re$gallons_added
        co2 <- co2 + re$co2_kg
        delay_min <- delay_min + re$stop_minutes
        seg_service_h <- resolve_service_time_hours("diesel", re$stop_minutes)
        service_h <- service_h + seg_service_h
        sched2 <- schedule_add_on_duty(schedule, hos, re$stop_minutes)
        schedule <- sched2$schedule
        hos <- sched2$hos
        schedule$time_refuel_min <- as.numeric(schedule$time_refuel_min) + re$stop_minutes
        tcur <- t1
        fuel_type_label <- re$fuel_type_name
      }
    }

    tcur <- tcur + travel_h * 3600 + incident_min * 60
    driving_h <- driving_h + travel_h
    traffic_delay_h <- traffic_delay_h + incident_min / 60
    delay_min <- delay_min + incident_min
    sched3 <- schedule_add_driving(
      schedule = schedule,
      hos = hos,
      driving_minutes = travel_h * 60 + incident_min,
      traffic_delay_minutes = incident_min
    )
    schedule <- sched3$schedule
    hos <- sched3$hos

    t_state <- if (isTRUE(enforce_duration_limit) && tcur > end_time) end_time else tcur

    add_state(
      t = t_state,
      seg = seg,
      speed_mph = speed_mph,
      soc = soc,
      fuel_gal = fuel_gal,
      prop_kwh = prop_kwh,
      diesel_gal = diesel_gal,
      tru_kwh = tru_kwh,
      tru_gal = tru_gal,
      co2 = co2,
      delay_min = delay_min,
      detour_min = detour_min,
      od_hits = od_hits,
      counts = counts,
      driving_h = driving_h,
      traffic_delay_h = traffic_delay_h,
      service_h = service_h,
      rest_h = rest_h,
      fuel_type = fuel_type_label,
      grid_kg_per_kwh = if (powertrain == "bev") grid_kg_per_kwh else NA_real_
    )

    if (tcur >= end_time) break
  }

  completed <- FALSE
  if (!is.null(last_state_row) && nrow(last_state_row) > 0) {
    d_last <- suppressWarnings(as.numeric(last_state_row$distance_miles_cum[[1]]))
    d_max <- suppressWarnings(max(route_segments$distance_miles_cum, na.rm = TRUE))
    completed <- is.finite(d_last) && is.finite(d_max) && d_last >= d_max
  }
  if (completed && !plan_soc_violation) {
    add_event(tcur, tcur, "ROUTE_COMPLETE", route_segments$lat[[nrow(route_segments)]], route_segments$lng[[nrow(route_segments)]], reason = "completed")
  }

  if (completed && !plan_soc_violation) {
    if (is.finite(load_unload_min) && load_unload_min > 0) {
      t1 <- tcur + load_unload_min * 60
      add_event(tcur, t1, "LOAD_UNLOAD_END", route_segments$lat[[nrow(route_segments)]], route_segments$lng[[nrow(route_segments)]], reason = "delivery")
      sched4 <- schedule_add_on_duty(schedule, hos, load_unload_min)
      schedule <- sched4$schedule
      hos <- sched4$hos
      schedule$time_load_unload_min <- as.numeric(schedule$time_load_unload_min) + load_unload_min
      tcur <- t1
      counts$stop <- counts$stop + 1L
      service_h <- service_h + load_unload_min / 60
      delay_min <- delay_min + load_unload_min
    }

    posttrip_min <- as.numeric(cfg$driver_time$posttrip_min %||% 0)
    if (is.finite(posttrip_min) && posttrip_min > 0) {
      t1 <- tcur + posttrip_min * 60
      add_event(tcur, t1, "POSTTRIP", route_segments$lat[[nrow(route_segments)]], route_segments$lng[[nrow(route_segments)]], reason = "posttrip")
      sched5 <- schedule_add_on_duty(schedule, hos, posttrip_min)
      schedule <- sched5$schedule
      hos <- sched5$hos
      tcur <- t1
      service_h <- service_h + posttrip_min / 60
      delay_min <- delay_min + posttrip_min
    }
  }

  sched_tot <- schedule_totals(schedule)
  rest_h <- as.numeric(sched_tot$driver_off_duty_min) / 60
  service_h <- as.numeric(sched_tot$driver_on_duty_min - sched_tot$driver_driving_min) / 60

  # Refrigeration continues during non-driving hours; apply stationary runtime penalty.
  trip_rollup <- compute_trip_time_rollup(driving_h, traffic_delay_h, service_h, rest_h)
  stationary_h <- max(0, trip_rollup$trip_duration_h - driving_h)
  if (stationary_h > 0 && isTRUE(cold_chain_required)) {
    if (powertrain == "bev") {
      base_kw <- sim_pick_distribution(cfg$refrigeration_units$electric_vector_ecool$tru_power_kw_base, rng = rng)
      duty <- sim_pick_distribution(cfg$refrigeration_units$electric_vector_ecool$duty_cycle_base, rng = rng)
      add_kwh <- max(0, stationary_h * base_kw * duty)
      tru_kwh <- tru_kwh + add_kwh
      co2 <- co2 + add_kwh * grid_kg_per_kwh
    } else {
      base_gal_h <- sim_pick_distribution(cfg$refrigeration_units$diesel_vector_tru$fuel_gal_per_engine_hr, rng = rng)
      duty <- sim_pick_distribution(cfg$refrigeration_units$diesel_vector_tru$duty_cycle_base, rng = rng)
      add_gal <- max(0, stationary_h * base_gal_h * duty)
      tru_gal <- tru_gal + add_gal
      co2 <- co2 + add_gal * as.numeric(cfg$emissions$diesel_co2_kg_per_gallon$baseline %||% 10.19)
    }
  }
  refrigeration_runtime_hours <- if (isTRUE(cold_chain_required)) {
    max(0, trip_rollup$trip_duration_h)
  } else {
    0
  }
  if (!isTRUE(cold_chain_required)) {
    tru_kwh <- 0
    tru_gal <- 0
  }
  pkg_assump <- cfg$load_model$packaging_assumptions[[product_type]] %||% list()
  if (identical(state_retention, "full")) {
    sim_state_df <- state_buffer$collect()
  } else if (!is.null(first_state_row) && !is.null(last_state_row) && nrow(first_state_row) > 0 && nrow(last_state_row) > 0) {
    same_state <- identical(as.list(first_state_row[1, , drop = FALSE]), as.list(last_state_row[1, , drop = FALSE]))
    sim_state_df <- if (isTRUE(same_state)) first_state_row else rbind(first_state_row, last_state_row)
  } else if (!is.null(last_state_row) && nrow(last_state_row) > 0) {
    sim_state_df <- last_state_row
  } else {
    sim_state_df <- data.frame()
  }
  event_log_df <- if (isTRUE(retain_event_log)) event_buffer$collect() else data.frame()
  charge_details_df <- if (isTRUE(retain_charge_details)) charge_detail_buffer$collect() else data.frame()
  charge_attempts_n <- as.integer(charge_qa_acc$charging_attempts %||% 0L)
  charge_qa <- list(
    charging_attempts = charge_attempts_n,
    compatible_chargers_considered = as.integer(charge_qa_acc$compatible_chargers_considered %||% 0L),
    occupied_events = as.integer(charge_qa_acc$occupied_events %||% 0L),
    broken_events = as.integer(charge_qa_acc$broken_events %||% 0L),
    average_wait_time_minutes = if (charge_attempts_n > 0L) as.numeric(charge_qa_acc$total_wait_time_minutes %||% 0) / charge_attempts_n else 0,
    max_wait_time_minutes = as.numeric(charge_qa_acc$max_wait_time_minutes %||% 0),
    total_wait_time_minutes = as.numeric(charge_qa_acc$total_wait_time_minutes %||% 0),
    added_refrigeration_runtime_minutes_waiting = as.numeric(charge_qa_acc$added_refrigeration_runtime_minutes_waiting %||% 0),
    added_hos_delay_minutes_waiting = as.numeric(charge_qa_acc$added_hos_delay_minutes_waiting %||% 0),
    failed_charging_attempt_fraction = if (charge_attempts_n > 0L) {
      as.integer(charge_qa_acc$failed_attempt_rows %||% 0L) / charge_attempts_n
    } else {
      0
    }
  )

  list(
    sim_state = sim_state_df,
    event_log = event_log_df,
    charge_stop_details = charge_details_df,
      metadata = list(
        completed = completed && !plan_soc_violation,
      route_completed = completed && !plan_soc_violation,
      end_time = as.character(tcur),
      powertrain = powertrain,
      scenario = scenario,
      plan_soc_violation = plan_soc_violation,
      trip_time = trip_rollup,
      exogenous_draws = exogenous_draws,
        schedule = sched_tot,
        load = load_draw,
        packaging_source_type = as.character(pkg_assump$source_type %||% NA_character_),
        packaging_confidence_level = as.character(pkg_assump$confidence_level %||% NA_character_),
        packaging_rationale = as.character(pkg_assump$rationale %||% NA_character_),
        station_ids_used = usage_station_ids$values(),
        connector_types_used = usage_connector_types$values(),
        charger_types_used = usage_charger_types$values(),
        charger_levels_used = usage_charger_levels$values(),
        max_charge_rate_kw_max = max_charge_rate_kw_max,
        max_charge_rate_kw_min = max_charge_rate_kw_min,
        soc_min_observed = soc_min_observed,
        soc_max_observed = soc_max_observed,
        product_type = product_type,
        cold_chain_required = isTRUE(cold_chain_required),
        reefer_state = if (isTRUE(cold_chain_required)) "on" else "off",
        refrigeration_runtime_hours = refrigeration_runtime_hours,
        stochastic_charger_states_enabled = isTRUE(stochastic_charge_enabled),
        charger_state_case = if (exists("resolve_charger_state_case", mode = "function")) as.character(resolve_charger_state_case(cfg$charging)) else NA_character_,
        charge_qa = charge_qa,
        nutrition = list(
          kcal_per_kg_product = kcal_per_kg_product,
          protein_g_per_kg_product = protein_g_per_kg_product
        )
      )
  )
}
