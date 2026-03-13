#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(yaml)
  library(digest)
})

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

parse_bool <- function(x, default = FALSE) {
  if (is.null(x) || length(x) == 0) return(isTRUE(default))
  value <- tolower(trimws(as.character(x[[1]])))
  if (!nzchar(value)) return(isTRUE(default))
  if (value %in% c("1", "true", "yes", "y")) return(TRUE)
  if (value %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Expected boolean value, got: ", as.character(x[[1]]))
}

resolve_repo_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    script_path <- normalizePath(sub("^--file=", "", file_arg[[1]]), winslash = "/", mustWork = TRUE)
    return(normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = TRUE))
  }
  normalizePath(".", winslash = "/", mustWork = TRUE)
}

repo_root <- resolve_repo_root()
setwd(repo_root)

starts_with_any <- function(x, prefixes) {
  any(vapply(prefixes, function(prefix) startsWith(x, prefix), logical(1)))
}

is_uri <- function(x) {
  starts_with_any(x, c("gs://", "file://", "http://", "https://"))
}

contains_glob <- function(x) {
  grepl("[*?\\[]", x)
}

join_path_or_uri <- function(root, child) {
  if (!nzchar(root)) return(child)
  if (is_uri(child) || grepl("^/", child)) return(child)
  if (startsWith(root, "gs://") || startsWith(root, "file://") || startsWith(root, "http://") || startsWith(root, "https://")) {
    return(sprintf("%s/%s", sub("/+$", "", root), sub("^/+", "", child)))
  }
  normalizePath(file.path(root, child), winslash = "/", mustWork = FALSE)
}

ensure_dir <- function(path) {
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  invisible(path)
}

sha256_file <- function(path) {
  digest(file = path, algo = "sha256", serialize = FALSE)
}

read_csv_safe <- function(path, label) {
  tryCatch(
    utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE),
    error = function(e) stop(label, " is not parseable CSV: ", path, " (", conditionMessage(e), ")")
  )
}

read_json_safe <- function(path, label) {
  tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) stop(label, " is not parseable JSON: ", path, " (", conditionMessage(e), ")")
  )
}

trim_trailing_slash <- function(x) sub("/+$", "", x)

copy_local_source <- function(src, dest) {
  if (!file.exists(src)) stop("Local source does not exist: ", src)
  if (file.exists(dest) || dir.exists(dest)) unlink(dest, recursive = TRUE, force = TRUE)
  status <- system2("cp", c("-R", src, dest), stdout = TRUE, stderr = TRUE)
  if (!is.null(attr(status, "status")) && attr(status, "status") != 0) {
    stop("Failed to copy local source ", src, " to ", dest, ": ", paste(status, collapse = "\n"))
  }
  invisible(dest)
}

copy_gcs_source <- function(src, dest) {
  if (file.exists(dest) || dir.exists(dest)) unlink(dest, recursive = TRUE, force = TRUE)
  ensure_dir(dirname(dest))
  if (nzchar(Sys.which("gsutil"))) {
    status <- system2("gsutil", c("-m", "cp", "-r", src, dest), stdout = TRUE, stderr = TRUE)
  } else if (nzchar(Sys.which("gcloud"))) {
    status <- system2("gcloud", c("storage", "cp", "--recursive", src, dest), stdout = TRUE, stderr = TRUE)
  } else {
    stop("Fetching gs:// sources requires gsutil or gcloud on PATH")
  }
  if (!is.null(attr(status, "status")) && attr(status, "status") != 0) {
    stop("Failed to fetch remote source ", src, ": ", paste(status, collapse = "\n"))
  }
  invisible(dest)
}

stage_source <- function(source_uri, dest, dry_run = FALSE) {
  plan <- list(source = source_uri, staged_path = dest, action = "stage")
  if (isTRUE(dry_run)) return(c(plan, list(status = "planned")))

  if (startsWith(source_uri, "gs://")) {
    copy_gcs_source(source_uri, dest)
  } else if (startsWith(source_uri, "file://")) {
    copy_local_source(sub("^file://", "", source_uri), dest)
  } else if (startsWith(source_uri, "http://") || startsWith(source_uri, "https://")) {
    stop("HTTP/HTTPS staging is not implemented. Fetch artifacts into a directory or use gs:// sources.")
  } else {
    copy_local_source(source_uri, dest)
  }

  c(plan, list(status = "staged"))
}

