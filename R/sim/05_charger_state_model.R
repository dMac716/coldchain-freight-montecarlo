# Charger eligibility, stochastic state, and charge-stop QA helpers.

`%||%` <- function(x, y) if (!is.null(x)) x else y

new_local_rng <- function(seed) {
  env <- new.env(parent = emptyenv())
  state <- suppressWarnings(as.numeric(seed))
  if (!is.finite(state)) state <- 1
  state <- floor(abs(state)) %% 2147483647
  if (!is.finite(state) || state <= 0) state <- 1

  next_unit <- function() {
    state <<- (1103515245 * state + 12345) %% 2147483647
    as.numeric(state) / 2147483647
  }

  env$runif <- function(n = 1L, min = 0, max = 1) {
    n <- max(1L, as.integer(n %||% 1L))
    u <- vapply(seq_len(n), function(i) next_unit(), numeric(1))
    as.numeric(min) + (as.numeric(max) - as.numeric(min)) * u
  }

  env$rnorm <- function(n = 1L, mean = 0, sd = 1) {
    n <- max(1L, as.integer(n %||% 1L))
    out <- numeric(n)
    i <- 1L
    while (i <= n) {
      u1 <- max(next_unit(), 1e-12)
      u2 <- next_unit()
      r <- sqrt(-2 * log(u1))
      theta <- 2 * pi * u2
      z1 <- r * cos(theta)
      z2 <- r * sin(theta)
      out[[i]] <- z1
      if ((i + 1L) <= n) out[[i + 1L]] <- z2
      i <- i + 2L
    }
    as.numeric(mean) + as.numeric(sd) * out
  }

  env
}

normalize_config_key <- function(x) {
  tolower(gsub("[^a-z0-9]+", "_", trimws(as.character(x %||% ""))))
}

pick_named_override <- function(spec, key) {
  if (is.null(spec) || is.null(key) || !nzchar(as.character(key))) return(NULL)
  nms <- names(spec)
  if (is.null(nms) || length(nms) == 0) return(NULL)
  nk <- normalize_config_key(key)
  nn <- vapply(nms, normalize_config_key, character(1))
  idx <- which(nn == nk)
  if (length(idx) == 0) return(NULL)
  spec[[idx[[1]]]]
}

normalize_connector_token <- function(x) {
  raw <- toupper(trimws(as.character(x %||% "")))
  if (!nzchar(raw)) return(NA_character_)
  if (grepl("CCS|COMBO", raw)) return("CCS")
  if (grepl("J1772", raw)) return("J1772")
  if (grepl("NACS", raw)) return("NACS")
  if (grepl("TESLA", raw)) return("TESLA")
  raw
}

normalize_connector_set <- function(x) {
  vals <- x
  if (is.list(vals)) vals <- unlist(vals, use.names = FALSE)
  vals <- as.character(vals %||% character())
  vals <- vals[nzchar(trimws(vals)) & !is.na(vals)]
  if (length(vals) == 0) return(character())
  out <- vapply(vals, normalize_connector_token, character(1))
  out <- out[nzchar(out) & !is.na(out)]
  unique(out)
}

charger_connector_set <- function(charger_row) {
  if (!is.data.frame(charger_row) || nrow(charger_row) == 0) return(character())
  cols <- c("connector_types_list", "connector_types", "connector_types_raw", "connector")
  vals <- list()
  for (nm in cols) {
    if (!nm %in% names(charger_row)) next
    vals[[length(vals) + 1L]] <- charger_row[[nm]][[1]]
  }
  normalize_connector_set(vals)
}

truck_connector_set <- function(charging_cfg, tractor_cfg = NULL) {
  vals <- list(
    charging_cfg$connector_types,
    charging_cfg$connector_required,
    tractor_cfg$connector_types,
    tractor_cfg$connector_required
  )
  normalize_connector_set(vals)
}

coalesce_numeric_field <- function(row, fields, default = NA_real_) {
  if (!is.data.frame(row) || nrow(row) == 0) return(as.numeric(default))
  for (nm in fields) {
    if (!nm %in% names(row)) next
    v <- suppressWarnings(as.numeric(row[[nm]][[1]]))
    if (is.finite(v)) return(v)
  }
  as.numeric(default)
}

