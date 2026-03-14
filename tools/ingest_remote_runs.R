#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(data.table)
})

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

parse_bool <- function(x, default = FALSE) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Boolean value expected, got: ", as.character(x))
}

duckdb_csv_query <- function(db, sql) {
  out <- tryCatch(system2("duckdb", args = c(db, "-csv"), input = sql, stdout = TRUE, stderr = TRUE), error = function(e) character())
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) return(data.table())
  if (length(out) == 0) return(data.table())
  fread(text = paste(out, collapse = "\n"), showProgress = FALSE)
}

ensure_cols <- function(dt, cols) {
  for (nm in cols) {
    if (!nm %in% names(dt)) dt[, (nm) := NA]
  }
  dt
}

load_csv_if_exists <- function(path) {
  if (!file.exists(path)) return(data.table())
  fread(path, showProgress = FALSE)
}

write_table_sql <- function(table_name, csv_path) {
  sprintf(paste(
    "CREATE TABLE IF NOT EXISTS %s AS SELECT * FROM read_csv_auto('%s', HEADER=TRUE);",
    "DELETE FROM %s WHERE run_id IN (SELECT run_id FROM read_csv_auto('%s', HEADER=TRUE));",
    "INSERT INTO %s SELECT * FROM read_csv_auto('%s', HEADER=TRUE);",
    sep = "\n"
  ), table_name, csv_path, table_name, csv_path, table_name, csv_path)
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--cache_root"), type = "character", default = "outputs/remote_cache/transport_runs"),
  make_option(c("--db"), type = "character", default = "analysis/transport_catalog.duckdb"),
  make_option(c("--force"), type = "character", default = "false")
)))

force_reingest <- parse_bool(opt$force, FALSE)
dir.create(dirname(opt$db), recursive = TRUE, showWarnings = FALSE)

manifest_paths <- list.files(opt$cache_root, pattern = "^manifest\\.json$", recursive = TRUE, full.names = TRUE)
manifest_paths <- manifest_paths[!grepl("/(controlled_crossed|realistic_lca|validation)/manifest\\.json$", manifest_paths)]
run_dirs <- unique(dirname(manifest_paths))
if (length(run_dirs) == 0) stop("No run manifests found under ", opt$cache_root)