format_num <- function(x, digits = 2) {
  if (!is.finite(as.numeric(x))) return("NA")
  formatC(as.numeric(x), format = "f", digits = digits)
}

compute_progress_done <- function(progress_df) {
  if (!"status" %in% names(progress_df) || nrow(progress_df) == 0) return(NA)
  as.character(progress_df$status[[nrow(progress_df)]])
}

check_required_file <- function(bundle_dir, rel_path) {
  target <- file.path(bundle_dir, rel_path)
  if (contains_glob(rel_path)) {
    matches <- Sys.glob(target)
    return(list(ok = length(matches) > 0, matches = matches))
  }
  list(ok = file.exists(target), matches = target)
}

check_bundle <- function(bundle_cfg, bundle_dir, checks_cfg) {
  failures <- character()
  warnings <- character()
  required_files <- as.character(unlist(
    bundle_cfg$required_files %||%
      bundle_cfg$required_artifacts %||%
      checks_cfg$required_files %||%
      checks_cfg$artifact_completeness$required_artifacts %||%
      character()
  ))
  optional_files <- as.character(unlist(
    checks_cfg$optional_files %||%
      checks_cfg$artifact_completeness$optional_artifacts %||%
      character()
  ))
  error_keywords <- as.character(unlist(
    checks_cfg$log_error_keywords %||%
      checks_cfg$logs$error_keywords %||%
      character()
  ))
  runtime_required_cols <- as.character(unlist(checks_cfg$runtime$required_columns %||% character()))
  memory_required_fields <- as.character(unlist(checks_cfg$memory$required_summary_fields %||% character()))
  rss_limit_mb <- as.numeric(bundle_cfg$rss_limit_mb %||% checks_cfg$memory$rss_limit_mb %||% NA_real_)
  require_runtime_summary <- "runtime_summary.csv" %in% required_files

  file_results <- lapply(required_files, function(rel_path) {
    res <- check_required_file(bundle_dir, rel_path)
    if (!isTRUE(res$ok)) failures <<- c(failures, paste0("Missing required artifact: ", rel_path))
    list(path = rel_path, ok = isTRUE(res$ok), matches = unname(as.character(res$matches)))
  })
  names(file_results) <- required_files

  optional_results <- lapply(optional_files, function(rel_path) {
    res <- check_required_file(bundle_dir, rel_path)
    list(path = rel_path, present = isTRUE(res$ok), matches = unname(as.character(res$matches)))
  })
  names(optional_results) <- optional_files

  runs_path <- file.path(bundle_dir, "runs.csv")
  summary_path <- file.path(bundle_dir, "summary.csv")
  runtime_path <- file.path(bundle_dir, "runtime_summary.csv")
  memory_profile_path <- file.path(bundle_dir, "memory_profile.csv")
  memory_summary_path <- file.path(bundle_dir, "memory_summary.json")
  progress_path <- file.path(bundle_dir, "progress.csv")
  console_path <- file.path(bundle_dir, "console.log")

  runs_df <- if (file.exists(runs_path)) read_csv_safe(runs_path, "runs.csv") else data.frame()
  summary_df <- if (file.exists(summary_path)) read_csv_safe(summary_path, "summary.csv") else data.frame()
  runtime_df <- if (file.exists(runtime_path)) read_csv_safe(runtime_path, "runtime_summary.csv") else data.frame()
  memory_profile_df <- if (file.exists(memory_profile_path)) read_csv_safe(memory_profile_path, "memory_profile.csv") else data.frame()
  progress_df <- if (file.exists(progress_path)) read_csv_safe(progress_path, "progress.csv") else data.frame()
  memory_summary <- if (file.exists(memory_summary_path)) read_json_safe(memory_summary_path, "memory_summary.json") else list()

  if (file.exists(runs_path) && nrow(runs_df) == 0) failures <- c(failures, "runs.csv is empty")
  if (file.exists(summary_path) && nrow(summary_df) == 0) failures <- c(failures, "summary.csv is empty")
  if (file.exists(runtime_path) && nrow(runtime_df) == 0) failures <- c(failures, "runtime_summary.csv is empty")
  if (file.exists(memory_profile_path) && nrow(memory_profile_df) == 0) failures <- c(failures, "memory_profile.csv is empty")

  if (isTRUE(require_runtime_summary)) {
    missing_runtime_cols <- setdiff(runtime_required_cols, names(runtime_df))
    if (length(missing_runtime_cols) > 0) failures <- c(failures, paste0("runtime_summary.csv missing columns: ", paste(missing_runtime_cols, collapse = ", ")))
  }

  missing_memory_fields <- setdiff(memory_required_fields, names(memory_summary))
  if (length(missing_memory_fields) > 0) failures <- c(failures, paste0("memory_summary.json missing fields: ", paste(missing_memory_fields, collapse = ", ")))

  expected_runs <- suppressWarnings(as.integer(bundle_cfg$expected_runs %||% NA_integer_))
  actual_runs <- if (nrow(runs_df) > 0) nrow(runs_df) else NA_integer_
  if (is.finite(expected_runs) && !identical(actual_runs, expected_runs)) {
    failures <- c(failures, sprintf("Expected %d rows in runs.csv but found %s", expected_runs, as.character(actual_runs)))
  }
  if (isTRUE(require_runtime_summary) && is.finite(expected_runs) && "run_count" %in% names(runtime_df)) {
    runtime_run_count <- suppressWarnings(as.integer(runtime_df$run_count[[1]]))
    if (!is.na(runtime_run_count) && runtime_run_count < expected_runs) {
      failures <- c(failures, sprintf("Expected runtime_summary.csv run_count >= %d but found %s", expected_runs, as.character(runtime_run_count)))
    } else if (!is.na(runtime_run_count) && runtime_run_count != expected_runs) {
      warnings <- c(warnings, sprintf("runtime_summary.csv run_count=%s differs from runs.csv row count=%d", as.character(runtime_run_count), expected_runs))
    }
  }

  peak_rss_mb <- suppressWarnings(as.numeric(memory_summary$peak_rss_mb %||% NA_real_))
  final_rss_mb <- suppressWarnings(as.numeric(memory_summary$final_rss_mb %||% NA_real_))
  profile_peak_rss_mb <- if ("rss_mb" %in% names(memory_profile_df) && nrow(memory_profile_df) > 0) {
    suppressWarnings(max(as.numeric(memory_profile_df$rss_mb), na.rm = TRUE))
  } else {
    NA_real_
  }
  if (is.finite(rss_limit_mb)) {
    if (is.finite(peak_rss_mb) && peak_rss_mb > rss_limit_mb) failures <- c(failures, sprintf("Peak RSS %.2f exceeds limit %.2f", peak_rss_mb, rss_limit_mb))
    if (is.finite(final_rss_mb) && final_rss_mb > rss_limit_mb) failures <- c(failures, sprintf("Final RSS %.2f exceeds limit %.2f", final_rss_mb, rss_limit_mb))
    if (is.finite(profile_peak_rss_mb) && profile_peak_rss_mb > rss_limit_mb) failures <- c(failures, sprintf("Memory profile RSS %.2f exceeds limit %.2f", profile_peak_rss_mb, rss_limit_mb))
  }

  require_done_status <- parse_bool(checks_cfg$progress$require_done_status %||% FALSE, default = FALSE)
  final_status <- if (nrow(progress_df) > 0) compute_progress_done(progress_df) else NA_character_
  if (isTRUE(require_done_status) && !is.na(final_status) && !identical(final_status, "DONE")) {
    failures <- c(failures, paste0("progress.csv final status is not DONE: ", final_status))
  }

  if (file.exists(console_path)) {
    console_text <- tolower(paste(readLines(console_path, warn = FALSE), collapse = "\n"))
    matched <- error_keywords[vapply(error_keywords, function(x) grepl(tolower(x), console_text, fixed = TRUE), logical(1))]
    if (length(matched) > 0) failures <- c(failures, paste0("console.log contains error markers: ", paste(unique(matched), collapse = ", ")))
  } else {
    warnings <- c(warnings, "console.log not present")
  }

  metrics <- list(
    expected_runs = if (is.finite(expected_runs)) expected_runs else NULL,
    actual_runs = if (is.finite(actual_runs)) actual_runs else NULL,
    summary_rows = if (nrow(summary_df) > 0) nrow(summary_df) else NULL,
    runtime_run_count = if ("run_count" %in% names(runtime_df)) suppressWarnings(as.integer(runtime_df$run_count[[1]])) else NULL,
    wall_seconds = if ("wall_seconds" %in% names(runtime_df)) suppressWarnings(as.numeric(runtime_df$wall_seconds[[1]])) else NULL,
    avg_run_seconds = if ("avg_run_seconds" %in% names(runtime_df)) suppressWarnings(as.numeric(runtime_df$avg_run_seconds[[1]])) else NULL,
    peak_rss_mb = if (is.finite(peak_rss_mb)) peak_rss_mb else NULL,
    final_rss_mb = if (is.finite(final_rss_mb)) final_rss_mb else NULL,
    delta_rss_mb = suppressWarnings(as.numeric(memory_summary$delta_rss_mb %||% NA_real_)),
    rss_limit_mb = if (is.finite(rss_limit_mb)) rss_limit_mb else NULL,
    final_progress_status = if (!is.na(final_status)) final_status else NULL
  )

  list(
    name = as.character(bundle_cfg$name),
    group = as.character(bundle_cfg$group %||% NA_character_),
    bundle_dir = bundle_dir,
    pass = length(failures) == 0,
    failures = unique(failures),
    warnings = unique(warnings),
    required_files = file_results,
    optional_files = optional_results,
    metrics = metrics
  )
}

