# Output writers and Monte Carlo summaries.

write_route_sim_outputs <- function(
    sim,
    run_id,
    tracks_dir = "outputs/sim_tracks",
    events_dir = "outputs/sim_events",
    charge_details_dir = "outputs/sim_charge_details",
    write_tracks = TRUE,
    write_events = TRUE,
    write_charge_details = TRUE) {
  dir.create(tracks_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(events_dir, recursive = TRUE, showWarnings = FALSE)
  track_path <- file.path(tracks_dir, paste0(run_id, ".csv"))
  event_path <- file.path(events_dir, paste0(run_id, ".csv"))
  charge_details_path <- file.path(charge_details_dir, paste0(run_id, ".csv"))
  if (isTRUE(write_tracks)) {
    if (requireNamespace("data.table", quietly = TRUE)) {
      data.table::fwrite(sim$sim_state, track_path)
    } else {
      utils::write.csv(sim$sim_state, track_path, row.names = FALSE)
    }
  }
  if (isTRUE(write_events)) {
    if (requireNamespace("data.table", quietly = TRUE)) {
      data.table::fwrite(sim$event_log, event_path)
    } else {
      utils::write.csv(sim$event_log, event_path, row.names = FALSE)
    }
  }
  if (isTRUE(write_charge_details) && is.data.frame(sim$charge_stop_details) && nrow(sim$charge_stop_details) > 0) {
    dir.create(charge_details_dir, recursive = TRUE, showWarnings = FALSE)
    if (requireNamespace("data.table", quietly = TRUE)) {
      data.table::fwrite(sim$charge_stop_details, charge_details_path)
    } else {
      utils::write.csv(sim$charge_stop_details, charge_details_path, row.names = FALSE)
    }
  }
  gc(verbose = FALSE)
  list(
    track_path = track_path,
    event_path = event_path,
    charge_details_path = if (file.exists(charge_details_path)) charge_details_path else NA_character_
  )
}

summarize_route_sim_runs <- function(runs_df) {
  if (nrow(runs_df) == 0) return(data.frame())
  traffic_mode <- if ("traffic_mode" %in% names(runs_df)) as.character(runs_df$traffic_mode) else NA_character_
  by <- split(runs_df, list(runs_df$scenario, runs_df$powertrain, traffic_mode), drop = TRUE)
  out <- lapply(by, function(d) {
    x <- d$co2_kg_total
    n_fail <- if ("status" %in% names(d)) sum(d$status != "OK", na.rm = TRUE) else 0L
    data.frame(
      scenario = d$scenario[[1]],
      powertrain = d$powertrain[[1]],
      traffic_mode = if ("traffic_mode" %in% names(d)) as.character(d$traffic_mode[[1]]) else NA_character_,
      mean = mean(x, na.rm = TRUE),
      p05 = as.numeric(stats::quantile(x, 0.05, na.rm = TRUE, names = FALSE)),
      p50 = as.numeric(stats::quantile(x, 0.50, na.rm = TRUE, names = FALSE)),
      p95 = as.numeric(stats::quantile(x, 0.95, na.rm = TRUE, names = FALSE)),
      n_runs = nrow(d),
      n_failed = n_fail,
      mean_charging_attempts = if ("charging_attempts" %in% names(d)) mean(as.numeric(d$charging_attempts), na.rm = TRUE) else NA_real_,
      mean_compatible_chargers_considered = if ("compatible_chargers_considered" %in% names(d)) mean(as.numeric(d$compatible_chargers_considered), na.rm = TRUE) else NA_real_,
      total_occupied_events = if ("occupied_events" %in% names(d)) sum(as.numeric(d$occupied_events), na.rm = TRUE) else NA_real_,
      total_broken_events = if ("broken_events" %in% names(d)) sum(as.numeric(d$broken_events), na.rm = TRUE) else NA_real_,
      average_wait_time_minutes = if ("average_wait_time_minutes" %in% names(d)) mean(as.numeric(d$average_wait_time_minutes), na.rm = TRUE) else NA_real_,
      max_wait_time_minutes = if ("max_wait_time_minutes" %in% names(d)) max(as.numeric(d$max_wait_time_minutes), na.rm = TRUE) else NA_real_,
      total_wait_time_minutes = if ("total_wait_time_minutes" %in% names(d)) sum(as.numeric(d$total_wait_time_minutes), na.rm = TRUE) else NA_real_,
      total_added_refrigeration_runtime_minutes_waiting = if ("added_refrigeration_runtime_minutes_waiting" %in% names(d)) sum(as.numeric(d$added_refrigeration_runtime_minutes_waiting), na.rm = TRUE) else NA_real_,
      total_added_hos_delay_minutes_waiting = if ("added_hos_delay_minutes_waiting" %in% names(d)) sum(as.numeric(d$added_hos_delay_minutes_waiting), na.rm = TRUE) else NA_real_,
      mean_failed_charging_attempt_fraction = if ("failed_charging_attempt_fraction" %in% names(d)) mean(as.numeric(d$failed_charging_attempt_fraction), na.rm = TRUE) else NA_real_,
      stringsAsFactors = FALSE
    )
  })
  if (requireNamespace("data.table", quietly = TRUE)) {
    as.data.frame(data.table::rbindlist(out, use.names = TRUE, fill = TRUE))
  } else {
    do.call(rbind, out)
  }
}
