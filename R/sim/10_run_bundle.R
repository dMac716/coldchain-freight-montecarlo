# Run bundle creation for collaboration publishing.

safe_git <- function(args) {
  out <- tryCatch(system2("git", args = args, stdout = TRUE, stderr = FALSE), error = function(e) "")
  if (length(out) == 0) return("")
  as.character(out[[1]])
}

git_metadata <- function() {
  sha <- safe_git(c("rev-parse", "HEAD"))
  branch <- safe_git(c("rev-parse", "--abbrev-ref", "HEAD"))
  dirty <- NA
  st <- tryCatch(system2("git", args = c("status", "--porcelain"), stdout = TRUE, stderr = FALSE), error = function(e) character())
  if (length(st) >= 0) dirty <- length(st) > 0
  list(git_sha = sha, git_branch = branch, repo_dirty = isTRUE(dirty))
}

run_status_from_sim <- function(sim) {
  if (!is.null(sim$metadata) && isTRUE(sim$metadata$plan_soc_violation)) return("plan_soc_violation")
  if (!is.null(sim$event_log) && nrow(sim$event_log) > 0 && any(sim$event_log$event_type == "ROUTE_COMPLETE")) return("ok")
  "ok"
}

run_summary_row <- function(sim, context) {
  ss <- sim$sim_state
  if (is.null(ss) || nrow(ss) == 0) return(data.frame())
  last <- ss[nrow(ss), , drop = FALSE]
  data.frame(
    run_id = as.character(context$run_id),
    scenario = as.character(context$scenario %||% NA_character_),
    route_id = as.character(context$route_id %||% NA_character_),
    route_plan_id = as.character(context$route_plan_id %||% NA_character_),
    leg = as.character(context$trip_leg %||% NA_character_),
    distance_miles = as.numeric(last$distance_miles_cum[[1]]),
    duration_minutes = as.numeric(as.numeric(difftime(as.POSIXct(last$t[[1]], tz = "UTC"), as.POSIXct(ss$t[[1]], tz = "UTC"), units = "mins"))),
    co2_kg_total = as.numeric(last$co2_kg_cum[[1]]),
    co2_kg_propulsion = NA_real_,
    co2_kg_tru = NA_real_,
    energy_kwh_propulsion = as.numeric(last$propulsion_kwh_cum[[1]]),
    energy_kwh_tru = as.numeric(last$tru_kwh_cum[[1]]),
    diesel_gal_propulsion = as.numeric(last$diesel_gal_cum[[1]]),
    diesel_gal_tru = as.numeric(last$tru_gal_cum[[1]]),
    charge_stops = as.integer(last$charge_count[[1]]),
    refuel_stops = as.integer(last$refuel_count[[1]]),
    delay_minutes = as.numeric(last$delay_minutes_cum[[1]]),
    fuel_type_outbound = if (isTRUE(identical(context$trip_leg, "outbound"))) as.character(last$fuel_type_label[[1]]) else NA_character_,
    fuel_type_return = if (isTRUE(identical(context$trip_leg, "return"))) as.character(last$fuel_type_label[[1]]) else NA_character_,
    stringsAsFactors = FALSE
  )
}

artifact_manifest <- function(paths_named) {
  nm <- names(paths_named)
  if (length(nm) == 0) return(data.frame())
  rows <- lapply(seq_along(paths_named), function(i) {
    p <- as.character(paths_named[[i]])
    exists <- file.exists(p)
    list(
      key = as.character(nm[[i]]),
      path = p,
      exists = isTRUE(exists),
      sha256 = if (isTRUE(exists)) sha256_file(p) else NA_character_,
      row_count = if (isTRUE(exists)) nrow(utils::read.csv(p, stringsAsFactors = FALSE)) else NA_integer_
    )
  })
  do.call(rbind.data.frame, c(rows, stringsAsFactors = FALSE))
}

inputs_hash_from_artifacts <- function(artifacts_df) {
  if (is.null(artifacts_df) || nrow(artifacts_df) == 0) return(NA_character_)
  key <- paste(
    artifacts_df$key,
    artifacts_df$sha256,
    artifacts_df$row_count,
    sep = "=",
    collapse = "|"
  )
  sha256_text(key)
}