run_regression_check <- function(script_path, report_dir, dry_run = FALSE, enabled = TRUE) {
  result <- list(
    enabled = isTRUE(enabled),
    script = script_path,
    log_path = file.path(report_dir, "verify_summary_runtime_split.log"),
    pass = NA,
    skipped = FALSE,
    exit_code = NA_integer_,
    message = ""
  )

  if (!isTRUE(enabled)) {
    result$pass <- TRUE
    result$skipped <- TRUE
    result$message <- "Regression check disabled in config"
    return(result)
  }
  if (isTRUE(dry_run)) {
    result$pass <- TRUE
    result$skipped <- TRUE
    result$message <- "Dry-run only; regression not executed"
    return(result)
  }

  ensure_dir(report_dir)
  env_vars <- c(
    "OMP_NUM_THREADS=1",
    "OPENBLAS_NUM_THREADS=1",
    "MKL_NUM_THREADS=1",
    "VECLIB_MAXIMUM_THREADS=1",
    "R_DATATABLE_NUM_THREADS=1",
    "KMP_BLOCKTIME=0",
    "KMP_SETTINGS=0"
  )
  output <- system2("Rscript", args = script_path, env = env_vars, stdout = TRUE, stderr = TRUE)
  writeLines(output, con = result$log_path)
  status <- attr(output, "status")
  if (is.null(status)) status <- 0L
  result$exit_code <- as.integer(status)
  result$pass <- identical(result$exit_code, 0L)
  result$message <- if (isTRUE(result$pass)) {
    "summary/runtime split regression passed"
  } else {
    paste("summary/runtime split regression failed; see", result$log_path)
  }
  result
}