coalesce_character_field <- function(row, fields, default = NA_character_) {
  if (!is.data.frame(row) || nrow(row) == 0) return(as.character(default))
  for (nm in fields) {
    if (!nm %in% names(row)) next
    v <- trimws(as.character(row[[nm]][[1]] %||% ""))
    if (nzchar(v) && !is.na(v)) return(v)
  }
  as.character(default)
}

coalesce_logical_field <- function(row, fields, default = NA) {
  if (!is.data.frame(row) || nrow(row) == 0) return(as.logical(default))
  for (nm in fields) {
    if (!nm %in% names(row)) next
    raw <- row[[nm]][[1]]
    if (is.logical(raw) && !is.na(raw)) return(isTRUE(raw))
    txt <- tolower(trimws(as.character(raw %||% "")))
    if (txt %in% c("true", "t", "1", "yes", "y")) return(TRUE)
    if (txt %in% c("false", "f", "0", "no", "n")) return(FALSE)
  }
  as.logical(default)
}

resolve_station_class <- function(charger_row) {
  explicit <- coalesce_character_field(charger_row, c("station_class", "charger_type", "charger_level"), default = "")
  if (nzchar(explicit)) return(normalize_config_key(explicit))
  kw <- coalesce_numeric_field(charger_row, c("max_charge_rate_kw", "power_kw"), default = NA_real_)
  if (!is.finite(kw)) return("unknown")
  if (kw >= 250) return("high_power_dc")
  if (kw >= 50) return("dc_fast")
  "level_2"
}

charging_feature_enabled <- function(charging_cfg) {
  root <- charging_cfg$stochastic_states %||% charging_cfg
  isTRUE(root$enable_stochastic_charger_states %||% charging_cfg$enable_stochastic_charger_states %||% FALSE)
}

resolve_charger_state_case <- function(charging_cfg) {
  root <- charging_cfg$stochastic_states %||% charging_cfg
  as.character(root$charger_state_case %||% charging_cfg$charger_state_case %||% NA_character_)
}

charger_power_min_kw <- function(charging_cfg) {
  root <- charging_cfg$stochastic_states %||% charging_cfg
  suppressWarnings(as.numeric(root$charger_power_min_kw %||% charging_cfg$charger_power_min_kw %||% charging_cfg$min_station_power_kw %||% 0))
}

resolve_modifier_entry <- function(spec, t = NULL) {
  if (is.null(spec) || !is.list(spec)) return(NULL)
  if (!is.null(spec$hours) && length(spec$hours) > 0 && !is.null(t)) {
    hour <- as.integer(format(as.POSIXct(t, tz = "UTC"), "%H"))
    hrs <- suppressWarnings(as.integer(unlist(spec$hours)))
    if (length(hrs) == 0 || !hour %in% hrs) return(NULL)
  }
  spec
}

resolve_time_bucket_override <- function(spec, t = NULL) {
  if (is.null(spec) || !is.list(spec) || is.null(t)) return(NULL)
  nms <- names(spec)
  if (is.null(nms)) return(NULL)
  for (nm in nms) {
    hit <- resolve_modifier_entry(spec[[nm]], t = t)
    if (!is.null(hit)) return(hit)
  }
  NULL
}

apply_probability_modifier <- function(base, modifier) {
  if (is.null(modifier)) return(base)
  out <- as.list(base %||% list())
  for (nm in c("p_broken", "p_occupied_given_not_broken")) {
    cur <- suppressWarnings(as.numeric(out[[nm]] %||% NA_real_))
    if (!is.finite(cur)) cur <- 0
    add <- suppressWarnings(as.numeric(modifier[[paste0(nm, "_add")]] %||% 0))
    mult <- suppressWarnings(as.numeric(modifier[[paste0(nm, "_mult")]] %||% 1))
    if (!is.finite(add)) add <- 0
    if (!is.finite(mult)) mult <- 1
    out[[nm]] <- cur * mult + add
  }
  out
}

normalize_charger_state_probabilities <- function(prob_spec) {
  p_broken <- suppressWarnings(as.numeric(prob_spec$p_broken %||% 0))
  p_occ <- suppressWarnings(as.numeric(prob_spec$p_occupied_given_not_broken %||% 0))
  if (!is.finite(p_broken)) p_broken <- 0
  if (!is.finite(p_occ)) p_occ <- 0
  p_broken <- max(0, min(1, p_broken))
  p_occ <- max(0, min(1, p_occ))
  p_available <- max(0, (1 - p_broken) * (1 - p_occ))
  total <- p_broken + ((1 - p_broken) * p_occ) + p_available
  if (!is.finite(total) || total <= 0) {
    return(c(available = 1, occupied = 0, broken = 0))
  }
  c(
    available = p_available / total,
    occupied = ((1 - p_broken) * p_occ) / total,
    broken = p_broken / total
  )
}

