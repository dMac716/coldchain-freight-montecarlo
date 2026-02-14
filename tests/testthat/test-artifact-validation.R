test_that("Artifact validation enforces histogram integrity", {
  if (!exists("validate_artifact_schema_local")) skip("validate_artifact_schema_local not implemented yet")

  artifact <- list(
    run_id = "run1",
    run_group_id = "grp",
    model_version = "v0",
    inputs_hash = "abc",
    metric_definitions_hash = "def",
    timestamp_utc = "2026-02-12T00:00:00Z",
    rng_kind = "Mersenne-Twister",
    seed = 123L,
    n_chunk = 3L,
    metrics = list(
      gco2_dry = list(
        n = 3L,
        sum = 3,
        sum_sq = 3,
        min = 1,
        max = 1,
        histogram = list(bin_edges = c(0, 1), bin_counts = c(1, 1), underflow = 0L, overflow = 0L)
      ),
      gco2_reefer = list(
        n = 3L,
        sum = 3,
        sum_sq = 3,
        min = 1,
        max = 1,
        histogram = list(bin_edges = c(0, 1, 2), bin_counts = c(3, 0), underflow = 0L, overflow = 0L)
      ),
      diff_gco2 = list(
        n = 3L,
        sum = 3,
        sum_sq = 3,
        min = 1,
        max = 1,
        histogram = list(bin_edges = c(0, 1, 2), bin_counts = c(3, 0), underflow = 0L, overflow = 0L)
      ),
      ratio = list(
        n = 3L,
        sum = 3,
        sum_sq = 3,
        min = 1,
        max = 1,
        histogram = list(bin_edges = c(0, 1, 2), bin_counts = c(3, 0), underflow = 0L, overflow = 0L)
      )
    ),
    integrity = list(artifact_sha256 = paste(rep("a", 64), collapse = ""), inputs_resolved_sha256 = paste(rep("b", 64), collapse = ""))
  )

  path <- file.path(tempdir(), "artifact.json")
  writeLines(jsonlite::toJSON(artifact, auto_unbox = TRUE, pretty = TRUE), path)

  expect_error(validate_artifact_schema_local(path))
})
