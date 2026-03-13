#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

safe_git <- function(args) {
  out <- tryCatch(system2("git", args = args, stdout = TRUE, stderr = FALSE), error = function(e) character())
  if (length(out) == 0) return("")
  as.character(out[[1]])
}

first_nonempty <- function(...) {
  vals <- unlist(list(...), use.names = FALSE)
  vals <- as.character(vals)
  vals <- vals[nzchar(trimws(vals))]
  if (length(vals) == 0) return("")
  vals[[1]]
}

parse_bool <- function(x, default = FALSE) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Boolean value expected, got: ", as.character(x))
}

extract_chunk_id <- function(paths) {
  vals <- vapply(paths, function(path) {
    mm <- regexec("(phase1|chunk_[0-9]+)", path)
    rr <- regmatches(path, mm)[[1]]
    if (length(rr) >= 2) rr[[2]] else NA_character_
  }, character(1))
  sort(unique(vals[!is.na(vals) & nzchar(vals)]))
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--run_id"), type = "character", default = Sys.getenv("RUN_ID", unset = "")),
  make_option(c("--out_root"), type = "character", default = Sys.getenv("OUT_ROOT", unset = "")),
  make_option(c("--lane_id"), type = "character", default = Sys.getenv("LANE_ID", unset = Sys.getenv("CONTRIBUTOR_ID", unset = Sys.getenv("USER", unset = "unknown")))),
  make_option(c("--gcp_account_id"), type = "character", default = Sys.getenv("GCP_ACCOUNT_ID", unset = "")),
  make_option(c("--contributor_id"), type = "character", default = Sys.getenv("CONTRIBUTOR_ID", unset = Sys.getenv("USER", unset = "unknown"))),
  make_option(c("--seed_base"), type = "integer", default = suppressWarnings(as.integer(Sys.getenv("SEED", unset = "5600")))),
  make_option(c("--n_reps"), type = "integer", default = suppressWarnings(as.integer(Sys.getenv("N_REPS", unset = "0")))),
  make_option(c("--worker_count"), type = "integer", default = suppressWarnings(as.integer(Sys.getenv("WORKER_COUNT", unset = "1")))),
  make_option(c("--launcher_version"), type = "character", default = Sys.getenv("LAUNCHER_VERSION", unset = "tools/run_codespace_distribution_lane.sh")),
  make_option(c("--scenario_design_version"), type = "character", default = Sys.getenv("SCENARIO_DESIGN_VERSION", unset = "crossed_factory_transport_v1")),
  make_option(c("--layer_type"), type = "character", default = Sys.getenv("LAYER_TYPE", unset = "controlled_crossed+realistic_lca")),
  make_option(c("--chunk_id"), type = "character", default = Sys.getenv("CHUNK_ID", unset = "")),
  make_option(c("--validation_passed"), type = "character", default = Sys.getenv("VALIDATION_PASSED", unset = "")),
  make_option(c("--promotable"), type = "character", default = Sys.getenv("PROMOTABLE", unset = "")),
  make_option(c("--bucket_path"), type = "character", default = Sys.getenv("BUCKET_PATH", unset = "")),
  make_option(c("--validator_status"), type = "character", default = Sys.getenv("VALIDATOR_STATUS", unset = "")),
  make_option(c("--notes"), type = "character", default = Sys.getenv("NOTES", unset = "")),
  make_option(c("--timestamp_utc"), type = "character", default = ""),
  make_option(c("--validation_path"), type = "character", default = ""),
  make_option(c("--validator_json_path"), type = "character", default = ""),
  make_option(c("--remote_results_root"), type = "character", default = Sys.getenv("REMOTE_RESULTS_ROOT", unset = ""))
)))

if (!nzchar(opt$run_id)) stop("--run_id is required")
if (!nzchar(opt$out_root)) stop("--out_root is required")

dir.create(opt$out_root, recursive = TRUE, showWarnings = FALSE)