run_rng_checks <- function(checks_cfg, bundle_results, staged_root) {
  rng_cfg <- checks_cfg$rng %||% checks_cfg$rng_hash %||% list()
  hash_file <- as.character(rng_cfg$hash_file %||% "runs.csv")
  bundle_by_name <- setNames(bundle_results, vapply(bundle_results, `[[`, character(1), "name"))

  extract_pair <- function(cfg, singular_key, plural_key) {
    plural <- cfg[[plural_key]] %||% list()
    if (length(plural) > 0) {
      first <- plural[[1]]
      return(list(
        a = as.character(first$a %||% "")[[1]],
        b = as.character(first$b %||% "")[[1]]
      ))
    }
    singular <- cfg[[singular_key]] %||% list()
    list(
      a = as.character(singular$a %||% "")[[1]],
      b = as.character(singular$b %||% "")[[1]]
    )
  }

  resolve_hash_path <- function(key) {
    target <- bundle_by_name[[key]]$bundle_dir %||% file.path(staged_root, key)
    file.path(target, hash_file)
  }

  same_pair <- extract_pair(rng_cfg, "same_seed", "same_seed_pairs")
  diff_pair <- extract_pair(rng_cfg, "different_seed", "different_seed_pairs")
  same_a_key <- same_pair$a
  same_b_key <- same_pair$b
  diff_a_key <- diff_pair$a
  diff_b_key <- diff_pair$b

  failures <- character()
  payload <- list(
    hash_file = hash_file,
    same_seed = list(),
    different_seed = list()
  )

  hash_if_exists <- function(path) {
    if (!file.exists(path)) return(NULL)
    sha256_file(path)
  }

  same_a_path <- resolve_hash_path(same_a_key)
  same_b_path <- resolve_hash_path(same_b_key)
  same_a_hash <- hash_if_exists(same_a_path)
  same_b_hash <- hash_if_exists(same_b_path)
  if (is.null(same_a_hash) || is.null(same_b_hash)) {
    failures <- c(failures, "Missing same-seed RNG comparison artifact(s)")
  }
  same_pass <- !is.null(same_a_hash) && identical(same_a_hash, same_b_hash)
  if (!isTRUE(same_pass)) failures <- c(failures, "Same-seed hashes are not identical")
  payload$same_seed <- list(
    a = list(name = same_a_key, path = same_a_path, sha256 = same_a_hash),
    b = list(name = same_b_key, path = same_b_path, sha256 = same_b_hash),
    pass = same_pass
  )

  diff_a_path <- resolve_hash_path(diff_a_key)
  diff_b_path <- resolve_hash_path(diff_b_key)
  diff_a_hash <- hash_if_exists(diff_a_path)
  diff_b_hash <- hash_if_exists(diff_b_path)
  if (is.null(diff_a_hash) || is.null(diff_b_hash)) {
    failures <- c(failures, "Missing different-seed RNG comparison artifact(s)")
  }
  diff_pass <- !is.null(diff_a_hash) && !identical(diff_a_hash, diff_b_hash)
  if (!isTRUE(diff_pass)) failures <- c(failures, "Different-seed hashes are identical")
  payload$different_seed <- list(
    a = list(name = diff_a_key, path = diff_a_path, sha256 = diff_a_hash),
    b = list(name = diff_b_key, path = diff_b_path, sha256 = diff_b_hash),
    pass = diff_pass
  )

  list(pass = length(failures) == 0, failures = unique(failures), details = payload)
}

