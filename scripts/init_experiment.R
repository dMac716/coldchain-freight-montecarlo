#!/usr/bin/env Rscript
# scripts/init_experiment.R
#
# Initialise a parallel MC experiment.
#
# Derives deterministic shard seeds from master_seed and writes a single
# experiment_manifest.json.  Does not run any simulations.
#
# Usage:
#   Rscript scripts/init_experiment.R \
#     --experiment_id my_run_001   \
#     --master_seed   42           \
#     --shard_count   8            \
#     --runs_per_shard 5000        \
#     --scenario      CENTRALIZED  \
#     --output_dir    runs
#
# Idempotency: re-running with the same arguments skips the write (exit 0).
# Pass --force to overwrite an existing manifest.

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

# ---------------------------------------------------------------------------
# Source only R/seeding.R — the one dependency this script needs.
# Locate it relative to this script, then fall back to the working directory.
# ---------------------------------------------------------------------------
script_path <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) ""
)
r_dir <- if (nzchar(script_path)) file.path(dirname(dirname(script_path)), "R") else "R"
seeding_file <- file.path(r_dir, "seeding.R")
if (!file.exists(seeding_file)) stop("Cannot find R/seeding.R at: ", seeding_file)
source(seeding_file, local = FALSE)

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
opt <- parse_args(OptionParser(
  description = "Initialise a parallel MC experiment.",
  option_list = list(
    make_option("--experiment_id",  type = "character", help = "Unique experiment identifier (required)"),
    make_option("--master_seed",    type = "integer",   help = "Master RNG seed (required)"),
    make_option("--shard_count",    type = "integer",   help = "Number of shards (required)"),
    make_option("--runs_per_shard", type = "integer",   help = "MC draws per shard (required)"),
    make_option("--scenario",       type = "character", help = "Scenario name, e.g. CENTRALIZED (required)"),
    make_option("--output_dir",     type = "character", default = "runs",
                help = "Root output directory [default: runs]"),
    make_option("--force", action = "store_true", default = FALSE,
                help = "Overwrite an existing manifest")
  )
))

# Validate required arguments before any work begins.
required <- c("experiment_id", "master_seed", "shard_count", "runs_per_shard", "scenario")
missing  <- required[vapply(required, function(a) is.null(opt[[a]]), logical(1L))]
if (length(missing) > 0L) stop("Missing required arguments: ", paste0("--", missing, collapse = ", "))

if (opt$shard_count    < 1L) stop("--shard_count must be >= 1")
if (opt$runs_per_shard < 1L) stop("--runs_per_shard must be >= 1")

# ---------------------------------------------------------------------------
# Resolve output path
# ---------------------------------------------------------------------------
experiment_dir <- file.path(opt$output_dir, opt$experiment_id)
manifest_path  <- file.path(experiment_dir, "experiment_manifest.json")

if (file.exists(manifest_path) && !opt$force) {
  message("Manifest already exists at ", manifest_path, " — pass --force to overwrite.")
  quit(status = 0L)
}

dir.create(experiment_dir, recursive = TRUE, showWarnings = FALSE)

# ---------------------------------------------------------------------------
# Derive shard seeds
# derive_shard_seeds() is pure arithmetic — no RNG state is touched.
# ---------------------------------------------------------------------------
shard_seeds <- derive_shard_seeds(opt$master_seed, opt$shard_count)
# Named integer vector: names "0", "1", ..., "N-1" (zero-based shard IDs)

shard_ids <- as.integer(names(shard_seeds))  # 0, 1, ..., shard_count - 1

# ---------------------------------------------------------------------------
# Capture reproducibility metadata
# ---------------------------------------------------------------------------
git_sha <- tryCatch(
  trimws(system2("git", c("rev-parse", "--short", "HEAD"),
                 stdout = TRUE, stderr = FALSE)[[1L]]),
  error   = function(e) "unknown",
  warning = function(e) "unknown"
)
if (length(git_sha) == 0L || is.na(git_sha)) git_sha <- "unknown"

# ---------------------------------------------------------------------------
# Build and write manifest
# ---------------------------------------------------------------------------
manifest <- list(
  experiment_id  = opt$experiment_id,
  master_seed    = opt$master_seed,
  shard_count    = opt$shard_count,
  runs_per_shard = opt$runs_per_shard,
  scenario       = opt$scenario,
  shard_ids      = shard_ids,
  shard_seeds    = as.list(shard_seeds),
  timestamp      = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  git_sha        = git_sha,
  r_version      = paste(R.version$major, R.version$minor, sep = ".")
)

write(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), file = manifest_path)
message("Manifest written to ", manifest_path)
