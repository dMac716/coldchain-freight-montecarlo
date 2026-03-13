# R/log_helpers.R
#
# Reusable structured logging for R entrypoints.
#
# This file is auto-sourced by any tool that does:
#   list.files("R", pattern="\\.R$", full.names = TRUE)
# (which includes run_chunk.R, run_local.R, aggregate.R, etc.)
#
# For scripts that do NOT auto-source R/, call explicitly:
#   source("R/log_helpers.R")
#
# Structured log format (grep-friendly, append-safe):
#   [ISO-8601-UTC] [tag] run_id="..." lane="..." seed="..." phase="..." status="..." msg="..."
#
# Usage:
#   configure_log(run_id = "my_run", lane = "local", seed = "42", tag = "my_tool")
#   log_event("INFO",  "start",   "Beginning simulation")
#   log_event("WARN",  "validate","Input file has extra columns")
#   log_event("ERROR", "run",     "Monte Carlo failed")
#
# Environment variables read (all optional, fall back to defaults):
#   COLDCHAIN_RUN_ID    run identifier (default: unknown)
#   COLDCHAIN_LANE      compute lane   (default: local)
#   COLDCHAIN_SEED      random seed    (default: unknown)
#   COLDCHAIN_LOG_TAG   source tag     (default: R)
#   COLDCHAIN_RUN_LOG   path to log file; auto-derived from runs/<run_id>/run.log if set

.coldchain_log_env <- new.env(parent = emptyenv())
.coldchain_log_env$run_id   <- Sys.getenv("COLDCHAIN_RUN_ID", unset = "unknown")
.coldchain_log_env$lane     <- Sys.getenv("COLDCHAIN_LANE",   unset = "local")
.coldchain_log_env$seed     <- Sys.getenv("COLDCHAIN_SEED",   unset = "unknown")
.coldchain_log_env$tag      <- Sys.getenv("COLDCHAIN_LOG_TAG", unset = "R")
.coldchain_log_env$log_path <- Sys.getenv("COLDCHAIN_RUN_LOG", unset = "")


configure_log <- function(run_id   = NULL,
                          lane     = NULL,
                          seed     = NULL,
                          tag      = NULL,
                          log_path = NULL) {
  if (!is.null(run_id))   .coldchain_log_env$run_id   <- as.character(run_id)
  if (!is.null(lane))     .coldchain_log_env$lane     <- as.character(lane)
  if (!is.null(seed))     .coldchain_log_env$seed     <- as.character(seed)
  if (!is.null(tag))      .coldchain_log_env$tag      <- as.character(tag)
  if (!is.null(log_path)) .coldchain_log_env$log_path <- as.character(log_path)
  invisible(NULL)
}


log_event <- function(level = "INFO", phase = "unknown", msg = "") {
  ts     <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  run_id <- .coldchain_log_env$run_id
  lane   <- .coldchain_log_env$lane
  seed   <- .coldchain_log_env$seed
  tag    <- .coldchain_log_env$tag

  entry <- sprintf(
    '[%s] [%s] run_id="%s" lane="%s" seed="%s" phase="%s" status="%s" msg="%s"',
    ts, tag, run_id, lane, seed, phase, level, msg
  )
  cat(entry, "\n", sep = "")

  log_path <- .coldchain_log_env$log_path
  if (!nzchar(log_path) && run_id != "unknown") {
    candidate <- file.path("runs", run_id, "run.log")
    if (dir.exists(dirname(candidate))) log_path <- candidate
  }
  if (nzchar(log_path)) {
    cat(entry, "\n", sep = "", file = log_path, append = TRUE)
  }

  invisible(entry)
}
