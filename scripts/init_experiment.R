#!/usr/bin/env Rscript
# scripts/init_experiment.R
#
# Initialise a new parallel MC experiment.
#
# Responsibilities:
#   1. Derive deterministic shard seeds from master_seed.
#   2. Write one experiment_manifest.json under <output_dir>/<experiment_id>/.
#   3. Exit cleanly with no simulation work performed.
#
# Idempotency:
#   Re-running with the same arguments skips the write and exits 0.
#   Pass --force to overwrite an existing manifest.
#
# Usage:
#   Rscript scripts/init_experiment.R \
#     --experiment_id my_run_001 \
#     --master_seed   42         \
#     --shard_count   8          \
#     --runs_per_shard 5000      \
#     --scenario      CENTRALIZED \
#     --output_dir    runs

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

# ---------------------------------------------------------------------------
# Source R/ helpers (seeding.R, log_helpers.R, and any other modules present).
# Sourcing the whole directory mirrors the pattern used by run_chunk.R.
# ---------------------------------------------------------------------------
# Locate R/ relative to this script's own path, then fall back to the working
# directory (which is the repo root when invoked via Rscript scripts/...).
script_path <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) ""
)
r_dir <- if (nzchar(script_path)) {
  file.path(dirname(dirname(script_path)), "R")   # scripts/../R
} else {
  "R"  # run from repo root
}
if (!dir.exists(r_dir)) r_dir <- "R"
for (f in list.files(r_dir, pattern = "\\.R$", full.names = TRUE)) {
  source(f, local = FALSE)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
option_list <- list(
  make_option("--experiment_id",  type = "character", help = "Unique experiment identifier (required)"),
  make_option("--master_seed",    type = "integer",   help = "Master RNG seed for the experiment (required)"),
  make_option("--shard_count",    type = "integer",   help = "Number of shards to create (required)"),
  make_option("--runs_per_shard", type = "integer",   help = "MC draws per shard (required)"),
  make_option("--scenario",       type = "character", help = "Scenario identifier, e.g. CENTRALIZED (required)"),
  make_option("--output_dir",     type = "character", default = "runs",
              help = "Root output directory [default: runs]"),
  make_option("--force",          action = "store_true", default = FALSE,
              help = "Overwrite an existing manifest")
)

opt <- parse_args(OptionParser(
  option_list  = option_list,
  description  = "Initialise a parallel MC experiment and write experiment_manifest.json."
))

# Validate required args early so the error is clear.
required <- c("experiment_id", "master_seed", "shard_count", "runs_per_shard", "scenario")
missing  <- required[vapply(required, function(a) is.null(opt[[a]]), logical(1L))]
if (length(missing) > 0L) {
  stop("Missing required arguments: ", paste0("--", missing, collapse = ", "))
}

if (opt$shard_count < 1L)    stop("--shard_count must be >= 1")
if (opt$runs_per_shard < 1L) stop("--runs_per_shard must be >= 1")

# ---------------------------------------------------------------------------
# Configure structured logging (uses log_helpers.R if sourced above).
# Falls back gracefully when the helper is unavailable.
# ---------------------------------------------------------------------------
if (exists("configure_log")) {
  configure_log(
    run_id = opt$experiment_id,
    lane   = Sys.getenv("COLDCHAIN_LANE", unset = "local"),
    seed   = as.character(opt$master_seed),
    tag    = "init_experiment"
  )
}

emit <- function(level, phase, msg) {
  if (exists("log_event")) {
    log_event(level, phase, msg)
  } else {
    ts <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    cat(sprintf("[%s] [init_experiment] phase=%s status=%s msg=%s\n", ts, phase, level, msg))
  }
}

emit("INFO", "start", sprintf(
  "init_experiment: experiment_id=%s master_seed=%d shard_count=%d runs_per_shard=%d scenario=%s",
  opt$experiment_id, opt$master_seed, opt$shard_count, opt$runs_per_shard, opt$scenario
))

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
experiment_dir  <- file.path(opt$output_dir, opt$experiment_id)
manifest_path   <- file.path(experiment_dir, "experiment_manifest.json")

# Idempotency: skip if already initialised.
if (file.exists(manifest_path) && !opt$force) {
  emit("INFO", "skip", sprintf(
    "manifest already exists at %s — pass --force to overwrite", manifest_path
  ))
  quit(status = 0L)
}

dir.create(experiment_dir, recursive = TRUE, showWarnings = FALSE)

# ---------------------------------------------------------------------------
# Derive shard seeds.
# derive_shard_seeds() is pure: it snapshots and restores the global RNG so
# calling this function has no side-effects on subsequent code.
# ---------------------------------------------------------------------------
shard_seeds <- derive_shard_seeds(opt$master_seed, opt$shard_count)
# shard_seeds is a named integer vector: names "0", "1", ..., "N-1"

emit("INFO", "seeding", sprintf(
  "derived %d shard seeds from master_seed=%d", opt$shard_count, opt$master_seed
))

# ---------------------------------------------------------------------------
# Capture reproducibility metadata
# ---------------------------------------------------------------------------
git_sha <- tryCatch(
  trimws(system2("git", c("rev-parse", "--short", "HEAD"),
                 stdout = TRUE, stderr = FALSE)[1L]),
  error   = function(e) "unknown",
  warning = function(e) "unknown"
)
if (length(git_sha) == 0L || is.na(git_sha)) git_sha <- "unknown"

r_version <- paste(R.version$major, R.version$minor, sep = ".")

# ---------------------------------------------------------------------------
# Build and write the manifest.
#
# The manifest is the single source of truth for this experiment's seed chain.
# Every shard runner reads its shard_seed from here; it never recomputes seeds.
# ---------------------------------------------------------------------------
manifest <- list(
  experiment_id  = opt$experiment_id,
  scenario       = opt$scenario,
  master_seed    = opt$master_seed,
  shard_count    = opt$shard_count,
  runs_per_shard = opt$runs_per_shard,
  # shard_seeds: named object so shard runners can look up by shard_id string.
  shard_seeds    = as.list(shard_seeds),
  rng_kind       = "Mersenne-Twister",
  rng_normal_kind = "Inversion",
  status         = "initialized",
  created_at     = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  git_sha        = git_sha,
  r_version      = r_version
)

write(
  toJSON(manifest, auto_unbox = TRUE, pretty = TRUE),
  file = manifest_path
)

emit("INFO", "complete", sprintf("manifest written to %s", manifest_path))
