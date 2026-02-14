test_that("Artifact checksum is stable under key reordering", {
  if (!exists("artifact_canonical_sha256")) skip("artifact_canonical_sha256 not implemented yet")

  a <- list(
    model_version = "abc",
    run_id = "run1",
    metrics = list(ratio = list(n = 1)),
    run_group_id = "grp",
    inputs_hash = paste(rep("a", 64), collapse = ""),
    metric_definitions_hash = paste(rep("b", 64), collapse = ""),
    timestamp_utc = "2026-02-12T00:00:00Z",
    rng_kind = "Mersenne-Twister,Inversion,Rejection",
    seed = 1L,
    n_chunk = 1L
  )
  b <- list(
    n_chunk = 1L,
    seed = 1L,
    rng_kind = "Mersenne-Twister,Inversion,Rejection",
    timestamp_utc = "2026-02-12T00:00:00Z",
    metric_definitions_hash = paste(rep("b", 64), collapse = ""),
    inputs_hash = paste(rep("a", 64), collapse = ""),
    run_group_id = "grp",
    metrics = list(ratio = list(n = 1)),
    run_id = "run1",
    model_version = "abc"
  )

  expect_identical(artifact_canonical_sha256(a), artifact_canonical_sha256(b))
})

test_that("Artifact validator enforces canonical checksum semantics", {
  if (!exists("run_monte_carlo_chunk")) skip("run_monte_carlo_chunk not implemented yet")
  if (!exists("validate_artifact_schema_local")) skip("validate_artifact_schema_local not implemented yet")
  if (!exists("artifact_canonical_sha256")) skip("artifact_canonical_sha256 not implemented yet")

  x <- fixture_inputs_small()
  h <- fixture_hist_config()
  chunk <- run_monte_carlo_chunk(inputs = x, hist_config = h, n = 100, seed = 123)

  metrics_payload <- list()
  for (nm in names(chunk$stats)) {
    hs <- chunk$hist[[nm]]
    metrics_payload[[nm]] <- list(
      n = chunk$stats[[nm]]$n,
      sum = chunk$stats[[nm]]$sum,
      sum_sq = chunk$stats[[nm]]$sum_sq,
      min = chunk$stats[[nm]]$min,
      max = chunk$stats[[nm]]$max,
      histogram = list(
        bin_edges = unname(hs$bin_edges),
        bin_counts = unname(hs$counts),
        underflow = hs$underflow,
        overflow = hs$overflow
      )
    )
  }

  artifact <- list(
    run_id = "run1",
    run_group_id = "grp",
    model_version = "v0",
    inputs_hash = paste(rep("a", 64), collapse = ""),
    metric_definitions_hash = paste(rep("b", 64), collapse = ""),
    timestamp_utc = "2026-02-12T00:00:00Z",
    rng_kind = chunk$metadata$rng_kind,
    seed = 123L,
    n_chunk = 100L,
    metrics = metrics_payload,
    integrity = list(
      artifact_sha256 = "",
      inputs_resolved_sha256 = paste(rep("c", 64), collapse = "")
    )
  )
  artifact$integrity$artifact_sha256 <- artifact_canonical_sha256(artifact)

  path <- file.path(tempdir(), "artifact_checksum_ok.json")
  writeLines(jsonlite::toJSON(artifact, auto_unbox = TRUE, pretty = TRUE), path)
  expect_silent(validate_artifact_schema_local(path))

  artifact$metrics$ratio$sum <- artifact$metrics$ratio$sum + 1
  path_bad <- file.path(tempdir(), "artifact_checksum_bad.json")
  writeLines(jsonlite::toJSON(artifact, auto_unbox = TRUE, pretty = TRUE), path_bad)
  expect_error(validate_artifact_schema_local(path_bad), "checksum mismatch")
})
