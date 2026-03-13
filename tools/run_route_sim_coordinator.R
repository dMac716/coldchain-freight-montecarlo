#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(parallel)
})

script_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- if (length(script_file_arg) > 0) sub("^--file=", "", script_file_arg[[1]]) else "tools/run_route_sim_coordinator.R"
script_path <- normalizePath(script_path, winslash = "/", mustWork = TRUE)
script_dir <- dirname(script_path)
repo_root <- normalizePath(file.path(script_dir, ".."), winslash = "/", mustWork = TRUE)

resolve_repo_path <- function(path, kind = c("file", "dir"), must_work = TRUE) {
  kind <- match.arg(kind)
  raw <- trimws(as.character(path))
  if (!nzchar(raw)) return(raw)
  expanded <- path.expand(raw)
  is_absolute <- grepl("^(/|[A-Za-z]:[/\\\\])", expanded)
  candidates <- unique(c(expanded, if (!is_absolute) file.path(repo_root, raw) else NULL))
  exists_fn <- if (identical(kind, "dir")) dir.exists else file.exists
  for (candidate in candidates) {
    if (exists_fn(candidate)) {
      return(normalizePath(candidate, winslash = "/", mustWork = TRUE))
    }
  }
  if (isTRUE(must_work)) {
    stop(
      sprintf(
        "%s not found: %s. Checked: %s",
        tools::toTitleCase(kind),
        raw,
        paste(candidates, collapse = ", ")
      )
    )
  }
  normalizePath(candidates[[length(candidates)]], winslash = "/", mustWork = FALSE)
}

# Keep BLAS/OpenMP from oversubscribing shared hosts.
Sys.setenv(
  OMP_NUM_THREADS = "1",
  OPENBLAS_NUM_THREADS = "1",
  MKL_NUM_THREADS = "1",
  VECLIB_MAXIMUM_THREADS = "1",
  NUMEXPR_NUM_THREADS = "1"
)

source_files <- c(
  list.files(file.path(repo_root, "R"), pattern = "\\.R$", full.names = TRUE),
  list.files(file.path(repo_root, "R", "io"), pattern = "\\.R$", full.names = TRUE),
  list.files(file.path(repo_root, "R", "sim"), pattern = "\\.R$", full.names = TRUE)
)
for (f in source_files) source(f, local = FALSE)

read_cfg <- function(path) {
  if (!requireNamespace("yaml", quietly = TRUE)) stop("yaml package required for route sim config")
  y <- yaml::read_yaml(path)
  if (!is.null(y$test_kit)) y$test_kit else y
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--config"), type = "character", default = "test_kit.yaml"),
  make_option(c("--routes"), type = "character", default = ""),
  make_option(c("--elevation"), type = "character", default = "data/derived/route_elevation_profiles.csv"),
  make_option(c("--facility_id"), type = "character", default = "FACILITY_REFRIG_ENNIS"),
  make_option(c("--scenario"), type = "character", default = "route_sim_demo"),
  make_option(c("--powertrain"), type = "character", default = "bev"),
  make_option(c("--trip_leg"), type = "character", default = "outbound"),
  make_option(c("--n"), type = "integer", default = 100L),
  make_option(c("--seed"), type = "integer", default = 123),
  make_option(c("--workers"), type = "integer", default = 4L),
  make_option(c("--confirm_heavy"), type = "character", default = "true"),
  make_option(c("--worker_nice"), type = "integer", default = 10L),
  make_option(c("--worker_throttle_seconds"), type = "double", default = 0),
  make_option(c("--poll_seconds"), type = "double", default = 5),
  make_option(c("--stall_seconds"), type = "double", default = 180),
  make_option(c("--max_retries"), type = "integer", default = 1L),
  make_option(c("--stations"), type = "character", default = ""),
  make_option(c("--plans"), type = "character", default = ""),
  make_option(c("--charger_state_case"), type = "character", default = ""),
  make_option(c("--memory_limit_mb"), type = "double", default = NA_real_),
  make_option(c("--memory_log_every_runs"), type = "integer", default = NA_integer_),
  make_option(c("--gc_every_runs"), type = "integer", default = NA_integer_),
  make_option(c("--summary_out"), type = "character", default = "outputs/summaries/route_sim_summary.csv"),
  make_option(c("--runs_out"), type = "character", default = "outputs/summaries/route_sim_runs.csv")
)))

opt$config <- resolve_repo_path(opt$config, kind = "file", must_work = TRUE)
if (nzchar(opt$routes)) opt$routes <- resolve_repo_path(opt$routes, kind = "file", must_work = TRUE)
if (nzchar(opt$elevation)) opt$elevation <- resolve_repo_path(opt$elevation, kind = "file", must_work = FALSE)
if (nzchar(opt$stations)) opt$stations <- resolve_repo_path(opt$stations, kind = "file", must_work = TRUE)
if (nzchar(opt$plans)) opt$plans <- resolve_repo_path(opt$plans, kind = "file", must_work = TRUE)

