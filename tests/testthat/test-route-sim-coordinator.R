source(file.path("..", "..", "R", "sim", "09_coordinator_utils.R"), local = FALSE)

test_that("split_work_counts partitions work across workers", {
  expect_equal(split_work_counts(10, 3), c(4L, 3L, 3L))
  expect_equal(split_work_counts(0, 4), c(0L, 0L, 0L, 0L))
  expect_error(split_work_counts(-1, 2), "total_n")
  expect_error(split_work_counts(10, 0), "workers")
})

test_that("worker_seed_offsets produce non-overlapping seed starts", {
  starts <- worker_seed_offsets(c(4, 3, 3), 100)
  expect_equal(starts, c(100L, 104L, 107L))
})

test_that("read_progress_status parses worker progress file", {
  f <- tempfile(fileext = ".csv")
  d <- data.frame(
    worker_label = "w1",
    i = 7,
    n = 20,
    status = "RUNNING",
    timestamp_utc = "2026-03-05 12:00:00 UTC",
    stringsAsFactors = FALSE
  )
  utils::write.csv(d, f, row.names = FALSE)
  p <- read_progress_status(f)
  expect_equal(p$i, 7L)
  expect_equal(p$n, 20L)
  expect_equal(p$status, "RUNNING")
  expect_true(inherits(p$timestamp, "POSIXct"))
})

test_that("is_stalled respects status and age", {
  p <- list(i = 2L, n = 10L, status = "RUNNING", timestamp = as.POSIXct("2026-03-05 00:00:00", tz = "UTC"))
  now <- as.POSIXct("2026-03-05 00:10:00", tz = "UTC")
  expect_true(is_stalled(p, now_utc = now, stall_seconds = 120))
  p_done <- modifyList(p, list(status = "DONE"))
  expect_false(is_stalled(p_done, now_utc = now, stall_seconds = 120))
})
