# tests/testthat/test-seeding.R
# Unit tests for R/seeding.R hierarchical seed derivation.

source(file.path(rprojroot::find_root(rprojroot::has_file("_targets.R")), "R", "seeding.R"))

# ---------------------------------------------------------------------------
# derive_shard_seeds
# ---------------------------------------------------------------------------

test_that("derive_shard_seeds is deterministic: same inputs → same output", {
  s1 <- derive_shard_seeds(42L, 8L)
  s2 <- derive_shard_seeds(42L, 8L)
  expect_identical(s1, s2)
})

test_that("derive_shard_seeds with different master_seeds → different vectors", {
  s1 <- derive_shard_seeds(42L, 8L)
  s2 <- derive_shard_seeds(43L, 8L)
  expect_false(identical(s1, s2))
})

test_that("derive_shard_seeds produces n_shards values", {
  for (n in c(1L, 5L, 20L, 100L)) {
    expect_length(derive_shard_seeds(7L, n), n)
  }
})

test_that("derive_shard_seeds names are 0-indexed strings", {
  s <- derive_shard_seeds(1L, 4L)
  expect_equal(names(s), c("0", "1", "2", "3"))
})

test_that("derive_shard_seeds: all values positive integers within [1, .Machine$integer.max]", {
  s <- derive_shard_seeds(99L, 50L)
  expect_true(all(s >= 1L))
  expect_true(all(s <= .Machine$integer.max))
  expect_type(s, "integer")
})

test_that("derive_shard_seeds: no duplicates for reasonable n_shards", {
  s <- derive_shard_seeds(12345L, 200L)
  expect_equal(length(unique(s)), length(s))
})

test_that("derive_shard_seeds does not mutate caller RNG state", {
  set.seed(999L)
  r1 <- runif(1)

  set.seed(999L)
  derive_shard_seeds(42L, 10L)  # should not affect RNG state on exit
  r2 <- runif(1)

  expect_equal(r1, r2)
})

# ---------------------------------------------------------------------------
# derive_shard_seed (single-shard convenience)
# ---------------------------------------------------------------------------

test_that("derive_shard_seed matches corresponding entry from derive_shard_seeds", {
  all_seeds <- derive_shard_seeds(7L, 5L)
  for (i in 0:4) {
    single <- derive_shard_seed(7L, i)
    expect_equal(single, unname(all_seeds[as.character(i)]))
  }
})

test_that("derive_shard_seed is deterministic", {
  expect_equal(derive_shard_seed(42L, 3L), derive_shard_seed(42L, 3L))
})

# ---------------------------------------------------------------------------
# derive_variant_seed
# ---------------------------------------------------------------------------

test_that("derive_variant_seed: variant_index=1 returns shard_seed unchanged", {
  expect_equal(derive_variant_seed(1000L, 1L), 1000L)
})

test_that("derive_variant_seed increments by (variant_index - 1)", {
  base <- 5000L
  for (idx in 1:10) {
    expect_equal(derive_variant_seed(base, idx), base + idx - 1L)
  }
})

test_that("derive_variant_seed does not overflow at INT_MAX", {
  max_seed <- .Machine$integer.max
  # Without overflow protection, max_seed + 1L produces NA; should stay positive.
  result <- derive_variant_seed(max_seed, 2L)
  expect_true(is.integer(result))
  expect_true(!is.na(result))
  expect_true(result >= 1L)
})

test_that("derive_variant_seed is consistent with run_chunk.R pattern", {
  shard_seed <- 12345L
  n_variants <- 8L
  # Existing pattern: seed_used = seed_base + i - 1L (i is 1-based)
  expected <- shard_seed + seq_len(n_variants) - 1L
  got      <- vapply(seq_len(n_variants), function(i) derive_variant_seed(shard_seed, i), integer(1L))
  expect_equal(got, expected)
})

# ---------------------------------------------------------------------------
# build_seed_provenance
# ---------------------------------------------------------------------------

test_that("build_seed_provenance returns required fields", {
  p <- build_seed_provenance(42L, 3L, 99999L, 10L)
  expect_equal(p$master_seed, 42L)
  expect_equal(p$shard_id, 3L)
  expect_equal(p$shard_seed, 99999L)
  expect_equal(p$n_shards, 10L)
  expect_equal(p$rng_kind, "Mersenne-Twister")
  expect_true(nzchar(p$derivation))
})

test_that("build_seed_provenance derivation field is executable R code", {
  p <- build_seed_provenance(42L, 0L, derive_shard_seed(42L, 0L), 5L)
  # eval(parse()) calls set.seed() + sample.int() directly and mutates global
  # RNG state.  Save and restore so this test does not affect subsequent tests.
  rng_existed <- exists(".Random.seed", envir = globalenv(), inherits = FALSE)
  old_rng     <- if (rng_existed) .Random.seed else NULL
  on.exit({
    if (rng_existed) assign(".Random.seed", old_rng, envir = globalenv())
    else suppressWarnings(rm(".Random.seed", envir = globalenv()))
  })
  result <- eval(parse(text = p$derivation))
  expect_equal(result, p$shard_seed)
})

# ---------------------------------------------------------------------------
# validate_shard_seed / validate_all_shard_seeds
# ---------------------------------------------------------------------------

test_that("validate_shard_seed passes for correct manifest", {
  seeds <- derive_shard_seeds(77L, 4L)
  manifest <- list(
    master_seed  = 77L,
    n_shards     = 4L,
    shard_seeds  = as.list(seeds)
  )
  expect_invisible(validate_shard_seed(manifest, 0L))
  expect_invisible(validate_shard_seed(manifest, 3L))
})

test_that("validate_shard_seed fails for tampered seed", {
  seeds <- derive_shard_seeds(77L, 4L)
  seeds["2"] <- 999L  # tampered
  manifest <- list(
    master_seed = 77L,
    n_shards    = 4L,
    shard_seeds = as.list(seeds)
  )
  expect_error(validate_shard_seed(manifest, 2L), "seed mismatch")
})

test_that("validate_all_shard_seeds passes for correctly derived manifest", {
  n <- 6L
  seeds <- derive_shard_seeds(123L, n)
  manifest <- list(
    master_seed = 123L,
    n_shards    = n,
    shard_seeds = as.list(seeds)
  )
  expect_invisible(validate_all_shard_seeds(manifest))
})

test_that("validate_shard_seed errors on missing shard_id", {
  manifest <- list(master_seed = 1L, n_shards = 2L, shard_seeds = list("0" = 111L))
  expect_error(validate_shard_seed(manifest, 5L), "not found")
})

test_that("validate_all_shard_seeds errors when n_shards field is missing", {
  seeds    <- derive_shard_seeds(77L, 3L)
  manifest <- list(master_seed = 77L, shard_seeds = as.list(seeds))
  # n_shards absent — must error clearly, not warn-then-crash with a cryptic message
  expect_error(validate_all_shard_seeds(manifest), "missing 'n_shards'")
})

test_that("validate_all_shard_seeds errors when n_shards < length(shard_seeds)", {
  seeds    <- derive_shard_seeds(77L, 3L)
  manifest <- list(master_seed = 77L, n_shards = 1L, shard_seeds = as.list(seeds))
  # n_shards=1 but 3 seeds present: shards 1-2 would be silently skipped without this guard
  expect_error(validate_all_shard_seeds(manifest), "3 seeds present")
})