resolve_charger_state_probabilities <- function(charging_cfg, scenario = NULL, t = NULL, station_class = NULL, state_case = NULL) {
  root <- charging_cfg$stochastic_states %||% charging_cfg
  spec <- as.list(root$charger_state_probabilities$default %||% root$charger_state_probabilities %||% list())
  case_key <- as.character(state_case %||% resolve_charger_state_case(charging_cfg) %||% NA_character_)
  case_spec <- pick_named_override(root$charger_state_probabilities$by_case, case_key)
  if (!is.null(case_spec)) spec <- modifyList(spec, case_spec)
  scen_spec <- pick_named_override(root$charger_state_probabilities$by_scenario, scenario)
  if (!is.null(scen_spec)) spec <- modifyList(spec, scen_spec)
  tod_mod <- resolve_time_bucket_override(root$charger_state_probabilities$time_of_day_modifiers, t = t)
  if (!is.null(tod_mod)) spec <- apply_probability_modifier(spec, tod_mod)
  class_mod <- pick_named_override(root$charger_state_probabilities$station_class_modifiers, station_class)
  if (!is.null(class_mod)) spec <- apply_probability_modifier(spec, class_mod)
  normalize_charger_state_probabilities(spec)
}

resolve_wait_time_distribution <- function(charging_cfg, scenario = NULL, t = NULL, station_class = NULL, state_case = NULL) {
  root <- charging_cfg$stochastic_states %||% charging_cfg
  spec <- root$wait_time_distribution$default %||% root$wait_time_distribution %||% NULL
  case_key <- as.character(state_case %||% resolve_charger_state_case(charging_cfg) %||% NA_character_)
  case_spec <- pick_named_override(root$wait_time_distribution$by_case, case_key)
  if (!is.null(case_spec)) spec <- case_spec
  scen_spec <- pick_named_override(root$wait_time_distribution$by_scenario, scenario)
  if (!is.null(scen_spec)) spec <- scen_spec
  tod_spec <- resolve_time_bucket_override(root$wait_time_distribution$by_time_of_day, t = t)
  if (!is.null(tod_spec)) spec <- tod_spec
  class_spec <- pick_named_override(root$wait_time_distribution$by_station_class, station_class)
  if (!is.null(class_spec)) spec <- class_spec
  spec
}

sample_wait_time_minutes <- function(charging_cfg, scenario = NULL, t = NULL, station_class = NULL, state_case = NULL, rng = NULL) {
  spec <- resolve_wait_time_distribution(
    charging_cfg = charging_cfg,
    scenario = scenario,
    t = t,
    station_class = station_class,
    state_case = state_case
  )
  if (is.null(spec)) return(0)
  v <- suppressWarnings(as.numeric(sim_pick_distribution(spec, rng = rng)))
  if (!is.finite(v) || v < 0) return(0)
  v
}

draw_charger_state <- function(charging_cfg, scenario = NULL, t = NULL, station_class = NULL, state_case = NULL, rng = NULL) {
  probs <- resolve_charger_state_probabilities(
    charging_cfg = charging_cfg,
    scenario = scenario,
    t = t,
    station_class = station_class,
    state_case = state_case
  )
  u <- if (is.null(rng)) stats::runif(1) else rng$runif(1)
  if (!is.finite(u)) u <- 1
  if (u <= probs[["broken"]]) return(list(state = "broken", probabilities = probs))
  if (u <= (probs[["broken"]] + probs[["occupied"]])) return(list(state = "occupied", probabilities = probs))
  list(state = "available", probabilities = probs)
}

