# Output writers and Monte Carlo summaries.

write_route_sim_outputs <- function(sim, run_id, tracks_dir = "outputs/sim_tracks", events_dir = "outputs/sim_events") {
  dir.create(tracks_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(events_dir, recursive = TRUE, showWarnings = FALSE)
  track_path <- file.path(tracks_dir, paste0(run_id, ".csv"))
  event_path <- file.path(events_dir, paste0(run_id, ".csv"))
  utils::write.csv(sim$sim_state, track_path, row.names = FALSE)
  utils::write.csv(sim$event_log, event_path, row.names = FALSE)
  list(track_path = track_path, event_path = event_path)
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
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, out)
}