existing_run_ids <- character()
if (file.exists(opt$db)) {
  tabs <- duckdb_csv_query(opt$db, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'")
  if (nrow(tabs) > 0 && "runs" %in% tabs$table_name) {
    existing <- duckdb_csv_query(opt$db, "SELECT DISTINCT run_id FROM runs")
    if (nrow(existing) > 0) existing_run_ids <- as.character(existing$run_id)
  }
}

manifests_root <- vector("list", length(run_dirs))
manifests_layer <- list()
selected_run_dirs <- character()

for (i in seq_along(run_dirs)) {
  run_dir <- run_dirs[[i]]
  root_manifest <- fromJSON(file.path(run_dir, "manifest.json"), simplifyVector = TRUE)
  run_id <- as.character(root_manifest$run_id %||% basename(run_dir))
  if (!force_reingest && run_id %in% existing_run_ids) next
  selected_run_dirs <- c(selected_run_dirs, run_dir)
  manifests_root[[length(selected_run_dirs)]] <- data.table(
    run_id = run_id,
    commit_sha = as.character(root_manifest$commit_sha %||% NA_character_),
    branch = as.character(root_manifest$branch %||% NA_character_),
    timestamp_utc = as.character(root_manifest$timestamp_utc %||% NA_character_),
    launcher_version = as.character(root_manifest$launcher_version %||% NA_character_),
    scenario_design_version = as.character(root_manifest$scenario_design_version %||% NA_character_),
    output_root = as.character(root_manifest$output_root %||% NA_character_),
    contributor_id = as.character(root_manifest$contributor_id %||% NA_character_),
    seed_base = suppressWarnings(as.integer(root_manifest$seed_base %||% NA_integer_)),
    n_reps = suppressWarnings(as.integer(root_manifest$n_reps %||% NA_integer_)),
    chunk_count = suppressWarnings(as.integer(root_manifest$chunk_count %||% NA_integer_)),
    worker_count = suppressWarnings(as.integer(root_manifest$worker_count %||% NA_integer_)),
    validation_passed = as.logical(root_manifest$validation_passed %||% FALSE),
    notes = as.character(root_manifest$notes %||% NA_character_),
    remote_results_root = as.character(root_manifest$remote_results_root %||% NA_character_)
  )
  for (layer_type in c("controlled_crossed", "realistic_lca")) {
    manifests_layer[[length(manifests_layer) + 1L]] <- data.table(
      run_id = run_id,
      layer_type = layer_type,
      commit_sha = as.character(root_manifest$commit_sha %||% NA_character_),
      branch = as.character(root_manifest$branch %||% NA_character_),
      timestamp_utc = as.character(root_manifest$timestamp_utc %||% NA_character_),
      launcher_version = as.character(root_manifest$launcher_version %||% NA_character_),
      scenario_design_version = as.character(root_manifest$scenario_design_version %||% NA_character_),
      contributor_id = as.character(root_manifest$contributor_id %||% NA_character_),
      validation_passed = as.logical(root_manifest$validation_passed %||% FALSE),
      manifest_path = normalizePath(file.path(run_dir, "manifest.json"), winslash = "/", mustWork = FALSE)
    )
  }
}

if (length(selected_run_dirs) == 0) {
  cat("No new run_ids to ingest.\n")
  quit(save = "no", status = 0)
}

runs_df <- rbindlist(Filter(Negate(is.null), manifests_root), fill = TRUE, use.names = TRUE)
layer_df <- rbindlist(manifests_layer, fill = TRUE, use.names = TRUE)

crossed_list <- list()
crossed_summary_list <- list()
realistic_list <- list()
realistic_powertrain_list <- list()
decomposition_list <- list()

for (run_dir in selected_run_dirs) {
  manifest_run_id <- basename(run_dir)
  crossed_path <- if (file.exists(file.path(run_dir, "raw", "crossed_factory_transport_scenarios.csv"))) {
    file.path(run_dir, "raw", "crossed_factory_transport_scenarios.csv")
  } else {
    file.path(run_dir, "controlled_crossed", "raw", "crossed_factory_transport_scenarios.csv")
  }
  crossed_summary_path <- if (file.exists(file.path(run_dir, "summaries", "crossed_factory_transport_summary.csv"))) {
    file.path(run_dir, "summaries", "crossed_factory_transport_summary.csv")
  } else {
    file.path(run_dir, "controlled_crossed", "summaries", "crossed_factory_transport_summary.csv")
  }
  decomp_path <- if (file.exists(file.path(run_dir, "summaries", "transport_effect_decomposition.csv"))) {
    file.path(run_dir, "summaries", "transport_effect_decomposition.csv")
  } else {
    file.path(run_dir, "controlled_crossed", "summaries", "transport_effect_decomposition.csv")
  }
  realistic_path <- if (file.exists(file.path(run_dir, "raw", "transport_sim_rows.csv"))) {
    file.path(run_dir, "raw", "transport_sim_rows.csv")
  } else {
    file.path(run_dir, "realistic_lca", "raw", "transport_sim_rows.csv")
  }
  realistic_powertrain_path <- if (file.exists(file.path(run_dir, "summaries", "transport_sim_powertrain_summary.csv"))) {
    file.path(run_dir, "summaries", "transport_sim_powertrain_summary.csv")
  } else {
    file.path(run_dir, "realistic_lca", "summaries", "transport_sim_powertrain_summary.csv")
  }

  crossed <- load_csv_if_exists(crossed_path)
  if (nrow(crossed) > 0) {
    crossed[, run_id := as.character(manifest_run_id)]
    crossed[, layer_type := "controlled_crossed"]
    crossed_list[[length(crossed_list) + 1L]] <- crossed
  }

  crossed_summary <- load_csv_if_exists(crossed_summary_path)
  if (nrow(crossed_summary) > 0) {
    crossed_summary[, run_id := as.character(manifest_run_id)]
    crossed_summary[, layer_type := "controlled_crossed"]
    crossed_summary_list[[length(crossed_summary_list) + 1L]] <- crossed_summary
  }

  realistic <- load_csv_if_exists(realistic_path)
  if (nrow(realistic) > 0) {
    realistic[, run_id := as.character(manifest_run_id)]
    realistic[, layer_type := "realistic_lca"]
    realistic_list[[length(realistic_list) + 1L]] <- realistic
  }

  realistic_powertrain <- load_csv_if_exists(realistic_powertrain_path)
  if (nrow(realistic_powertrain) > 0) {
    realistic_powertrain[, run_id := as.character(manifest_run_id)]
    realistic_powertrain[, layer_type := "realistic_lca"]
    realistic_powertrain_list[[length(realistic_powertrain_list) + 1L]] <- realistic_powertrain
  }

  decomp <- load_csv_if_exists(decomp_path)
  if (nrow(decomp) > 0) {
    decomp[, run_id := as.character(manifest_run_id)]
    decomp[, layer_type := "controlled_crossed"]
    decomposition_list[[length(decomposition_list) + 1L]] <- decomp
  }
}

crossed_df <- rbindlist(crossed_list, fill = TRUE, use.names = TRUE)
crossed_summary_df <- rbindlist(crossed_summary_list, fill = TRUE, use.names = TRUE)
realistic_df <- rbindlist(realistic_list, fill = TRUE, use.names = TRUE)
realistic_powertrain_df <- rbindlist(realistic_powertrain_list, fill = TRUE, use.names = TRUE)
decomposition_df <- rbindlist(decomposition_list, fill = TRUE, use.names = TRUE)

scenario_rows <- rbindlist(list(crossed_df, realistic_df), fill = TRUE, use.names = TRUE)
scenario_rows <- ensure_cols(scenario_rows, c(
  "run_id", "layer_type", "factory", "powertrain", "reefer_state", "product_load", "replicate_id", "chunk_id",
  "route_completed", "trip_distance_miles", "trip_duration_hours", "congestion_delay_hours", "refrigeration_runtime_hours",
  "diesel_gallons", "traction_electricity_kwh", "charging_stops", "charging_time_hours", "total_trip_co2_kg",
  "total_kcal_delivered", "co2_per_1000kcal"
))
scenario_rows <- scenario_rows[, .(
  run_id,
  layer_type,
  factory,
  powertrain,
  reefer_state,
  product_load,
  replicate_id,
  chunk_id,
  route_completed,
  trip_distance_miles,
  trip_duration_hours,
  congestion_delay_hours,
  refrigeration_runtime_hours,
  diesel_gallons,
  traction_electricity_kwh,
  charging_stops,
  charging_time_hours,
  total_trip_co2_kg,
  total_kcal_delivered,
  co2_per_1000kcal
)]

tmp_dir <- tempfile("transport_catalog_ingest_")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
on.exit(unlink(tmp_dir, recursive = TRUE, force = TRUE), add = TRUE)

tables_to_write <- list(
  runs = runs_df,
  manifests = layer_df,
  scenario_rows = scenario_rows,
  crossed_results = crossed_df,
  crossed_summary = crossed_summary_df,
  realistic_results = realistic_df,
  realistic_powertrain_summary = realistic_powertrain_df,
  decomposition = decomposition_df
)

sql_parts <- character()
for (nm in names(tables_to_write)) {
  dt <- tables_to_write[[nm]]
  if (nrow(dt) == 0) next
  csv_path <- file.path(tmp_dir, paste0(nm, ".csv"))
  fwrite(dt, csv_path)
  sql_parts <- c(sql_parts, write_table_sql(nm, normalizePath(csv_path, winslash = "/", mustWork = FALSE)))
}

if (length(sql_parts) == 0) {
  cat("No new rows to ingest after manifest scan.\n")
  quit(save = "no", status = 0)
}

sql_path <- file.path(tmp_dir, "ingest.sql")
writeLines(sql_parts, con = sql_path)
res <- system2("duckdb", args = c(opt$db, "-f", sql_path))
if (!identical(res, 0L)) stop("duckdb ingest failed with status ", res)

cat("Ingested run_ids: ", paste(runs_df$run_id, collapse = ", "), "\n", sep = "")
cat("DuckDB catalog: ", opt$db, "\n", sep = "")
