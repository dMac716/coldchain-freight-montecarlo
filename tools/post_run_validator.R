#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

parse_bool <- function(x, default = FALSE) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Boolean value expected, got: ", as.character(x))
}

read_csv_if_exists <- function(path) {
  if (!file.exists(path)) return(data.table::data.table())
  data.table::fread(path, showProgress = FALSE)
}

resolve_file <- function(root, relative_path, fallback_name = NULL) {
  candidate <- file.path(root, relative_path)
  if (file.exists(candidate)) return(candidate)
  if (!is.null(fallback_name)) {
    fallback <- file.path(root, fallback_name)
    if (file.exists(fallback)) return(fallback)
  }
  candidate
}

check_finite_positive <- function(d, cols) {
  out <- list()
  for (nm in cols) {
    if (!nm %in% names(d)) {
      out[[nm]] <- FALSE
      next
    }
    vals <- suppressWarnings(as.numeric(d[[nm]]))
    out[[nm]] <- all(is.finite(vals) & vals > 0)
  }
  out
}

normalize_manifest <- function(path) {
  if (!file.exists(path)) return(list())
  fromJSON(path, simplifyVector = TRUE)
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--artifact_root"), type = "character", default = Sys.getenv("ARTIFACT_ROOT", unset = "")),
  make_option(c("--run_id"), type = "character", default = Sys.getenv("RUN_ID", unset = "")),
  make_option(c("--lane_id"), type = "character", default = Sys.getenv("LANE_ID", unset = "")),
  make_option(c("--expected_layer_type"), type = "character", default = Sys.getenv("EXPECTED_LAYER_TYPE", unset = "controlled_crossed+realistic_lca")),
  make_option(c("--expect_crossed_cells"), type = "integer", default = suppressWarnings(as.integer(Sys.getenv("EXPECT_CROSSED_CELLS", unset = "16")))),
  make_option(c("--duckdb_test_db"), type = "character", default = Sys.getenv("DUCKDB_TEST_DB", unset = "")),
  make_option(c("--update_manifest"), type = "character", default = Sys.getenv("UPDATE_MANIFEST", unset = "false")),
  make_option(c("--summary_out"), type = "character", default = ""),
  make_option(c("--json_out"), type = "character", default = "")
)))

if (!nzchar(opt$artifact_root)) stop("--artifact_root is required")
root <- normalizePath(opt$artifact_root, winslash = "/", mustWork = TRUE)

manifest_path <- file.path(root, "manifest.json")
has_remote_layout <- dir.exists(file.path(root, "raw")) || dir.exists(file.path(root, "summaries"))
raw_dir <- if (dir.exists(file.path(root, "raw"))) file.path(root, "raw") else root
summary_dir <- if (dir.exists(file.path(root, "summaries"))) file.path(root, "summaries") else root
log_dir <- if (dir.exists(file.path(root, "logs"))) file.path(root, "logs") else root
validation_dir <- if (dir.exists(file.path(root, "validation"))) file.path(root, "validation") else file.path(root, "validation")
dir.create(validation_dir, recursive = TRUE, showWarnings = FALSE)

crossed_path <- resolve_file(raw_dir, "crossed_factory_transport_scenarios.csv")
realistic_path <- resolve_file(raw_dir, "transport_sim_rows.csv")
crossed_summary_path <- resolve_file(summary_dir, "crossed_factory_transport_summary.csv")
paired_summary_path <- resolve_file(summary_dir, "transport_sim_paired_summary.csv")
powertrain_summary_path <- resolve_file(summary_dir, "transport_sim_powertrain_summary.csv")
graphics_inputs_path <- resolve_file(summary_dir, "transport_sim_graphics_inputs.csv")
decomp_path <- resolve_file(summary_dir, "transport_effect_decomposition.csv")
validation_report_path <- if (file.exists(file.path(root, "crossed_factory_transport_validation_report.txt"))) {
  file.path(root, "crossed_factory_transport_validation_report.txt")
} else {
  resolve_file(validation_dir, "crossed_factory_transport_validation_report.txt", fallback_name = "crossed_factory_transport_validation_report.txt")
}
progress_log_path <- resolve_file(log_dir, "progress.log", fallback_name = "progress.log")

crossed <- read_csv_if_exists(crossed_path)
realistic <- read_csv_if_exists(realistic_path)
manifest <- normalize_manifest(manifest_path)

errors <- character()
warnings <- character()

add_error <- function(msg) errors <<- c(errors, msg)
add_warning <- function(msg) warnings <<- c(warnings, msg)