cfg <- read_cfg(opt$config)
workers <- max(1L, as.integer(opt$workers))
confirm_heavy <- tolower(as.character(opt$confirm_heavy %||% "true")) %in% c("1", "true", "yes", "y")

if (confirm_heavy &&
    should_prompt_heavy_run(as.integer(opt$n), workers) &&
    interactive() &&
    sink.number() == 0) {
  cat(sprintf(
    "This run is heavy (n=%d, workers=%d, nice=%d). Continue? [y/N]: ",
    as.integer(opt$n), workers, as.integer(opt$worker_nice)
  ))
  ans <- tryCatch(readLines("stdin", n = 1), error = function(e) "")
  if (!(tolower(trimws(ans)) %in% c("y", "yes"))) {
    stop("Cancelled by user before launching heavy run.")
  }
}

counts <- split_work_counts(as.integer(opt$n), workers)
starts <- worker_seed_offsets(counts, as.integer(opt$seed))

run_stamp <- format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC")
coord_dir <- file.path(repo_root, "outputs", "coordinator", paste0(opt$scenario, "_", tolower(opt$powertrain), "_", run_stamp))
dir.create(coord_dir, recursive = TRUE, showWarnings = FALSE)

mk_args <- function(worker_id, worker_n, worker_seed, worker_summary, worker_runs, worker_progress) {
  args <- c(
    file.path(repo_root, "tools", "run_route_sim_mc.R"),
    "--config", opt$config,
    "--elevation", opt$elevation,
    "--facility_id", opt$facility_id,
    "--scenario", opt$scenario,
    "--powertrain", tolower(opt$powertrain),
    "--trip_leg", tolower(opt$trip_leg),
    "--n", as.character(worker_n),
    "--seed", as.character(worker_seed),
    "--summary_out", worker_summary,
    "--runs_out", worker_runs,
    "--progress_file", worker_progress,
    "--worker_label", paste0("w", worker_id),
    "--throttle_seconds", as.character(as.numeric(opt$worker_throttle_seconds))
  )
  if (nzchar(opt$routes)) args <- c(args, "--routes", opt$routes)
  if (nzchar(opt$stations)) args <- c(args, "--stations", opt$stations)
  if (nzchar(opt$plans)) args <- c(args, "--plans", opt$plans)
  if (nzchar(opt$charger_state_case)) args <- c(args, "--charger_state_case", opt$charger_state_case)
  if (is.finite(as.numeric(opt$memory_limit_mb))) args <- c(args, "--memory_limit_mb", as.character(opt$memory_limit_mb))
  if (is.finite(as.numeric(opt$memory_log_every_runs)) && as.integer(opt$memory_log_every_runs) > 0L) args <- c(args, "--memory_log_every_runs", as.character(as.integer(opt$memory_log_every_runs)))
  if (is.finite(as.numeric(opt$gc_every_runs)) && as.integer(opt$gc_every_runs) > 0L) args <- c(args, "--gc_every_runs", as.character(as.integer(opt$gc_every_runs)))
  args
}

launch_worker <- function(w) {
  w$attempt <- w$attempt + 1L
  w$status <- "RUNNING"
  worker_log <- file.path(coord_dir, sprintf("worker_%02d_attempt_%02d.log", w$id, w$attempt))
  args <- mk_args(w$id, w$n, w$seed, w$summary_path, w$runs_path, w$progress_path)
  nice_args <- c("-n", as.character(as.integer(opt$worker_nice)), "Rscript", args)
  job <- parallel::mcparallel({
    code <- system2("nice", args = nice_args, stdout = worker_log, stderr = worker_log)
    list(code = code, log = worker_log)
  }, silent = TRUE)
  w$job <- job
  w$pid <- as.integer(job$pid)
  w$last_i <- 0L
  w
}

workers_tbl <- list()
for (i in seq_len(workers)) {
  if (counts[[i]] <= 0) next
  workers_tbl[[length(workers_tbl) + 1L]] <- list(
    id = i,
    n = counts[[i]],
    seed = starts[[i]],
    attempt = 0L,
    status = "PENDING",
    pid = NA_integer_,
    job = NULL,
    last_i = 0L,
    summary_path = file.path(coord_dir, sprintf("worker_%02d_summary.csv", i)),
    runs_path = file.path(coord_dir, sprintf("worker_%02d_runs.csv", i)),
    progress_path = file.path(coord_dir, sprintf("worker_%02d_progress.csv", i))
  )
}