prepare_charge_candidates_for_route <- function(stations_df, route_segments, max_detour_miles = 10) {
  if (!is.data.frame(stations_df) || nrow(stations_df) == 0) return(data.frame())
  out <- stations_df
  if ("lon" %in% names(out) && !"lng" %in% names(out)) names(out)[names(out) == "lon"] <- "lng"
  req <- c("station_id", "lat", "lng")
  miss <- setdiff(req, names(out))
  if (length(miss) > 0) stop("Charge candidates missing columns: ", paste(miss, collapse = ", "))
  out$stop_cum_miles <- NA_real_
  out$seg_id <- NA_integer_
  out$detour_miles <- NA_real_
  for (i in seq_len(nrow(out))) {
    d <- haversine_m(out$lat[[i]], out$lng[[i]], route_segments$lat, route_segments$lng) / 1609.344
    j <- which.min(d)
    out$stop_cum_miles[[i]] <- as.numeric(route_segments$distance_miles_cum[[j]])
    out$seg_id[[i]] <- as.integer(route_segments$seg_id[[j]])
    out$detour_miles[[i]] <- as.numeric(d[[j]])
  }
  keep <- is.finite(out$detour_miles) & out$detour_miles <= as.numeric(max_detour_miles %||% 10)
  out <- out[keep, , drop = FALSE]
  out[order(out$stop_cum_miles, out$detour_miles), , drop = FALSE]
}

estimate_charge_detour_minutes <- function(charger_row) {
  dm <- coalesce_numeric_field(charger_row, c("detour_minutes"), default = NA_real_)
  if (is.finite(dm) && dm >= 0) return(dm)
  detour_miles <- coalesce_numeric_field(charger_row, c("detour_miles"), default = 0)
  if (!is.finite(detour_miles) || detour_miles < 0) detour_miles <- 0
  (detour_miles * 2 / 35) * 60
}

evaluate_charger_eligibility <- function(
    charger_row,
    charging_cfg,
    tractor_cfg = NULL,
    current_soc = NA_real_,
    battery_kwh = NA_real_,
    soc_min = NA_real_,
    current_distance_miles = NA_real_,
    speed_mph = NA_real_,
    predict_energy_fn = NULL) {
  truck_connectors <- truck_connector_set(charging_cfg, tractor_cfg = tractor_cfg)
  charger_connectors <- charger_connector_set(charger_row)
  power_kw <- coalesce_numeric_field(charger_row, c("max_charge_rate_kw", "power_kw"), default = NA_real_)
  min_kw <- charger_power_min_kw(charging_cfg)
  if (!is.finite(min_kw)) min_kw <- 0
  truck_capable_required <- isTRUE(charging_cfg$require_truck_capable %||% FALSE)
  truck_capable_fields <- c("truck_capable", "is_truck_capable", "truck_friendly")
  truck_capable_flag <- coalesce_logical_field(charger_row, truck_capable_fields, default = NA)
  truck_capable_present <- any(truck_capable_fields %in% names(charger_row)) && !is.na(truck_capable_flag)
  station_class <- resolve_station_class(charger_row)
  reasons <- character()

  connector_ok <- length(truck_connectors) == 0 || length(intersect(truck_connectors, charger_connectors)) > 0
  if (!connector_ok) reasons <- c(reasons, "connector_incompatible")

  power_ok <- is.finite(power_kw) && power_kw >= min_kw
  if (!power_ok) reasons <- c(reasons, "below_min_power")

  truck_capable_ok <- if (truck_capable_required) {
    isTRUE(truck_capable_flag)
  } else {
    !truck_capable_present || isTRUE(truck_capable_flag)
  }
  if (!truck_capable_ok) reasons <- c(reasons, "not_truck_capable")

  range_ok <- TRUE
  target_distance_miles <- coalesce_numeric_field(charger_row, c("stop_cum_miles", "along_route_miles"), default = NA_real_)
  if (is.function(predict_energy_fn) &&
      is.finite(current_soc) &&
      is.finite(battery_kwh) &&
      is.finite(soc_min) &&
      is.finite(current_distance_miles) &&
      is.finite(target_distance_miles) &&
      target_distance_miles > current_distance_miles) {
    need_kwh <- suppressWarnings(as.numeric(predict_energy_fn(current_distance_miles, target_distance_miles, speed_mph)))
    avail_kwh <- max(0, (current_soc - soc_min) * battery_kwh)
    range_ok <- is.finite(need_kwh) && need_kwh <= (avail_kwh + 1e-9)
  }
  if (!isTRUE(range_ok)) reasons <- c(reasons, "range_infeasible")

  list(
    eligible = length(reasons) == 0,
    compatible = length(reasons) == 0,
    reason = if (length(reasons) == 0) "eligible" else paste(reasons, collapse = ";"),
    station_class = station_class,
    charger_id = coalesce_character_field(charger_row, c("charger_id", "station_id"), default = NA_character_),
    station_id = coalesce_character_field(charger_row, c("station_id", "charger_id"), default = NA_character_),
    power_kw = power_kw,
    connector_ok = connector_ok,
    power_ok = power_ok,
    truck_capable_ok = truck_capable_ok,
    range_ok = isTRUE(range_ok),
    compatible_connectors = if (length(charger_connectors) > 0) paste(charger_connectors, collapse = "|") else NA_character_
  )
}

