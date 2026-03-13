safe_memory_numeric <- function(x, default = NA_real_) {
  v <- suppressWarnings(as.numeric(x))
  if (!is.finite(v)) return(as.numeric(default))
  as.numeric(v)
}

current_rss_mb <- function() {
  pid <- Sys.getpid()
  out <- tryCatch(
    system2("ps", args = c("-o", "rss=", "-p", as.character(pid)), stdout = TRUE, stderr = FALSE),
    error = function(e) character()
  )
  if (length(out) == 0) return(NA_real_)
  kb <- safe_memory_numeric(trimws(out[[1]]), default = NA_real_)
  if (!is.finite(kb) || kb < 0) return(NA_real_)
  kb / 1024
}

heap_used_mb <- function(gc_stats = NULL) {
  g <- gc_stats
  if (is.null(g)) g <- gc(verbose = FALSE)
  ncells <- safe_memory_numeric(g["Ncells", "used"], default = 0)
  vcells <- safe_memory_numeric(g["Vcells", "used"], default = 0)
  ((ncells * 56) + (vcells * 8)) / (1024 ^ 2)
}

heap_max_mb <- function(gc_stats = NULL) {
  g <- gc_stats
  if (is.null(g)) g <- gc(verbose = FALSE)
  if (!"max used" %in% colnames(g)) return(NA_real_)
  ncells <- safe_memory_numeric(g["Ncells", "max used"], default = 0)
  vcells <- safe_memory_numeric(g["Vcells", "max used"], default = 0)
  ((ncells * 56) + (vcells * 8)) / (1024 ^ 2)
}

current_memory_snapshot <- function(label = NA_character_, force_gc = FALSE) {
  if (isTRUE(force_gc)) gc(verbose = FALSE)
  g <- gc(verbose = FALSE)
  data.frame(
    timestamp_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
    label = as.character(label %||% NA_character_),
    rss_mb = current_rss_mb(),
    heap_used_mb = heap_used_mb(g),
    heap_max_mb = heap_max_mb(g),
    stringsAsFactors = FALSE
  )
}

init_memory_monitor <- function(profile_path = "", rss_limit_mb = NA_real_) {
  list(
    profile_path = as.character(profile_path %||% ""),
    rss_limit_mb = safe_memory_numeric(rss_limit_mb, default = NA_real_),
    initial_rss_mb = NA_real_,
    initial_heap_mb = NA_real_,
    peak_rss_mb = NA_real_,
    peak_heap_mb = NA_real_,
    final_rss_mb = NA_real_,
    final_heap_mb = NA_real_
  )
}

write_memory_snapshot <- function(path, snapshot, run_index = NA_integer_, pid = Sys.getpid()) {
  if (!nzchar(as.character(path %||% "")) || !is.data.frame(snapshot) || nrow(snapshot) == 0) return(invisible(NULL))
  row <- snapshot
  row$run_index <- as.integer(run_index)
  row$pid <- as.integer(pid)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  if (requireNamespace("data.table", quietly = TRUE)) {
    data.table::fwrite(row, path, append = file.exists(path), col.names = !file.exists(path))
  } else {
    utils::write.table(row, path, sep = ",", row.names = FALSE, col.names = !file.exists(path), append = file.exists(path))
  }
  invisible(NULL)
}

record_memory_snapshot <- function(monitor, label, run_index = NA_integer_, force_gc = FALSE, log_label = "memory") {
  if (is.null(monitor)) return(list(monitor = monitor, snapshot = data.frame()))
  snap <- current_memory_snapshot(label = label, force_gc = force_gc)
  rss_mb <- safe_memory_numeric(snap$rss_mb[[1]], default = NA_real_)
  heap_mb <- safe_memory_numeric(snap$heap_used_mb[[1]], default = NA_real_)

  if (!is.finite(monitor$initial_rss_mb)) {
    monitor$initial_rss_mb <- rss_mb
    monitor$initial_heap_mb <- heap_mb
  }
  monitor$final_rss_mb <- rss_mb
  monitor$final_heap_mb <- heap_mb
  if (is.finite(rss_mb)) {
    monitor$peak_rss_mb <- if (is.finite(monitor$peak_rss_mb)) max(monitor$peak_rss_mb, rss_mb) else rss_mb
  }
  if (is.finite(heap_mb)) {
    monitor$peak_heap_mb <- if (is.finite(monitor$peak_heap_mb)) max(monitor$peak_heap_mb, heap_mb) else heap_mb
  }

  write_memory_snapshot(monitor$profile_path, snap, run_index = run_index)

  if (exists("log_event", mode = "function")) {
    log_event(
      level = "INFO",
      phase = log_label,
      msg = paste0(
        "label=", as.character(label),
        " run_index=", as.character(run_index),
        " rss_mb=", formatC(rss_mb, format = "f", digits = 2),
        " heap_used_mb=", formatC(heap_mb, format = "f", digits = 2),
        " heap_max_mb=", formatC(safe_memory_numeric(snap$heap_max_mb[[1]], default = NA_real_), format = "f", digits = 2)
      )
    )
  }

  limit_mb <- safe_memory_numeric(monitor$rss_limit_mb, default = NA_real_)
  if (is.finite(limit_mb) && is.finite(rss_mb) && rss_mb > limit_mb) {
    stop(
      "Memory guard triggered at label=", as.character(label),
      ": rss_mb=", formatC(rss_mb, format = "f", digits = 2),
      " exceeded rss_limit_mb=", formatC(limit_mb, format = "f", digits = 2)
    )
  }

  list(monitor = monitor, snapshot = snap)
}

memory_summary_row <- function(monitor, batch_id = NA_character_, run_count = NA_integer_) {
  if (is.null(monitor)) return(data.frame())
  data.frame(
    batch_id = as.character(batch_id %||% NA_character_),
    run_count = as.integer(run_count),
    initial_rss_mb = safe_memory_numeric(monitor$initial_rss_mb, default = NA_real_),
    peak_rss_mb = safe_memory_numeric(monitor$peak_rss_mb, default = NA_real_),
    final_rss_mb = safe_memory_numeric(monitor$final_rss_mb, default = NA_real_),
    delta_rss_mb = safe_memory_numeric(monitor$final_rss_mb - monitor$initial_rss_mb, default = NA_real_),
    initial_heap_mb = safe_memory_numeric(monitor$initial_heap_mb, default = NA_real_),
    peak_heap_mb = safe_memory_numeric(monitor$peak_heap_mb, default = NA_real_),
    final_heap_mb = safe_memory_numeric(monitor$final_heap_mb, default = NA_real_),
    delta_heap_mb = safe_memory_numeric(monitor$final_heap_mb - monitor$initial_heap_mb, default = NA_real_),
    rss_limit_mb = safe_memory_numeric(monitor$rss_limit_mb, default = NA_real_),
    stringsAsFactors = FALSE
  )
}

write_memory_summary <- function(path, monitor, batch_id = NA_character_, run_count = NA_integer_) {
  if (!nzchar(as.character(path %||% "")) || is.null(monitor)) return(invisible(NULL))
  row <- memory_summary_row(monitor, batch_id = batch_id, run_count = run_count)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    as.list(row[1, , drop = FALSE]),
    path = path,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null",
    na = "null"
  )
  invisible(row)
}