if (length(workers_tbl) == 0) stop("No work to run. Increase --n.")

for (i in seq_along(workers_tbl)) workers_tbl[[i]] <- launch_worker(workers_tbl[[i]])
cat("Coordinator started", length(workers_tbl), "workers in", coord_dir, "\n")

pid_to_idx <- function(pid) {
  idx <- which(vapply(workers_tbl, function(w) !is.null(w$job) && identical(as.integer(w$job$pid), as.integer(pid)), logical(1)))
  if (length(idx) == 0) NA_integer_ else idx[[1]]
}

all_done <- function() {
  all(vapply(workers_tbl, function(w) w$status %in% c("DONE", "FAILED"), logical(1)))
}

while (!all_done()) {
  Sys.sleep(as.numeric(opt$poll_seconds))

  jobs <- Filter(Negate(is.null), lapply(workers_tbl, function(w) w$job))
  collected <- if (length(jobs) > 0) parallel::mccollect(jobs, wait = FALSE) else NULL
  if (!is.null(collected) && length(collected) > 0) {
    for (pid_chr in names(collected)) {
      pid <- as.integer(pid_chr)
      idx <- pid_to_idx(pid)
      if (is.na(idx)) next
      res <- collected[[pid_chr]]
      code <- if (inherits(res, "try-error")) 1L else as.integer(res$code %||% 1L)
      if (identical(code, 0L)) {
        workers_tbl[[idx]]$status <- "DONE"
        workers_tbl[[idx]]$job <- NULL
      } else {
        if (workers_tbl[[idx]]$attempt <= as.integer(opt$max_retries)) {
          workers_tbl[[idx]]$status <- "RETRYING"
          workers_tbl[[idx]] <- launch_worker(workers_tbl[[idx]])
          cat(sprintf("Worker w%d failed (exit=%d). Relaunched attempt %d.\n", workers_tbl[[idx]]$id, code, workers_tbl[[idx]]$attempt))
        } else {
          workers_tbl[[idx]]$status <- "FAILED"
          workers_tbl[[idx]]$job <- NULL
          cat(sprintf("Worker w%d failed after retries.\n", workers_tbl[[idx]]$id))
        }
      }
    }
  }

  now <- Sys.time()
  for (i in seq_along(workers_tbl)) {
    w <- workers_tbl[[i]]
    if (!identical(w$status, "RUNNING") && !identical(w$status, "RETRYING")) next

    prog <- read_progress_status(w$progress_path)
    if (!is.null(prog) && is.finite(prog$i)) workers_tbl[[i]]$last_i <- prog$i

    if (is_stalled(prog, now_utc = now, stall_seconds = as.numeric(opt$stall_seconds))) {
      cat(sprintf("Worker w%d appears stalled at i=%s. Killing pid %s.\n", w$id, as.character(prog$i), as.character(w$pid)))
      if (!is.na(w$pid)) system2("kill", args = c("-9", as.character(w$pid)))
      workers_tbl[[i]]$job <- NULL
      if (workers_tbl[[i]]$attempt <= as.integer(opt$max_retries)) {
        workers_tbl[[i]]$status <- "RETRYING"
        workers_tbl[[i]] <- launch_worker(workers_tbl[[i]])
        cat(sprintf("Worker w%d relaunched after stall, attempt %d.\n", workers_tbl[[i]]$id, workers_tbl[[i]]$attempt))
      } else {
        workers_tbl[[i]]$status <- "FAILED"
        cat(sprintf("Worker w%d marked FAILED after stall retries.\n", workers_tbl[[i]]$id))
      }
    }
  }

  status_line <- vapply(workers_tbl, function(w) sprintf("w%d:%s(%d/%d)", w$id, w$status, w$last_i, w$n), character(1))
  cat("[coordinator]", paste(status_line, collapse = " | "), "\n")
}

failed <- vapply(workers_tbl, function(w) identical(w$status, "FAILED"), logical(1))
if (any(failed)) {
  stop("One or more workers failed. See logs under ", coord_dir)
}

run_files <- vapply(workers_tbl, function(w) w$runs_path, character(1))
run_files <- run_files[file.exists(run_files)]
if (length(run_files) == 0) stop("No worker run files found under ", coord_dir)

runs <- do.call(rbind, lapply(run_files, function(p) utils::read.csv(p, stringsAsFactors = FALSE)))
summary_df <- summarize_route_sim_runs(runs)
dir.create(dirname(opt$runs_out), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(opt$summary_out), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(runs, opt$runs_out, row.names = FALSE)
utils::write.csv(summary_df, opt$summary_out, row.names = FALSE)
cat("Wrote", opt$runs_out, "\n")
cat("Wrote", opt$summary_out, "\n")
cat("Coordinator artifacts:", coord_dir, "\n")