build_charge_attempt_row <- function(
    charger_row,
    eligibility,
    phase = "planned",
    attempt_index = 1L,
    stop_index = NA_integer_,
    state_drawn = NA_character_,
    wait_time_minutes = 0,
    compatible_candidates_considered = 0L,
    fallback_used = FALSE,
    decision_status = "pending",
    pre_charge_soc = NA_real_) {
  data.frame(
    phase = as.character(phase),
    attempt_index = as.integer(attempt_index),
    stop_index = as.integer(stop_index),
    charger_id = as.character(eligibility$charger_id %||% coalesce_character_field(charger_row, c("charger_id", "station_id"), default = NA_character_)),
    station_id = as.character(eligibility$station_id %||% coalesce_character_field(charger_row, c("station_id", "charger_id"), default = NA_character_)),
    station_class = as.character(eligibility$station_class %||% resolve_station_class(charger_row)),
    compatible = as.logical(eligibility$compatible %||% FALSE),
    incompatibility_reason = if (isTRUE(eligibility$compatible %||% FALSE)) NA_character_ else as.character(eligibility$reason %||% NA_character_),
    state_drawn = as.character(state_drawn %||% NA_character_),
    wait_time_minutes = as.numeric(wait_time_minutes %||% 0),
    charge_duration_minutes = NA_real_,
    pre_charge_soc = as.numeric(pre_charge_soc),
    post_charge_soc = NA_real_,
    hos_impact_minutes = NA_real_,
    reefer_runtime_increment_minutes = NA_real_,
    compatible_candidates_considered = as.integer(compatible_candidates_considered %||% 0L),
    failed_attempt = as.integer(!isTRUE(decision_status %in% c("selected", "selected_occupied", "selected_available", "emergency_virtual"))),
    fallback_used = as.logical(fallback_used),
    detour_minutes = as.numeric(estimate_charge_detour_minutes(charger_row)),
    decision_status = as.character(decision_status),
    stringsAsFactors = FALSE
  )
}

