#!/usr/bin/env Rscript
# scripts/run_shard.R
#
# Execute one shard of a parallel MC experiment.
#
# Loads experiment_manifest.json, looks up the shard_seed for the given
# shard_id, and calls tools/run_chunk.R as a subprocess with that seed.
# Captures stdout/stderr to per-shard log files and writes metadata.json
# and a _SUCCESS marker on clean completion.
#
# Must be run from the repository root (same requirement as run_chunk.R,
# which resolves R/ and data/ via relative paths).
#
# Usage:
#   Rscript scripts/run_shard.R \
#     --manifest   runs/my_exp/experiment_manifest.json \
#     --shard_id   3 \
#     --output_dir runs/my_exp/shards \
#     --scenario   CENTRALIZED \
#     --config_path data/inputs_local \
#     --mode       SMOKE_LOCAL
#
# Note on config_path: tools/run_chunk.R reads inputs via read_inputs_local(),
# which resolves data/ relative to the working directory.  config_path is
# stored in metadata.json for provenance but is not forwarded as a flag to
# run_chunk.R.  To use a non-default config directory, set it up at
# data/inputs_local before calling this script.

suppressPackageStartupMessages(library(optparse))
suppressPackageStartupMessages(library(jsonlite))

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
opt <- parse_args(OptionParser(
  description = "Run one shard of a parallel MC experiment.",
  option_list = list(
    make_option("--manifest",    type = "character",
                help = "Path to experiment_manifest.json (required)"),
    make_option("--shard_id",   type = "integer",
                help = "Zero-based shard index to run (required)"),
    make_option("--output_dir", type = "character",
                help = "Root directory for shard outputs (required)"),
    make_option("--scenario",   type = "character",
                help = "Scenario name passed to run_chunk.R (required)"),
    make_option("--config_path", type = "character", default = "data/inputs_local",
                help = "Config/inputs directory [default: data/inputs_local]"),
    make_option("--mode",       type = "character", default = "SMOKE_LOCAL",
                help = "Run mode: SMOKE_LOCAL or REAL_RUN [default: SMOKE_LOCAL]"),
    make_option("--force",      action = "store_true", default = FALSE,
                help = "Re-run even if _SUCCESS marker already exists")
  )
))

required <- c("manifest", "shard_id", "output_dir", "scenario")
missing  <- required[vapply(required, function(a) is.null(opt[[a]]), logical(1L))]
if (length(missing) > 0L)
  stop("Missing required arguments: ", paste0("--", missing, collapse = ", "))

# ---------------------------------------------------------------------------
# Load and validate the experiment manifest
# ---------------------------------------------------------------------------
if (!file.exists(opt$manifest))
  stop("Manifest not found: ", opt$manifest)

manifest <- tryCatch(
  fromJSON(opt$manifest, simplifyVector = FALSE),
  error = function(e) stop("Failed to parse manifest JSON: ", e$message)
)

required_fields <- c("experiment_id", "master_seed", "runs_per_shard", "shard_seeds")
missing_fields  <- required_fields[!required_fields %in% names(manifest)]
if (length(missing_fields) > 0L)
  stop("Manifest is missing fields: ", paste(missing_fields, collapse = ", "))

shard_key <- as.character(opt$shard_id)
if (is.null(manifest$shard_seeds[[shard_key]]))
  stop(sprintf("shard_id %d not found in manifest shard_seeds", opt$shard_id))

shard_seed      <- as.integer(manifest$shard_seeds[[shard_key]])
experiment_id   <- manifest$experiment_id
master_seed     <- as.integer(manifest$master_seed)
runs_per_shard  <- as.integer(manifest$runs_per_shard)

# ---------------------------------------------------------------------------
# Resolve shard output directory
# ---------------------------------------------------------------------------
shard_dir    <- file.path(opt$output_dir, sprintf("shard_%04d", opt$shard_id))
success_path <- file.path(shard_dir, "_SUCCESS")

if (file.exists(success_path) && !opt$force) {
  message(sprintf("shard %d already complete (%s exists). Pass --force to re-run.",
                  opt$shard_id, success_path))
  quit(status = 0L)
}

# On force, remove stale markers and logs so artifacts are not mixed across runs.
if (file.exists(success_path) && opt$force) {
  file.remove(success_path)
  for (f in c("stdout.log", "stderr.log", "metadata.json")) {
    p <- file.path(shard_dir, f)
    if (file.exists(p)) file.remove(p)
  }
  message(sprintf("shard %d: cleared stale artifacts (--force)", opt$shard_id))
}

dir.create(shard_dir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(shard_dir))
  stop("Failed to create shard directory: ", shard_dir)

stdout_log <- file.path(shard_dir, "stdout.log")
stderr_log <- file.path(shard_dir, "stderr.log")

# ---------------------------------------------------------------------------
# Locate run_chunk.R relative to this script, falling back to tools/
# ---------------------------------------------------------------------------
script_path <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) ""
)
repo_root <- if (nzchar(script_path)) dirname(dirname(script_path)) else getwd()
run_chunk  <- file.path(repo_root, "tools", "run_chunk.R")
if (!file.exists(run_chunk))
  stop("Cannot find tools/run_chunk.R at: ", run_chunk)

# run_chunk.R resolves R/ and data/ relative to CWD; ensure we are at repo root.
orig_wd <- getwd()
setwd(repo_root)
on.exit(setwd(orig_wd), add = TRUE)

# ---------------------------------------------------------------------------
# Write initial metadata (before the run so partial failures are diagnosable)
# ---------------------------------------------------------------------------
timestamp_start <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

write_metadata <- function(status) {
  meta <- list(
    experiment_id = experiment_id,
    master_seed   = master_seed,
    shard_id      = opt$shard_id,
    shard_seed    = shard_seed,
    scenario      = opt$scenario,
    config_path   = opt$config_path,
    mode          = opt$mode,
    runs_per_shard = runs_per_shard,
    status        = status,
    timestamp     = timestamp_start,
    completed_at  = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )
  write(toJSON(meta, auto_unbox = TRUE, pretty = TRUE),
        file = file.path(shard_dir, "metadata.json"))
}

write_metadata("running")

# ---------------------------------------------------------------------------
# Invoke run_chunk.R as a subprocess
# Stdout and stderr are captured to separate log files for diagnostics.
# ---------------------------------------------------------------------------
args <- c(
  "tools/run_chunk.R",
  "--scenario", opt$scenario,
  "--n",        as.character(runs_per_shard),
  "--seed",     as.character(shard_seed),
  "--outdir",   shard_dir,
  "--mode",     opt$mode
)

message(sprintf(
  "shard %d: starting run_chunk.R  seed=%d  n=%d  scenario=%s  mode=%s",
  opt$shard_id, shard_seed, runs_per_shard, opt$scenario, opt$mode
))

exit_code <- system2("Rscript", args = args, stdout = stdout_log, stderr = stderr_log)

# ---------------------------------------------------------------------------
# Record outcome
# ---------------------------------------------------------------------------
if (exit_code == 0L) {
  write_metadata("completed")
  writeLines(format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), success_path)
  message(sprintf("shard %d: completed successfully -> %s", opt$shard_id, shard_dir))
} else {
  write_metadata("failed")
  message(sprintf(
    "shard %d: run_chunk.R exited with code %d. See %s",
    opt$shard_id, exit_code, stderr_log
  ))
  quit(status = 1L)
}
