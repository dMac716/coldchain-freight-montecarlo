#!/usr/bin/env Rscript

run_mc_rscript <- function(cmd) {
  env_vars <- c(
    "OMP_NUM_THREADS=1",
    "OPENBLAS_NUM_THREADS=1",
    "MKL_NUM_THREADS=1",
    "VECLIB_MAXIMUM_THREADS=1",
    "R_DATATABLE_NUM_THREADS=1",
    "KMP_BLOCKTIME=0",
    "KMP_SETTINGS=0"
  )
  status <- system2("Rscript", args = cmd, env = env_vars, stdout = TRUE, stderr = TRUE)
  invisible(status)
}

resolve_repo_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    script_path <- normalizePath(sub("^--file=", "", file_arg[[1]]), winslash = "/", mustWork = TRUE)
    return(normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = TRUE))
  }

  cwd <- normalizePath(".", winslash = "/", mustWork = TRUE)
  if (file.exists(file.path(cwd, "tools", "run_route_sim_mc.R")) &&
      file.exists(file.path(cwd, "test_kit.yaml"))) {
    return(cwd)
  }

  normalizePath(file.path(cwd, ".."), winslash = "/", mustWork = TRUE)
}

repo_root <- resolve_repo_root()
td <- tempfile("summary_runtime_split_")
dir.create(td, recursive = TRUE)
bundle_root <- file.path(td, "run_bundle")
summary_out <- file.path(td, "summary.csv")
runtime_summary_out <- file.path(td, "runtime_summary.csv")
runs_out <- file.path(td, "runs.csv")
memory_summary_out <- file.path(td, "memory_summary.json")

cmd <- c(
  file.path(repo_root, "tools", "run_route_sim_mc.R"),
  "--config", file.path(repo_root, "test_kit.yaml"),
  "--scenario", "summary_runtime_split_regression",
  "--powertrain", "diesel",
  "--product_type", "dry",
  "--traffic_mode", "freeflow",
  "--facility_id", "FACILITY_DRY_TOPEKA",
  "--artifact_mode", "summary_only",
  "--n", "2",
  "--seed", "2855",
  "--bundle_root", bundle_root,
  "--summary_out", summary_out,
  "--runtime_summary_out", runtime_summary_out,
  "--memory_summary_out", memory_summary_out,
  "--runs_out", runs_out
)

status <- run_mc_rscript(cmd)
if (!is.null(attr(status, "status")) && attr(status, "status") != 0) {
  stop("summary/runtime split verification command failed")
}

summary_df <- utils::read.csv(summary_out, stringsAsFactors = FALSE)
runtime_df <- utils::read.csv(runtime_summary_out, stringsAsFactors = FALSE)
stopifnot(!"peak_rss_mb" %in% names(summary_df))
stopifnot(!"batch_wall_seconds" %in% names(summary_df))
stopifnot("peak_rss_mb" %in% names(runtime_df))
stopifnot("batch_wall_seconds" %in% names(runtime_df))
invisible(cat("summary/runtime split verification succeeded\n"))
