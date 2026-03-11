# R/seeding.R
# Deterministic hierarchical seed derivation for publishable-research MC runs.
#
# Seed chain:
#   master_seed  (experiment-level, user-provided integer)
#     └─ shard_seed[i]  derived via set.seed(master_seed) + sample.int (at init time)
#          └─ variant_seed[j] = shard_seed[i] + (j - 1)   (run_shard.R inner loop)
#
# All shard seeds are pre-derived in a single RNG pass and stored in
# experiment_manifest.json.  run_shard.R reads from the manifest — it never
# recomputes seeds independently — making the full provenance auditable.

# ---------------------------------------------------------------------------
# Derive shard seeds from master seed
# ---------------------------------------------------------------------------

#' Derive one seed per shard from master_seed.
#'
#' Uses R's default Mersenne-Twister + Inversion-method RNG, seeded
#' deterministically from master_seed, then draws n_shards unique integers.
#' The same master_seed + n_shards always produces the same vector.
#' Different shard indices get different seeds; different master_seeds produce
#' entirely different seed sets.
#'
#' @param master_seed Integer. Experiment-level RNG seed.
#' @param n_shards    Integer. Number of shards to derive seeds for (>= 1).
#' @return Named integer vector of length n_shards; names are "0", "1", ...
derive_shard_seeds <- function(master_seed, n_shards) {
  stopifnot(is.numeric(master_seed), length(master_seed) == 1L,
            is.finite(master_seed))
  stopifnot(is.numeric(n_shards), length(n_shards) == 1L,
            n_shards >= 1L)

  master_seed <- as.integer(master_seed)
  n_shards    <- as.integer(n_shards)

  # Snapshot and restore the caller's RNG state so this function is pure.
  # .Random.seed does not exist in a fresh R session until the first RNG call,
  # so we must guard the read with exists().
  rng_existed <- exists(".Random.seed", envir = globalenv(), inherits = FALSE)
  old_rng     <- if (rng_existed) .Random.seed else NULL
  on.exit({
    if (rng_existed) {
      assign(".Random.seed", old_rng, envir = globalenv())
    } else {
      # Clean up the state that set.seed() created so callers see a fresh session.
      suppressWarnings(rm(".Random.seed", envir = globalenv()))
    }
  })

  set.seed(master_seed, kind = "Mersenne-Twister", normal.kind = "Inversion")
  seeds <- sample.int(.Machine$integer.max, n_shards, replace = FALSE)

  names(seeds) <- as.character(seq_len(n_shards) - 1L)  # 0-indexed shard IDs
  seeds
}

# ---------------------------------------------------------------------------
# Derive the seed for a specific shard
# ---------------------------------------------------------------------------

#' Derive the seed for a single shard.
#'
#' Calls derive_shard_seeds(master_seed, shard_id + 1) and returns the last
#' element.  Because Mersenne-Twister has no skip-ahead, all preceding seeds
#' are generated and discarded; for large shard_id this is O(shard_id).
#'
#' @param master_seed Integer. Experiment-level RNG seed.
#' @param shard_id    Integer >= 0. Zero-based shard index.
#' @return Single integer seed for this shard.
derive_shard_seed <- function(master_seed, shard_id) {
  shard_id <- as.integer(shard_id)
  stopifnot(shard_id >= 0L)
  all_seeds <- derive_shard_seeds(master_seed, shard_id + 1L)
  unname(all_seeds[shard_id + 1L])
}

# ---------------------------------------------------------------------------
# Derive the per-variant seed within a shard
# ---------------------------------------------------------------------------

#' Derive the seed for a specific variant within a shard.
#'
#' Consistent with the existing run_chunk.R pattern:
#'   variant_seed = shard_seed + (variant_index - 1)
#' variant_index is 1-based (first variant = index 1).
#'
#' @param shard_seed    Integer. Shard-level seed from derive_shard_seed().
#' @param variant_index Integer >= 1. 1-based index of the variant in the loop.
#' @return Integer seed for this variant.
derive_variant_seed <- function(shard_seed, variant_index) {
  # Promote to numeric before adding to prevent silent integer overflow when
  # shard_seed is near .Machine$integer.max, then wrap to [1, INT_MAX].
  raw <- as.numeric(shard_seed) + as.integer(variant_index) - 1L
  as.integer(((raw - 1L) %% .Machine$integer.max) + 1L)
}

# ---------------------------------------------------------------------------
# Seed provenance record
# ---------------------------------------------------------------------------

#' Build a seed provenance record for embedding in metadata files.
#'
#' @param master_seed  Integer. Experiment master seed.
#' @param shard_id     Integer >= 0. Zero-based shard index.
#' @param shard_seed   Integer. Derived shard seed.
#' @param n_shards     Integer. Total shards in the experiment.
#' @return Named list suitable for jsonlite::toJSON().
build_seed_provenance <- function(master_seed, shard_id, shard_seed, n_shards) {
  list(
    master_seed     = as.integer(master_seed),
    shard_id        = as.integer(shard_id),
    shard_seed      = as.integer(shard_seed),
    n_shards        = as.integer(n_shards),
    rng_kind        = "Mersenne-Twister",
    rng_normal_kind = "Inversion",
    derivation      = paste0(
      "set.seed(", master_seed, ", kind='Mersenne-Twister', normal.kind='Inversion'); ",
      "sample.int(.Machine$integer.max, ", shard_id + 1L, ", replace=FALSE)[", shard_id + 1L, "]"
    )
  )
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

#' Verify that a shard seed can be reproduced from the experiment manifest.
#'
#' Raises an error if the shard_seed stored in the manifest does not match
#' the freshly-derived value. Use this for audit checks.
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
#' @param manifest List. Parsed experiment_manifest.json.
#' @return Invisibly TRUE if all seeds verify; stops on first mismatch.
validate_all_shard_seeds <- function(manifest) {
  # Guard: n_shards must be present and positive.
  if (is.null(manifest$n_shards)) {
    stop("validate_all_shard_seeds: manifest is missing 'n_shards' field")
  }
  n_shards <- as.integer(manifest$n_shards)
  if (length(n_shards) != 1L || is.na(n_shards) || n_shards < 1L) {
    stop("validate_all_shard_seeds: manifest 'n_shards' must be a positive integer")
  }

  # Guard: n_shards must equal the number of seeds stored.  If they differ,
  # validate_shard_seed would silently skip any seeds beyond n_shards, making
  # the audit incomplete.
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
