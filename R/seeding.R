# R/seeding.R
# Deterministic hierarchical seed derivation for publishable-research MC runs.
#
# Seed chain:
#   master_seed  (integer, experiment-wide, user-provided)
#       └─ shard_seed = derive_shard_seed(master_seed, shard_id)
#               └─ run_seed = derive_run_seed(shard_seed, run_id)
#
# All derivations use pure integer arithmetic — no RNG calls, no global state.
# The same inputs always produce the same seed on any platform.
# The formula is self-contained and can be reproduced in any language:
#
#   shard_seed = ((master_seed × 1000003) + (shard_id × 999983))  mod  INT_MAX  +  1
#   run_seed   = ((shard_seed  − 1) + (run_id − 1))                mod  INT_MAX  +  1
#
# where INT_MAX = .Machine$integer.max = 2147483647 (a Mersenne prime, 2^31 − 1).
# Because INT_MAX is prime, every multiplier 1 ≤ k < INT_MAX is coprime with it.
# This guarantees that different shard_ids always yield different shard_seeds
# (the mapping shard_id → shard_seed is a bijection on the residues mod INT_MAX).

# Prime multipliers for shard-level mixing.
# Two distinct primes reduce correlation between the master_seed and shard_id terms.
.SHARD_MIX_M <- 1000003   # applied to master_seed
.SHARD_MIX_S <- 999983    # applied to shard_id

# ---------------------------------------------------------------------------
# Shard level
# ---------------------------------------------------------------------------

#' Derive the seed for a single shard.
#'
#' O(1) arithmetic — no RNG, no global state.
#'
#' @param master_seed Integer. Experiment-wide seed.
#' @param shard_id    Integer >= 0. Zero-based shard index.
#' @return Integer in [1, .Machine$integer.max].
derive_shard_seed <- function(master_seed, shard_id) {
  stopifnot(is.numeric(master_seed), length(master_seed) == 1L, is.finite(master_seed))
  stopifnot(is.numeric(shard_id),   length(shard_id)   == 1L, shard_id >= 0)
  # Use as.numeric to avoid integer overflow before the mod operation.
  raw <- (as.numeric(master_seed) * .SHARD_MIX_M +
          as.numeric(shard_id)    * .SHARD_MIX_S) %% .Machine$integer.max
  as.integer(raw) + 1L
}

#' Derive seeds for all shards in one call.
#'
#' Vectorised wrapper around derive_shard_seed.
#'
#' @param master_seed Integer. Experiment-wide seed.
#' @param n_shards    Integer >= 1. Number of shards.
#' @return Named integer vector of length n_shards; names are "0", "1", ...
derive_shard_seeds <- function(master_seed, n_shards) {
  stopifnot(is.numeric(n_shards), length(n_shards) == 1L, n_shards >= 1L)
  n_shards <- as.integer(n_shards)
  ids      <- seq_len(n_shards) - 1L  # 0-indexed shard IDs
  seeds    <- vapply(ids, function(i) derive_shard_seed(master_seed, i), integer(1L))
  names(seeds) <- as.character(ids)
  seeds
}

# ---------------------------------------------------------------------------
# Run level
# ---------------------------------------------------------------------------

#' Derive the seed for a specific run within a shard.
#'
#' run_id is 1-based: run 1 receives shard_seed unchanged, run 2 receives
#' shard_seed + 1, etc., wrapping within [1, .Machine$integer.max].
#'
#' This formula is consistent with the existing run_chunk.R pattern
#' (seed_used = seed_base + variant_index - 1).
#'
#' @param shard_seed Integer. Shard-level seed from derive_shard_seed().
#' @param run_id     Integer >= 1. 1-based run index within the shard.
#' @return Integer in [1, .Machine$integer.max].
derive_run_seed <- function(shard_seed, run_id) {
  # Promote to numeric before adding to prevent silent integer overflow when
  # shard_seed is near .Machine$integer.max, then wrap back to [1, INT_MAX].
  raw <- as.numeric(shard_seed) + as.integer(run_id) - 1L
  as.integer(((raw - 1L) %% .Machine$integer.max) + 1L)
}