resolve_stochastic_charge_decision <- function(
    anchor_row,
    charging_candidates,
    charging_cfg,
    tractor_cfg = NULL,
    scenario = NULL,
    current_time = NULL,
    current_distance_miles = NA_real_,
    current_soc = NA_real_,
    battery_kwh = NA_real_,
    soc_min = NA_real_,
    speed_mph = NA_real_,
    predict_energy_fn = NULL,
    phase = "planned",
    stop_index = NA_integer_,
    seed = 1L) {
  if (!is.data.frame(anchor_row) || nrow(anchor_row) == 0) return(list(success = FALSE, attempts = data.frame(), compatible_candidates_considered = 0L))
  search_window_miles <- suppressWarnings(as.numeric(charging_cfg$fallback_search_window_miles %||% 5))
  if (!is.finite(search_window_miles) || search_window_miles < 0) search_window_miles <- 5
  anchor_miles <- coalesce_numeric_field(anchor_row, c("stop_cum_miles", "along_route_miles"), default = current_distance_miles)

  pool <- anchor_row
  if (is.data.frame(charging_candidates) && nrow(charging_candidates) > 0) {
    cand <- charging_candidates
    cand_miles <- suppressWarnings(as.numeric(cand$stop_cum_miles %||% cand$along_route_miles))
    keep <- is.finite(cand_miles) & is.finite(anchor_miles) & abs(cand_miles - anchor_miles) <= search_window_miles
    cand <- cand[keep, , drop = FALSE]
    if (nrow(cand) > 0) pool <- if (requireNamespace("data.table", quietly = TRUE)) {
      as.data.frame(data.table::rbindlist(list(anchor_row, cand), fill = TRUE, use.names = TRUE))
    } else {
      unique(rbind(anchor_row, cand))
    }
  }

  pool$charger_id_norm <- vapply(seq_len(nrow(pool)), function(i) {
    normalize_config_key(coalesce_character_field(pool[i, , drop = FALSE], c("charger_id", "station_id"), default = paste0("charger_", i)))
  }, character(1))
  pool <- pool[!duplicated(pool$charger_id_norm), , drop = FALSE]
  pool$anchor_priority <- seq_len(nrow(pool))

  eval_count <- nrow(pool)
  evals <- vector("list", eval_count)
  for (i in seq_len(eval_count)) {
    row <- pool[i, , drop = FALSE]
    el <- evaluate_charger_eligibility(
      charger_row = row,
      charging_cfg = charging_cfg,
      tractor_cfg = tractor_cfg,
      current_soc = current_soc,
      battery_kwh = battery_kwh,
      soc_min = soc_min,
      current_distance_miles = current_distance_miles,
      speed_mph = speed_mph,
      predict_energy_fn = predict_energy_fn
    )
    evals[[i]] <- list(row = row, eligibility = el)
  }

  compatible_candidates <- sum(vapply(evals, function(x) isTRUE(x$eligibility$eligible), logical(1)))
  attempts <- vector("list", eval_count)
  ai <- 0L
  eligible_rows <- vector("list", eval_count)
  eligible_n <- 0L
  for (i in seq_along(evals)) {
    one <- evals[[i]]
    if (!isTRUE(one$eligibility$eligible)) {
      ai <- ai + 1L
      attempts[[ai]] <- build_charge_attempt_row(
        charger_row = one$row,
        eligibility = one$eligibility,
        phase = phase,
        attempt_index = ai,
        stop_index = stop_index,
        compatible_candidates_considered = compatible_candidates,
        decision_status = "incompatible",
        pre_charge_soc = current_soc
      )
    } else {
      eligible_n <- eligible_n + 1L
      eligible_rows[[eligible_n]] <- one
    }
  }
  if (eligible_n > 0L) eligible_rows <- eligible_rows[seq_len(eligible_n)] else eligible_rows <- list()

  if (length(eligible_rows) == 0L) {
    return(list(
      success = FALSE,
      attempts = if (ai > 0L) do.call(rbind, attempts[seq_len(ai)]) else data.frame(),
      compatible_candidates_considered = compatible_candidates,
      failure_reason = "no_compatible_candidate"
    ))
  }

  ord <- order(
    vapply(eligible_rows, function(x) x$row$anchor_priority[[1]], numeric(1)),
    vapply(eligible_rows, function(x) estimate_charge_detour_minutes(x$row), numeric(1)),
    -vapply(eligible_rows, function(x) x$eligibility$power_kw %||% 0, numeric(1))
  )
  eligible_rows <- eligible_rows[ord]

  for (i in seq_along(eligible_rows)) {
    one <- eligible_rows[[i]]
    event_rng <- new_local_rng(as.integer(seed) + i * 97L + as.integer(stop_index %||% 0L) * 997L)
    state <- draw_charger_state(
      charging_cfg = charging_cfg,
      scenario = scenario,
      t = current_time,
      station_class = one$eligibility$station_class,
      state_case = resolve_charger_state_case(charging_cfg),
      rng = event_rng
    )
    wait_time <- if (identical(state$state, "occupied")) {
      sample_wait_time_minutes(
        charging_cfg = charging_cfg,
        scenario = scenario,
        t = current_time,
        station_class = one$eligibility$station_class,
        state_case = resolve_charger_state_case(charging_cfg),
        rng = event_rng
      )
    } else {
      0
    }
    ai <- ai + 1L
    fallback_used <- i > 1L || normalize_config_key(one$eligibility$charger_id) != normalize_config_key(coalesce_character_field(anchor_row, c("charger_id", "station_id"), default = NA_character_))
    status <- if (identical(state$state, "broken")) "broken" else if (identical(state$state, "occupied")) "selected_occupied" else "selected_available"
    attempts[[ai]] <- build_charge_attempt_row(
      charger_row = one$row,
      eligibility = one$eligibility,
      phase = phase,
      attempt_index = ai,
      stop_index = stop_index,
      state_drawn = state$state,
      wait_time_minutes = wait_time,
      compatible_candidates_considered = compatible_candidates,
      fallback_used = fallback_used,
      decision_status = status,
      pre_charge_soc = current_soc
    )
    if (!identical(state$state, "broken")) {
      return(list(
        success = TRUE,
        chosen_row = one$row,
        chosen_eligibility = one$eligibility,
        chosen_state = state$state,
        wait_time_minutes = wait_time,
        attempts = do.call(rbind, attempts[seq_len(ai)]),
        compatible_candidates_considered = compatible_candidates
      ))
    }
  }

  list(
    success = FALSE,
    attempts = if (ai > 0L) do.call(rbind, attempts[seq_len(ai)]) else data.frame(),
    compatible_candidates_considered = compatible_candidates,
    failure_reason = "all_candidates_broken"
  )
}