timestamp_utc <- if (nzchar(opt$timestamp_utc)) {
  opt$timestamp_utc
} else {
  format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

validation_path <- if (nzchar(opt$validation_path)) opt$validation_path else file.path(opt$out_root, "crossed_factory_transport_validation_report.txt")
validation_passed <- file.exists(validation_path) && any(grepl("^VALIDATION:\\s*PASS", readLines(validation_path, warn = FALSE)))

chunk_paths <- list.files(file.path(opt$out_root, "phase2"), pattern = "^chunk_.*_(summary|runs)\\.csv$", recursive = TRUE, full.names = TRUE)
chunk_ids <- extract_chunk_id(chunk_paths)
chunk_id <- if (nzchar(opt$chunk_id)) {
  opt$chunk_id
} else if (length(chunk_ids) > 0) {
  utils::tail(chunk_ids, 1)
} else if (dir.exists(file.path(opt$out_root, "phase1"))) {
  "phase1"
} else {
  ""
}

controlled_files <- list(
  scenarios = file.path(opt$out_root, "crossed_factory_transport_scenarios.csv"),
  summary = file.path(opt$out_root, "crossed_factory_transport_summary.csv"),
  decomposition = file.path(opt$out_root, "transport_effect_decomposition.csv")
)
realistic_files <- list(
  rows = file.path(opt$out_root, "transport_sim_rows.csv"),
  paired_summary = file.path(opt$out_root, "transport_sim_paired_summary.csv"),
  powertrain_summary = file.path(opt$out_root, "transport_sim_powertrain_summary.csv"),
  graphics_inputs = file.path(opt$out_root, "transport_sim_graphics_inputs.csv")
)
log_files <- list(
  progress = file.path(opt$out_root, "progress.log"),
  nohup = file.path(opt$out_root, "nohup.log"),
  validation = validation_path
)

validation_passed <- if (nzchar(opt$validation_passed)) {
  parse_bool(opt$validation_passed, default = FALSE)
} else {
  file.exists(validation_path) && any(grepl("^VALIDATION:\\s*PASS", readLines(validation_path, warn = FALSE)))
}
promotable <- if (nzchar(opt$promotable)) parse_bool(opt$promotable, default = FALSE) else FALSE
validator_json_path <- if (nzchar(opt$validator_json_path)) opt$validator_json_path else file.path(opt$out_root, "validation", "post_run_validator.json")

root_manifest <- list(
  run_id = opt$run_id,
  lane_id = opt$lane_id,
  gcp_account_id = if (nzchar(opt$gcp_account_id)) opt$gcp_account_id else NA_character_,
  commit_sha = first_nonempty(
    Sys.getenv("COMMIT_SHA", unset = ""),
    Sys.getenv("GITHUB_SHA", unset = ""),
    safe_git(c("rev-parse", "HEAD"))
  ),
  branch = first_nonempty(
    Sys.getenv("BRANCH", unset = ""),
    Sys.getenv("GITHUB_REF_NAME", unset = ""),
    safe_git(c("rev-parse", "--abbrev-ref", "HEAD"))
  ),
  timestamp_utc = timestamp_utc,
  launcher_version = opt$launcher_version,
  scenario_design_version = opt$scenario_design_version,
  layer_type = opt$layer_type,
  chunk_id = if (nzchar(chunk_id)) chunk_id else NA_character_,
  output_root = normalizePath(opt$out_root, winslash = "/", mustWork = FALSE),
  contributor_id = opt$contributor_id,
  seed_base = as.integer(opt$seed_base),
  n_reps = as.integer(opt$n_reps),
  chunk_count = as.integer(length(chunk_ids)),
  worker_count = as.integer(opt$worker_count),
  validation_passed = isTRUE(validation_passed),
  promotable = isTRUE(promotable),
  bucket_path = if (nzchar(opt$bucket_path)) opt$bucket_path else NA_character_,
  validator_status = if (nzchar(opt$validator_status)) opt$validator_status else NA_character_,
  notes = opt$notes,
  remote_results_root = if (nzchar(opt$remote_results_root)) opt$remote_results_root else NA_character_,
  validator_json_path = if (nzchar(validator_json_path)) normalizePath(validator_json_path, winslash = "/", mustWork = FALSE) else NA_character_,
  layers = list(
    controlled_crossed = list(
      layer_type = "controlled_crossed",
      raw_path = "controlled_crossed/raw/crossed_factory_transport_scenarios.csv",
      summary_path = "controlled_crossed/summaries/crossed_factory_transport_summary.csv",
      decomposition_path = "controlled_crossed/summaries/transport_effect_decomposition.csv"
    ),
    realistic_lca = list(
      layer_type = "realistic_lca",
      raw_path = "realistic_lca/raw/transport_sim_rows.csv",
      paired_summary_path = "realistic_lca/summaries/transport_sim_paired_summary.csv",
      powertrain_summary_path = "realistic_lca/summaries/transport_sim_powertrain_summary.csv",
      graphics_inputs_path = "graphics/transport_sim_graphics_inputs.csv"
    )
  ),
  artifacts = list(
    controlled = controlled_files,
    realistic = realistic_files,
    logs = log_files,
    chunk_ids = unname(chunk_ids)
  )
)

controlled_manifest <- within(as.list(root_manifest), {
  layer_type <- "controlled_crossed"
})
realistic_manifest <- within(as.list(root_manifest), {
  layer_type <- "realistic_lca"
})

write_json(root_manifest, path = file.path(opt$out_root, "manifest.json"), pretty = TRUE, auto_unbox = TRUE, null = "null")
write_json(controlled_manifest, path = file.path(opt$out_root, "controlled_crossed_manifest.json"), pretty = TRUE, auto_unbox = TRUE, null = "null")
write_json(realistic_manifest, path = file.path(opt$out_root, "realistic_lca_manifest.json"), pretty = TRUE, auto_unbox = TRUE, null = "null")

cat(file.path(opt$out_root, "manifest.json"), "\n", sep = "")