# Backward-compatible alias: run_chunk.R and existing tests use "variant" terminology.
derive_variant_seed <- derive_run_seed

# ---------------------------------------------------------------------------
# Seed provenance record
# ---------------------------------------------------------------------------

#' Build a seed provenance record for embedding in metadata files.
#'
#' The 'derivation' field is a self-contained R expression that reproduces
#' shard_seed from master_seed and shard_id using only arithmetic — no RNG.
#' It can be evaluated with eval(parse(text = provenance$derivation)).
#'
#' @param master_seed Integer. Experiment master seed.
#' @param shard_id    Integer >= 0. Zero-based shard index.
#' @param shard_seed  Integer. Derived shard seed (from derive_shard_seed()).
#' @param n_shards    Integer. Total shards in the experiment.
#' @return Named list suitable for jsonlite::toJSON().
build_seed_provenance <- function(master_seed, shard_id, shard_seed, n_shards) {
  derivation <- paste0(
    "as.integer(",
    "(as.numeric(", as.integer(master_seed), "L) * 1000003 + ",
    "as.numeric(",  as.integer(shard_id),    "L) * 999983) %% ",
    ".Machine$integer.max) + 1L"
  )
  list(
    master_seed       = as.integer(master_seed),
    shard_id          = as.integer(shard_id),
    shard_seed        = as.integer(shard_seed),
    n_shards          = as.integer(n_shards),
    rng_kind          = "Mersenne-Twister",  # kept for backward compatibility
    rng_normal_kind   = "Inversion",          # kept for backward compatibility
    derivation_method = "arithmetic",          # actual derivation method
    derivation        = derivation
  )
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

#' Verify that a shard seed can be reproduced from the experiment manifest.
#'
#' Recomputes the expected seed from manifest$master_seed and errors if it
#' does not match the stored value.  Use this for audit checks.
#'
#' @param manifest List. Parsed experiment_manifest.json (from jsonlite::fromJSON).
#' @param shard_id Integer >= 0. Zero-based shard index to verify.
#' @return Invisibly TRUE on success; stops on mismatch.
validate_shard_seed <- function(manifest, shard_id) {
  shard_id <- as.integer(shard_id)
  key      <- as.character(shard_id)

  # manifest$shard_seeds[[key]] returns NULL for a missing key; check before
  # calling as.integer() which silently converts NULL to integer(0).
  raw <- manifest$shard_seeds[[key]]
  if (is.null(raw)) {
    stop(sprintf("validate_shard_seed: shard_id %d not found in manifest", shard_id))
  }
  stored <- as.integer(raw)

  expected <- derive_shard_seed(manifest$master_seed, shard_id)
  if (!identical(stored, expected)) {
    stop(sprintf(
      "validate_shard_seed: shard_id %d seed mismatch — manifest has %d, derived %d",
      shard_id, stored, expected
    ))
  }
  invisible(TRUE)
}

#' Verify all shard seeds in an experiment manifest.
#'
#' Checks that n_shards is present, matches the actual seed count, and that
#' every seed can be reproduced from master_seed.
#'
#' @param manifest List. Parsed experiment_manifest.json.
#' @return Invisibly TRUE if all seeds verify; stops on first problem.
validate_all_shard_seeds <- function(manifest) {
  if (is.null(manifest$n_shards)) {
    stop("validate_all_shard_seeds: manifest is missing 'n_shards' field")
  }
  n_shards <- as.integer(manifest$n_shards)
  if (length(n_shards) != 1L || is.na(n_shards) || n_shards < 1L) {
    stop("validate_all_shard_seeds: manifest 'n_shards' must be a positive integer")
  }

  # n_shards must equal the actual seed count so no seeds are skipped silently.
  actual <- length(manifest$shard_seeds)
  if (actual != n_shards) {
    stop(sprintf(
      "validate_all_shard_seeds: n_shards=%d but %d seeds present in manifest",
      n_shards, actual
    ))
  }

  for (i in seq_len(n_shards) - 1L) {
    validate_shard_seed(manifest, i)
  }
  invisible(TRUE)
}