render_markdown_report <- function(summary_payload, path) {
  core_bundles <- Filter(function(x) identical(x$group, "core"), summary_payload$bundles)
  lines <- c(
    "# Validation Report",
    "",
    sprintf("- Generated at: `%s`", summary_payload$generated_at_utc),
    sprintf("- Config: `%s`", summary_payload$config_path),
    sprintf("- Source root: `%s`", summary_payload$source_root),
    sprintf("- Work dir: `%s`", summary_payload$work_dir),
    sprintf("- Overall status: **%s**", if (isTRUE(summary_payload$overall_pass)) "PASS" else "FAIL"),
    "",
    "## Checks",
    "",
    sprintf("- Artifact completeness: **%s**", if (isTRUE(summary_payload$verdicts$artifact_completeness)) "PASS" else "FAIL"),
    sprintf("- Memory/runtime profiles: **%s**", if (isTRUE(summary_payload$verdicts$memory_runtime_profiles)) "PASS" else "FAIL"),
    sprintf("- Summary/runtime split regression: **%s**",
            if (isTRUE(summary_payload$regression$skipped)) "SKIPPED"
            else if (isTRUE(summary_payload$verdicts$summary_runtime_split)) "PASS"
            else "FAIL"),
    sprintf("- RNG same-seed reproducibility: **%s**", if (isTRUE(summary_payload$verdicts$rng_same_seed)) "PASS" else "FAIL"),
    sprintf("- RNG different-seed divergence: **%s**", if (isTRUE(summary_payload$verdicts$rng_different_seed)) "PASS" else "FAIL"),
    "",
    "## Core bundles",
    ""
  )

  for (bundle in core_bundles) {
    metrics <- bundle$metrics
    lines <- c(
      lines,
      sprintf("- `%s`: pass=%s runs=%s peak_rss_mb=%s final_rss_mb=%s wall_seconds=%s avg_run_seconds=%s",
              bundle$name,
              if (isTRUE(bundle$pass)) "true" else "false",
              as.character(metrics$actual_runs %||% "NA"),
              format_num(metrics$peak_rss_mb %||% NA_real_),
              format_num(metrics$final_rss_mb %||% NA_real_),
              format_num(metrics$wall_seconds %||% NA_real_),
              format_num(metrics$avg_run_seconds %||% NA_real_))
    )
    if (length(bundle$failures) > 0) {
      lines <- c(lines, paste0("  failures: ", paste(bundle$failures, collapse = " | ")))
    }
    if (length(bundle$warnings) > 0) {
      lines <- c(lines, paste0("  warnings: ", paste(bundle$warnings, collapse = " | ")))
    }
  }

  rng <- summary_payload$rng
  lines <- c(
    lines,
    "",
    "## RNG gates",
    "",
    sprintf("- Same seed: **%s** (`%s` vs `%s`)", if (isTRUE(rng$details$same_seed$pass)) "PASS" else "FAIL",
            rng$details$same_seed$a$sha256 %||% "missing",
            rng$details$same_seed$b$sha256 %||% "missing"),
    sprintf("- Different seed: **%s** (`%s` vs `%s`)", if (isTRUE(rng$details$different_seed$pass)) "PASS" else "FAIL",
            rng$details$different_seed$a$sha256 %||% "missing",
            rng$details$different_seed$b$sha256 %||% "missing"),
    "",
    "## Regression",
    "",
    sprintf("- `tools/verify_summary_runtime_split.R`: status=%s exit_code=%s log=`%s`",
            if (isTRUE(summary_payload$regression$skipped)) "skipped"
            else if (isTRUE(summary_payload$regression$pass)) "pass"
            else "fail",
            as.character(summary_payload$regression$exit_code %||% "NA"),
            summary_payload$regression$log_path %||% ""),
    "",
    "## Failures",
    ""
  )

  if (length(summary_payload$failures) == 0) {
    lines <- c(lines, "- None")
  } else {
    lines <- c(lines, paste0("- ", summary_payload$failures))
  }

  lines <- c(lines, "", "## Warnings", "")
  if (length(summary_payload$warnings) == 0) {
    lines <- c(lines, "- None")
  } else {
    lines <- c(lines, paste0("- ", summary_payload$warnings))
  }

  writeLines(lines, con = path)
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--config"), type = "character", default = "config/validation/defaults.yaml"),
  make_option(c("--source_root"), type = "character", default = ""),
  make_option(c("--work_dir"), type = "character", default = ""),
  make_option(c("--report_dir"), type = "character", default = ""),
  make_option(c("--dry_run"), type = "character", default = "false"),
  make_option(c("--skip_fetch"), type = "character", default = "false"),
  make_option(c("--skip_regression"), type = "character", default = "false")
)))

