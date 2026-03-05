# Event-driven 24h route simulation.

new_rng <- function(seed) {
  env <- new.env(parent = emptyenv())
  set.seed(as.integer(seed))
  env$runif <- function(...) stats::runif(...)
  env
}

sample_exogenous_draws <- function(cfg, seed = 123) {
  rng <- new_rng(seed)
  trailer <- sample_trailer_capacity(seed = seed + 100L, test_kit = cfg)
  dry_pack <- sample_product_packaging(seed = seed + 101L, product_type = "dry", test_kit = cfg)
  ref_pack <- sample_product_packaging(seed = seed + 102L, product_type = "refrigerated", test_kit = cfg)
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
    bags_per_pallet = as.numeric(dry_pack$bags_per_pallet),
    cases_per_pallet = as.numeric(ref_pack$cases_per_pallet),
    packs_per_case = as.numeric(ref_pack$packs_per_case),
    load_unload_min = as.numeric(sim_pick_distribution(cfg$driver_time$load_unload_min, rng = rng)),
    refuel_stop_min = as.numeric(sim_pick_distribution(cfg$driver_time$refuel_stop_min, rng = rng)),
    connector_overhead_min = as.numeric(sim_pick_distribution(cfg$driver_time$charge_connector_overhead_min, rng = rng))
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
    od_cache = NULL,
    exogenous_draws = NULL,
    product_type = "refrigerated") {
  powertrain <- match.arg(powertrain)
  trip_leg <- match.arg(trip_leg)
  rng <- new_rng(seed)

  start_time <- as.POSIXct(start_time %||% cfg$time_sim$start_datetime_local %||% "2026-03-04T00:00:00", tz = "UTC")
  duration_hours <- as.numeric(duration_hours %||% cfg$time_sim$duration_hours %||% 24)
  end_time <- start_time + duration_hours * 3600
  product_type <- infer_product_type_from_text(product_type, default = "refrigerated")

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

  load_draw <- resolve_load_draw(seed = as.integer(seed), cfg = cfg, product_type = product_type, exogenous_draws = exogenous_draws)
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

  events <- list()
  states <- list()
  ev_i <- 0L
  st_i <- 0L

  add_event <- function(t0, t1, type, lat, lng, energy_delta_kwh = 0, fuel_delta_gal = 0, co2_delta_kg = 0, reason = "") {
    ev_i <<- ev_i + 1L
    events[[ev_i]] <<- data.frame(
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
    )
  }

  add_state <- function(t, seg, speed_mph, soc, fuel_gal, prop_kwh, diesel_gal, tru_kwh, tru_gal, co2, delay_min, detour_min, od_hits, counts, driving_h, traffic_delay_h, service_h, rest_h, fuel_type = NA_character_, grid_kg_per_kwh = NA_real_) {
    st_i <<- st_i + 1L
    trip <- compute_trip_time_rollup(driving_h, traffic_delay_h, service_h, rest_h)
    states[[st_i]] <<- data.frame(
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
      tr <- compute_tru_segment(sg$seg_miles[[1]], sg$seg_miles[[1]] / max(speed_mph, 1), ambient_f, cfg, powertrain = "bev", rng = rng)
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

    tru <- compute_tru_segment(seg$seg_miles[[1]], travel_h, ambient_f, cfg, powertrain = powertrain, rng = rng)

    fuel_type_label <- NA_character_
    if (powertrain == "bev") {
      if (nrow(stops_plan) > 0 && next_stop_idx <= nrow(stops_plan)) {
        next_stop_miles <- as.numeric(stops_plan$stop_cum_miles[[next_stop_idx]])
        e_need <- predict_energy_to_miles(seg$distance_miles_cum[[1]], next_stop_miles, speed_mph)
        if (is.finite(e_need) && (soc - e_need / battery_kwh) < soc_min) {
          plan_soc_violation <- TRUE
          add_event(tcur, tcur, "PLAN_SOC_VIOLATION", seg$lat[[1]], seg$lng[[1]], reason = paste0("before_stop_idx=", next_stop_idx))
          break
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
        plan_soc_violation <- TRUE
        add_event(tcur, tcur, "PLAN_SOC_VIOLATION", seg$lat[[1]], seg$lng[[1]], reason = "SOC below minimum")
        break
      }

      if (nrow(stops_plan) > 0 && next_stop_idx <= nrow(stops_plan)) {
        stop_row <- stops_plan[next_stop_idx, , drop = FALSE]
        if (seg$distance_miles_cum[[1]] >= stop_row$stop_cum_miles[[1]]) {
          qmin <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$queue_delay_minutes %||% NA_real_))) {
            as.numeric(exogenous_draws$queue_delay_minutes)
          } else sample_queue_delay_minutes(tcur, cfg$charging, cfg$traffic, rng = rng)
          connector_overhead_min <- if (!is.null(exogenous_draws) && is.finite(as.numeric(exogenous_draws$connector_overhead_min %||% NA_real_))) {
            as.numeric(exogenous_draws$connector_overhead_min)
          } else as.numeric(sim_pick_distribution(cfg$driver_time$charge_connector_overhead_min, rng = rng))
          if (!is.finite(connector_overhead_min) || connector_overhead_min < 0) connector_overhead_min <- 0
          ddet <- stop_detour_minutes(stop_row)
          dmin <- as.numeric(ddet$minutes)
          if (isTRUE(ddet$hit)) od_hits <- od_hits + 1L
          station_kw <- as.numeric(stop_row$max_charge_rate_kw[[1]])
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

    add_state(
      t = tcur,
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
  if (length(states) > 0) {
    d_last <- suppressWarnings(as.numeric(states[[length(states)]]$distance_miles_cum[[1]]))
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
  if (stationary_h > 0) {
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

  list(
    sim_state = if (length(states) > 0) do.call(rbind, states) else data.frame(),
    event_log = if (length(events) > 0) do.call(rbind, events) else data.frame(),
    metadata = list(
      completed = completed && !plan_soc_violation,
      end_time = as.character(tcur),
      powertrain = powertrain,
      scenario = scenario,
      plan_soc_violation = plan_soc_violation,
      trip_time = trip_rollup,
      exogenous_draws = exogenous_draws,
      schedule = sched_tot,
      load = load_draw,
      product_type = product_type,
      nutrition = list(
        kcal_per_kg_product = kcal_per_kg_product,
        protein_g_per_kg_product = protein_g_per_kg_product
      )
    )
  )
}