write_run_bundle <- function(
    sim,
    context,
    cfg_resolved = list(),
    artifact_paths = NULL,
    tracks_path = NULL,
    bundle_root = "outputs/run_bundle") {
  if (is.null(context$run_id) || !nzchar(context$run_id)) stop("context$run_id is required")
  run_id <- as.character(context$run_id)
  bundle_dir <- file.path(bundle_root, run_id)
  dir.create(bundle_dir, recursive = TRUE, showWarnings = FALSE)

  if (is.null(artifact_paths)) {
    artifact_paths <- c(
      routes_geometry = "data/derived/routes_facility_to_petco.csv",
      bev_route_plans = "data/derived/bev_route_plans.csv",
      ev_stations = "data/derived/ev_charging_stations_corridor.csv",
      od_cache = "data/derived/google_routes_od_cache.csv"
    )
  }

  g <- git_metadata()
  artifacts_df <- artifact_manifest(artifact_paths)
  inputs_hash <- inputs_hash_from_artifacts(artifacts_df)
  status <- run_status_from_sim(sim)
  summary_row <- run_summary_row(sim, context)

  runs_obj <- list(
    run_id = run_id,
    created_at_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
    runner = Sys.getenv("USER", unset = ""),
    git_sha = g$git_sha,
    git_branch = g$git_branch,
    repo_dirty = g$repo_dirty,
    status = status,
    scenario = context$scenario %||% NA_character_,
    route_id = context$route_id %||% NA_character_,
    route_plan_id = context$route_plan_id %||% NA_character_,
    seed = as.integer(context$seed %||% NA_integer_),
    mc_draws = as.integer(context$mc_draws %||% 1L),
    gcs_prefix = NA_character_,
    inputs_hash = inputs_hash
  )

  params_obj <- list(
    run_id = run_id,
    scenario = context$scenario %||% NA_character_,
    facility_id = context$facility_id %||% NA_character_,
    powertrain = context$powertrain %||% NA_character_,
    trip_leg = context$trip_leg %||% NA_character_,
    seed = as.integer(context$seed %||% NA_integer_),
    mc_draws = as.integer(context$mc_draws %||% 1L),
    route_id = context$route_id %||% NA_character_,
    route_plan_id = context$route_plan_id %||% NA_character_,
    config = cfg_resolved
  )

  runs_path <- file.path(bundle_dir, "runs.json")
  summaries_path <- file.path(bundle_dir, "summaries.csv")
  events_path <- file.path(bundle_dir, "events.csv")
  params_path <- file.path(bundle_dir, "params.json")
  artifacts_path <- file.path(bundle_dir, "artifacts.json")
  tracks_gz_path <- file.path(bundle_dir, "tracks.csv.gz")

  jsonlite::write_json(runs_obj, runs_path, pretty = TRUE, auto_unbox = TRUE, null = "null")
  utils::write.csv(summary_row, summaries_path, row.names = FALSE)
  utils::write.csv(sim$event_log, events_path, row.names = FALSE)
  jsonlite::write_json(params_obj, params_path, pretty = TRUE, auto_unbox = TRUE, null = "null")
  jsonlite::write_json(artifacts_df, artifacts_path, pretty = TRUE, auto_unbox = TRUE, dataframe = "rows", null = "null")

  if (!is.null(tracks_path) && file.exists(tracks_path)) {
    con_in <- file(tracks_path, open = "rb")
    con_out <- gzfile(tracks_gz_path, open = "wb")
    on.exit(try(close(con_in), silent = TRUE), add = TRUE)
    on.exit(try(close(con_out), silent = TRUE), add = TRUE)
    repeat {
      buf <- readBin(con_in, what = raw(), n = 1024 * 1024)
      if (length(buf) == 0) break
      writeBin(buf, con_out)
    }
  }

  list(
    bundle_dir = bundle_dir,
    runs_path = runs_path,
    summaries_path = summaries_path,
    events_path = events_path,
    params_path = params_path,
    artifacts_path = artifacts_path,
    tracks_gz_path = if (file.exists(tracks_gz_path)) tracks_gz_path else NA_character_
  )
}