required_files <- c(
  manifest_path,
  crossed_path,
  crossed_summary_path,
  decomp_path,
  realistic_path,
  paired_summary_path,
  powertrain_summary_path,
  graphics_inputs_path,
  validation_report_path
)
missing_files <- required_files[!file.exists(required_files)]
if (length(missing_files) > 0) add_error(paste("missing_required_files", paste(basename(missing_files), collapse = ","), sep = ":"))

required_manifest_fields <- c(
  "run_id", "lane_id", "gcp_account_id", "commit_sha", "branch", "timestamp_utc", "seed_base", "chunk_id",
  "n_reps", "worker_count", "layer_type", "scenario_design_version", "validation_passed", "promotable",
  "output_root", "bucket_path"
)
manifest_missing <- required_manifest_fields[!required_manifest_fields %in% names(manifest)]
if (length(manifest_missing) > 0) add_error(paste("manifest_missing_fields", paste(manifest_missing, collapse = ","), sep = ":"))
if (nzchar(opt$run_id) && length(manifest$run_id) > 0 && !identical(as.character(manifest$run_id), as.character(opt$run_id))) {
  add_error(paste("run_id_mismatch", manifest$run_id, opt$run_id, sep = ":"))
}
if (nzchar(opt$lane_id) && length(manifest$lane_id) > 0 && !identical(as.character(manifest$lane_id), as.character(opt$lane_id))) {
  add_error(paste("lane_id_mismatch", manifest$lane_id, opt$lane_id, sep = ":"))
}
if (length(manifest$layer_type) > 0 && !identical(as.character(manifest$layer_type), as.character(opt$expected_layer_type))) {
  add_warning(paste("layer_type", as.character(manifest$layer_type), "expected", as.character(opt$expected_layer_type)))
}

if (nrow(crossed) == 0) {
  add_error("crossed_rows_missing")
} else {
  if (!"scenario_cell" %in% names(crossed)) add_error("crossed_missing_scenario_cell")
  if ("scenario_cell" %in% names(crossed)) {
    cell_count <- data.table::uniqueN(as.character(crossed$scenario_cell))
    if (!identical(cell_count, as.integer(opt$expect_crossed_cells))) {
      add_error(paste("crossed_cell_count", cell_count, "expected", opt$expect_crossed_cells))
    }
  }
  if ("scenario_name" %in% names(crossed) && "scenario_cell" %in% names(crossed)) {
    if (!all(as.character(crossed$scenario_name) == as.character(crossed$scenario_cell))) {
      add_error("crossed_scenario_labels_incorrect")
    }
  }
  if ("route_completed" %in% names(crossed)) {
    completed <- as.logical(crossed$route_completed)
    if (!all(completed %in% TRUE)) add_error("route_completion_gate_failed")
  } else {
    add_error("crossed_missing_route_completed")
  }
}

if (nrow(realistic) == 0) {
  add_error("realistic_rows_missing")
} else {
  needed_realistic <- c("factory", "product_load", "reefer_state", "scenario_name", "total_kcal_delivered", "co2_per_1000kcal")
  for (nm in needed_realistic) {
    if (!nm %in% names(realistic)) add_error(paste("realistic_missing_column", nm, sep = ":"))
  }
  if (all(c("factory", "product_load", "reefer_state") %in% names(realistic))) {
    bad_pairings <- realistic[!(
      (factory == "kansas" & product_load == "dry" & reefer_state == "off") |
        (factory == "texas" & product_load == "refrigerated" & reefer_state == "on")
    )]
    if (nrow(bad_pairings) > 0) add_error("realistic_pairing_isolation_failed")
  }
  if ("scenario_name" %in% names(realistic)) {
    expected <- c("dry_bev", "dry_diesel", "refrigerated_bev", "refrigerated_diesel")
    if (!all(as.character(realistic$scenario_name) %in% expected)) add_error("realistic_scenario_labels_incorrect")
  }
  finite_checks <- check_finite_positive(realistic, c("total_kcal_delivered", "co2_per_1000kcal"))
  if (!isTRUE(finite_checks$total_kcal_delivered)) add_error("total_kcal_delivered_not_positive_finite")
  if (!isTRUE(finite_checks$co2_per_1000kcal)) add_error("co2_per_1000kcal_not_positive_finite")
  if (all(c("product_load", "reefer_state") %in% names(realistic))) {
    dry_bad <- realistic[product_load == "dry" & reefer_state != "off"]
    if (nrow(dry_bad) > 0) add_error("dry_reefer_not_zero_where_required")
  }
  if (all(c("product_load", "refrigeration_runtime_hours") %in% names(realistic))) {
    dry_runtime <- suppressWarnings(as.numeric(realistic[product_load == "dry", refrigeration_runtime_hours]))
    if (length(dry_runtime) > 0 && any(is.finite(dry_runtime) & abs(dry_runtime) > 1e-9)) {
      add_error("dry_refrigeration_runtime_nonzero")
    }
  }
}