config_path <- normalizePath(opt$config, winslash = "/", mustWork = TRUE)
config <- yaml::read_yaml(config_path)
source_root <- as.character(opt$source_root %||% "")
if (!nzchar(source_root)) source_root <- as.character(config$job$source_root %||% "")
if (!nzchar(source_root)) stop("A source root is required via --source_root or config job.source_root")
source_root <- if (startsWith(source_root, "gs://")) trim_trailing_slash(source_root) else normalizePath(source_root, winslash = "/", mustWork = FALSE)

work_dir <- as.character(opt$work_dir %||% "")
if (!nzchar(work_dir)) work_dir <- as.character(config$job$work_dir %||% file.path("outputs", "validation_remote", "work"))
if (!nzchar(work_dir)) work_dir <- as.character(config$output_locations$work_dir %||% "")
work_dir <- normalizePath(work_dir, winslash = "/", mustWork = FALSE)
report_dir <- as.character(opt$report_dir %||% "")
if (!nzchar(report_dir)) report_dir <- as.character(config$job$report_dir %||% file.path("outputs", "validation_remote", "report"))
if (!nzchar(report_dir)) report_dir <- as.character(config$output_locations$report_dir %||% "")
report_dir <- normalizePath(report_dir, winslash = "/", mustWork = FALSE)
staged_root <- file.path(work_dir, "staged")
dry_run <- parse_bool(opt$dry_run, default = FALSE)
skip_fetch <- parse_bool(opt$skip_fetch, default = FALSE)
skip_regression <- parse_bool(opt$skip_regression, default = FALSE)

ensure_dir(work_dir)
ensure_dir(report_dir)
if (!isTRUE(skip_fetch)) ensure_dir(staged_root)

source_plans <- list()
bundle_results <- list()
sources <- config$sources %||% list()

