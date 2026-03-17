## tests/testthat/test-cloud-preflight.R
## Validates preflight_cloud.sh existence, permissions, and quota parsing logic.

repo_root <- rprojroot::find_root(rprojroot::has_file("_targets.R"))

test_that("preflight_cloud.sh exists and is executable", {
  script <- file.path(repo_root, "tools", "preflight_cloud.sh")
  expect_true(file.exists(script))
  # file.access mode 1 = execute; returns 0 on success

  expect_equal(file.access(script, mode = 1), 0L,
               info = "preflight_cloud.sh must be executable (chmod +x)")
})

test_that("preflight_cloud.sh has bash strict mode", {
  script <- file.path(repo_root, "tools", "preflight_cloud.sh")
  lines <- readLines(script, n = 10)
  expect_true(any(grepl("^#!/usr/bin/env bash", lines)),
              info = "Script must use #!/usr/bin/env bash shebang")
  expect_true(any(grepl("set -euo pipefail", lines)),
              info = "Script must use strict mode (set -euo pipefail)")
})

test_that("GCP quota parsing handles tab-separated limit and usage", {
  # Simulates the output of:
  #   gcloud compute project-info describe \
  #     --format="value(quotas[name=CPUS_ALL_REGIONS].limit,
  #                      quotas[name=CPUS_ALL_REGIONS].usage)"
  # which returns a single line: "24.0\t8.0"

  parse_quota <- function(raw, headroom = 8L) {
    # Mirror the shell logic: cut -f1 / cut -f2, then printf '%.0f'
    parts <- strsplit(trimws(raw), "\t")[[1]]
    limit <- as.integer(round(as.numeric(parts[1])))
    usage <- as.integer(round(as.numeric(parts[2])))
    available <- limit - usage
    list(limit = limit, usage = usage, available = available,
         ok = available >= headroom)
  }

  # Normal case: plenty of headroom
  res <- parse_quota("24.0\t4.0", headroom = 8L)
  expect_equal(res$limit, 24L)
  expect_equal(res$usage, 4L)
  expect_equal(res$available, 20L)
  expect_true(res$ok)

  # Tight: exactly at headroom boundary
  res2 <- parse_quota("24.0\t16.0", headroom = 8L)
  expect_equal(res2$available, 8L)
  expect_true(res2$ok)

  # Over threshold: should warn

  res3 <- parse_quota("24.0\t20.0", headroom = 8L)
  expect_equal(res3$available, 4L)
  expect_false(res3$ok)

  # Integer output (no decimal)
  res4 <- parse_quota("8\t0", headroom = 8L)
  expect_equal(res4$limit, 8L)
  expect_equal(res4$usage, 0L)
  expect_true(res4$ok)

  # Fully exhausted
  res5 <- parse_quota("24.0\t24.0", headroom = 8L)
  expect_equal(res5$available, 0L)
  expect_false(res5$ok)
})

test_that("script contains all required check sections", {
  script <- file.path(repo_root, "tools", "preflight_cloud.sh")
  content <- readLines(script)
  full <- paste(content, collapse = "\n")

  expect_true(grepl("check_gcp_quota", full),    info = "Missing GCP quota check")
  expect_true(grepl("check_gcp_ssh", full),       info = "Missing GCP SSH check")
  expect_true(grepl("check_azure_ssh", full),     info = "Missing Azure SSH check")
  expect_true(grepl("check_gcs_bucket", full),    info = "Missing GCS bucket check")
  expect_true(grepl("check_disk_space", full),    info = "Missing disk space check")
  expect_true(grepl("check_running_sims", full),  info = "Missing running sims check")
})

test_that("pgrep uses bracket trick to avoid self-match", {
  # lessonsLearned.md documents the pgrep self-match bug.
  # The script must use '[R]script' (bracket trick) so pgrep does not
  # count its own grep process as a match.
  script <- file.path(repo_root, "tools", "preflight_cloud.sh")
  content <- paste(readLines(script), collapse = "\n")
  expect_true(grepl("\\[R\\]script", content),
              info = "pgrep must use bracket trick '[R]script' to avoid self-match (see lessonsLearned.md)")
})

test_that("script help flag works without error", {
  script <- file.path(repo_root, "tools", "preflight_cloud.sh")
  out <- suppressWarnings(
    system2("bash", c(script, "--help"), stdout = TRUE, stderr = TRUE)
  )
  exit_code <- attr(out, "status")
  # --help should exit 0
  expect_true(is.null(exit_code) || exit_code == 0L,
              info = "--help should exit cleanly")
})