finalize_charge_attempts <- function(
    attempts_df,
    charge_duration_minutes = NA_real_,
    post_charge_soc = NA_real_,
    hos_impact_minutes = NA_real_,
    reefer_runtime_increment_minutes = NA_real_) {
  if (!is.data.frame(attempts_df) || nrow(attempts_df) == 0) return(attempts_df)
  idx <- which(as.character(attempts_df$decision_status) %in% c("selected_occupied", "selected_available", "emergency_virtual"))
  if (length(idx) == 0) return(attempts_df)
  j <- idx[[length(idx)]]
  attempts_df$charge_duration_minutes[[j]] <- as.numeric(charge_duration_minutes %||% NA_real_)
  attempts_df$post_charge_soc[[j]] <- as.numeric(post_charge_soc %||% NA_real_)
  attempts_df$hos_impact_minutes[[j]] <- as.numeric(hos_impact_minutes %||% NA_real_)
  attempts_df$reefer_runtime_increment_minutes[[j]] <- as.numeric(reefer_runtime_increment_minutes %||% NA_real_)
  attempts_df
}

summarize_charge_attempts <- function(attempts_df) {
  if (!is.data.frame(attempts_df) || nrow(attempts_df) == 0) {
    return(list(
      charging_attempts = 0L,
      compatible_chargers_considered = 0L,
      occupied_events = 0L,
      broken_events = 0L,
      average_wait_time_minutes = 0,
      max_wait_time_minutes = 0,
      total_wait_time_minutes = 0,
      added_refrigeration_runtime_minutes_waiting = 0,
      added_hos_delay_minutes_waiting = 0,
      failed_charging_attempt_fraction = 0
    ))
  }
  wait_times <- suppressWarnings(as.numeric(attempts_df$wait_time_minutes))
  wait_times[!is.finite(wait_times)] <- 0
  compatible_counts <- suppressWarnings(as.numeric(attempts_df$compatible_candidates_considered))
  compatible_counts[!is.finite(compatible_counts)] <- 0
  failed <- suppressWarnings(as.numeric(attempts_df$failed_attempt))
  failed[!is.finite(failed)] <- 0
  states <- tolower(as.character(attempts_df$state_drawn %||% NA_character_))
  compatible_total <- if (all(c("phase", "stop_index") %in% names(attempts_df))) {
    key <- paste0(as.character(attempts_df$phase), "::", as.character(attempts_df$stop_index))
    by_event <- split(compatible_counts, key)
    sum(vapply(by_event, function(x) max(as.numeric(x), na.rm = TRUE), numeric(1)), na.rm = TRUE)
  } else {
    sum(compatible_counts, na.rm = TRUE)
  }
  list(
    charging_attempts = as.integer(nrow(attempts_df)),
    compatible_chargers_considered = as.integer(compatible_total),
    occupied_events = as.integer(sum(states == "occupied", na.rm = TRUE)),
    broken_events = as.integer(sum(states == "broken", na.rm = TRUE)),
    average_wait_time_minutes = if (length(wait_times) > 0) mean(wait_times, na.rm = TRUE) else 0,
    max_wait_time_minutes = if (length(wait_times) > 0) max(wait_times, na.rm = TRUE) else 0,
    total_wait_time_minutes = sum(wait_times, na.rm = TRUE),
    added_refrigeration_runtime_minutes_waiting = sum(wait_times, na.rm = TRUE),
    added_hos_delay_minutes_waiting = sum(wait_times, na.rm = TRUE),
    failed_charging_attempt_fraction = if (nrow(attempts_df) > 0) mean(failed > 0, na.rm = TRUE) else 0
  )
}
