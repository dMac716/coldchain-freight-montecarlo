# Utilities for route simulation coordinator.

split_work_counts <- function(total_n, workers) {
  total_n <- as.integer(total_n)
  workers <- as.integer(workers)
  if (!is.finite(total_n) || total_n < 0) stop("total_n must be >= 0")
  if (!is.finite(workers) || workers <= 0) stop("workers must be > 0")
  base <- total_n %/% workers
  rem <- total_n %% workers
  out <- rep(base, workers)
  if (rem > 0) out[seq_len(rem)] <- out[seq_len(rem)] + 1L
  out
}

worker_seed_offsets <- function(counts, base_seed) {
  counts <- as.integer(counts)
  if (length(counts) == 0) return(integer())
  starts <- integer(length(counts))
  cur <- as.integer(base_seed)
  for (i in seq_along(counts)) {
    starts[[i]] <- cur
    cur <- cur + max(0L, counts[[i]])
  }
  starts
}

read_progress_status <- function(path) {
  if (!file.exists(path)) return(NULL)
  d <- tryCatch(utils::read.csv(path, stringsAsFactors = FALSE), error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  row <- d[1, , drop = FALSE]
  ts <- suppressWarnings(as.POSIXct(row$timestamp_utc[[1]], tz = "UTC"))
  list(
    i = suppressWarnings(as.integer(row$i[[1]])),
    n = suppressWarnings(as.integer(row$n[[1]])),
    status = as.character(row$status[[1]]),
    timestamp = ts
  )
}

is_stalled <- function(progress, now_utc = Sys.time(), stall_seconds = 600) {
  if (is.null(progress)) return(FALSE)
  if (!is.finite(stall_seconds) || stall_seconds <= 0) return(FALSE)
  if (!inherits(progress$timestamp, "POSIXct") || is.na(progress$timestamp)) return(FALSE)
  age <- as.numeric(difftime(now_utc, progress$timestamp, units = "secs"))
  is.finite(age) && age > as.numeric(stall_seconds) && !identical(progress$status, "DONE")
}