for (source in sources) {
  bundle_name <- as.character(source$name)
  source_path <- join_path_or_uri(source_root, as.character(source$path %||% bundle_name))
  staged_path <- file.path(staged_root, bundle_name)
  if (isTRUE(skip_fetch)) {
    staged_path <- if (startsWith(source_root, "gs://")) {
      stop("--skip_fetch requires a local source root, not gs://")
    } else {
      normalizePath(file.path(source_root, as.character(source$path %||% bundle_name)), winslash = "/", mustWork = TRUE)
    }
    source_plans[[bundle_name]] <- list(source = source_path, staged_path = staged_path, status = "using_local")
  } else {
    source_plans[[bundle_name]] <- stage_source(source_path, staged_path, dry_run = dry_run)
  }

  if (!isTRUE(dry_run)) {
    bundle_results[[bundle_name]] <- check_bundle(source, staged_path, config$checks)
  }
}

regression_cfg <- config$checks$regression %||% list()
regression_script <- normalizePath(as.character(regression_cfg$script %||% file.path("tools", "verify_summary_runtime_split.R")),
                                   winslash = "/", mustWork = TRUE)
regression <- run_regression_check(
  script_path = regression_script,
  report_dir = report_dir,
  dry_run = dry_run || skip_regression,
  enabled = parse_bool(regression_cfg$enabled %||% TRUE, default = TRUE)
)
if (isTRUE(skip_regression) && !isTRUE(dry_run)) regression$message <- "Regression skipped by CLI flag"

rng_result <- if (isTRUE(dry_run)) {
  list(pass = TRUE, failures = character(), details = list())
} else {
  run_rng_checks(config$checks, bundle_results, staged_root)
}

bundle_pass <- if (length(bundle_results) == 0) FALSE else all(vapply(bundle_results, `[[`, logical(1), "pass"))
artifact_completeness_pass <- bundle_pass
memory_runtime_pass <- bundle_pass
overall_pass <- all(c(
  artifact_completeness_pass,
  memory_runtime_pass,
  isTRUE(regression$pass),
  isTRUE(rng_result$pass)
))

failures <- character()
if (!artifact_completeness_pass) {
  failures <- c(failures, "One or more staged bundles failed completeness or profile checks")
}
warnings <- character()
for (bundle in bundle_results) {
  if (length(bundle$failures) > 0) {
    failures <- c(failures, paste0(bundle$name, ": ", bundle$failures))
  }
  if (length(bundle$warnings) > 0) {
    warnings <- c(warnings, paste0(bundle$name, ": ", bundle$warnings))
  }
}
if (!isTRUE(regression$pass)) failures <- c(failures, regression$message)
if (length(rng_result$failures) > 0) failures <- c(failures, rng_result$failures)

summary_payload <- list(
  generated_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  config_path = config_path,
  source_root = source_root,
  work_dir = work_dir,
  report_dir = report_dir,
  dry_run = isTRUE(dry_run),
  skip_fetch = isTRUE(skip_fetch),
  skip_regression = isTRUE(skip_regression),
  overall_pass = overall_pass,
  verdicts = list(
    artifact_completeness = artifact_completeness_pass,
    memory_runtime_profiles = memory_runtime_pass,
    summary_runtime_split = isTRUE(regression$pass),
    rng_same_seed = isTRUE(rng_result$details$same_seed$pass %||% rng_result$pass),
    rng_different_seed = isTRUE(rng_result$details$different_seed$pass %||% rng_result$pass)
  ),
  execution_contract = list(
    worker_count = 1L,
    artifact_mode = "summary_only",
    stochastic_charger_state_enabled = TRUE,
    rss_limit_mb = as.numeric(config$checks$memory$rss_limit_mb %||% NA_real_)
  ),
  staging = unname(source_plans),
  bundles = unname(bundle_results),
  regression = regression,
  rng = rng_result,
  warnings = unique(warnings),
  failures = unique(failures)
)

summary_json_path <- file.path(report_dir, "validation_summary.json")
report_md_path <- file.path(report_dir, "validation_report.md")
jsonlite::write_json(summary_payload, path = summary_json_path, pretty = TRUE, auto_unbox = TRUE, null = "null", na = "null")
render_markdown_report(summary_payload, report_md_path)

cat(summary_json_path, "\n", report_md_path, "\n", sep = "")
if (!isTRUE(overall_pass)) quit(status = 1)