validation_passed_report <- FALSE
if (file.exists(validation_report_path)) {
  lines <- readLines(validation_report_path, warn = FALSE)
  validation_passed_report <- any(grepl("^VALIDATION:\\s*PASS", lines))
  if (!validation_passed_report) add_error("validation_report_not_pass")
} else {
  add_error("validation_report_missing")
}

duckdb_ingest_ok <- FALSE
duckdb_message <- "not_run"
if (nzchar(opt$duckdb_test_db)) {
  db_path <- normalizePath(opt$duckdb_test_db, winslash = "/", mustWork = FALSE)
  dir.create(dirname(db_path), recursive = TRUE, showWarnings = FALSE)
  cache_root <- dirname(dirname(root))
  cmd <- c("tools/ingest_remote_runs.R", "--cache_root", cache_root, "--db", db_path, "--force", "true")
  out <- tryCatch(system2("Rscript", args = cmd, stdout = TRUE, stderr = TRUE), error = function(e) paste("error", conditionMessage(e)))
  status <- attr(out, "status")
  duckdb_ingest_ok <- is.null(status) || identical(status, 0L)
  duckdb_message <- paste(out, collapse = "\n")
  if (!duckdb_ingest_ok) add_error("duckdb_ingest_failed")
}

promotable <- length(errors) == 0
validator_status <- if (promotable) "promotable" else "failed"

result <- list(
  run_id = if (nzchar(opt$run_id)) opt$run_id else as.character(manifest$run_id %||% basename(root)),
  lane_id = if (nzchar(opt$lane_id)) opt$lane_id else as.character(manifest$lane_id %||% basename(dirname(root))),
  artifact_root = root,
  manifest_path = manifest_path,
  remote_layout = has_remote_layout,
  validation_passed = promotable,
  promotable = promotable,
  validator_status = validator_status,
  crossed_cell_count = if ("scenario_cell" %in% names(crossed)) data.table::uniqueN(as.character(crossed$scenario_cell)) else 0L,
  realistic_row_count = nrow(realistic),
  route_completion_ok = nrow(crossed) > 0 && "route_completed" %in% names(crossed) && all(as.logical(crossed$route_completed) %in% TRUE),
  duckdb_ingest_ok = duckdb_ingest_ok,
  duckdb_message = duckdb_message,
  errors = unique(errors),
  warnings = unique(warnings)
)

summary_out <- if (nzchar(opt$summary_out)) opt$summary_out else file.path(validation_dir, "post_run_validator.txt")
json_out <- if (nzchar(opt$json_out)) opt$json_out else file.path(validation_dir, "post_run_validator.json")

writeLines(c(
  paste0("validator_status=", validator_status),
  paste0("validation_passed=", tolower(as.character(promotable))),
  paste0("promotable=", tolower(as.character(promotable))),
  paste0("duckdb_ingest_ok=", tolower(as.character(duckdb_ingest_ok))),
  paste0("crossed_cell_count=", result$crossed_cell_count),
  paste0("realistic_row_count=", result$realistic_row_count),
  if (length(result$errors) > 0) paste("errors:", paste(result$errors, collapse = " | ")) else "errors:none",
  if (length(result$warnings) > 0) paste("warnings:", paste(result$warnings, collapse = " | ")) else "warnings:none"
), con = summary_out)
write_json(result, path = json_out, pretty = TRUE, auto_unbox = TRUE, null = "null")

if (parse_bool(opt$update_manifest, FALSE) && file.exists(manifest_path)) {
  manifest$validation_passed <- promotable
  manifest$promotable <- promotable
  manifest$validator_status <- validator_status
  manifest$validator_json_path <- if (has_remote_layout) {
    "validation/post_run_validator.json"
  } else {
    normalizePath(json_out, winslash = "/", mustWork = FALSE)
  }
  write_json(manifest, path = manifest_path, pretty = TRUE, auto_unbox = TRUE, null = "null")
}

cat(summary_out, "\n", sep = "")
quit(save = "no", status = if (promotable) 0L else 1L)
