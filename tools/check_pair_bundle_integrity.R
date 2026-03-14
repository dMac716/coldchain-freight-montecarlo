#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

if (!requireNamespace("data.table", quietly = TRUE)) {
  stop("data.table package required")
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--bundle_root"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--recursive"), type = "character", default = "true"),
  make_option(c("--out_csv"), type = "character", default = "")
)))

parse_bool <- function(x, default = TRUE) {
  raw <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(raw)) return(isTRUE(default))
  if (raw %in% c("1", "true", "yes", "y")) return(TRUE)
  if (raw %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Boolean flag must be true/false")
}

`%||%` <- function(x, y) if (is.null(x)) y else x

bundle_root <- normalizePath(opt$bundle_root, winslash = "/", mustWork = FALSE)
if (!dir.exists(bundle_root)) {
  stop("bundle_root does not exist: ", bundle_root)
}

scan_recursive <- parse_bool(opt$recursive, default = TRUE)
pair_dirs <- list.dirs(bundle_root, full.names = TRUE, recursive = scan_recursive)
pair_dirs <- unique(pair_dirs[basename(pair_dirs) %in% basename(pair_dirs)[grepl("^pair_", basename(pair_dirs))]])
pair_dirs <- sort(pair_dirs)

if (length(pair_dirs) == 0) {
  cat("STATUS: WARN\n")
  cat("No pair_* directories found under ", bundle_root, "\n", sep = "")
  quit(save = "no", status = 0)
}

check_one_pair <- function(pair_dir) {
  runs_path <- file.path(pair_dir, "runs.csv")
  sums_path <- file.path(pair_dir, "summaries.csv")
  issues <- character()

  if (!file.exists(runs_path)) issues <- c(issues, "missing_runs.csv")
  if (!file.exists(sums_path)) issues <- c(issues, "missing_summaries.csv")

  runs <- NULL
  sums <- NULL
  if (file.exists(runs_path)) {
    runs <- tryCatch(data.table::fread(runs_path, showProgress = FALSE), error = function(e) NULL)
    if (is.null(runs)) issues <- c(issues, "runs_read_error")
  }
  if (file.exists(sums_path)) {
    sums <- tryCatch(data.table::fread(sums_path, showProgress = FALSE), error = function(e) NULL)
    if (is.null(sums)) issues <- c(issues, "summaries_read_error")
  }

  runs_n <- if (is.null(runs)) NA_integer_ else nrow(runs)
  sums_n <- if (is.null(sums)) NA_integer_ else nrow(sums)
  if (!is.na(runs_n) && runs_n != 2L) issues <- c(issues, paste0("runs_rows=", runs_n))
  if (!is.na(sums_n) && sums_n != 2L) issues <- c(issues, paste0("summaries_rows=", sums_n))

  origin_count <- NA_integer_
  pair_id_count <- NA_integer_
  powertrain_nonempty <- NA
  facility_id_nonempty <- NA
  retail_id_nonempty <- NA
  if (!is.null(runs)) {
    if (!("origin_network" %in% names(runs))) {
      issues <- c(issues, "runs_missing_origin_network")
    } else {
      origins <- as.character(runs$origin_network)
      origins <- origins[!is.na(origins) & nzchar(origins)]
      origin_count <- length(unique(origins))
      if (origin_count != 2L) issues <- c(issues, paste0("origin_count=", origin_count))
    }
    if (!("pair_id" %in% names(runs))) {
      issues <- c(issues, "runs_missing_pair_id")
    } else {
      pair_ids <- as.character(runs$pair_id)
      pair_ids <- pair_ids[!is.na(pair_ids) & nzchar(pair_ids)]
      pair_id_count <- length(unique(pair_ids))
      if (pair_id_count != 1L) issues <- c(issues, paste0("pair_id_count=", pair_id_count))
    }
    if (!("powertrain" %in% names(runs))) {
      issues <- c(issues, "runs_missing_powertrain")
    } else {
      pt <- as.character(runs$powertrain)
      powertrain_nonempty <- all(!is.na(pt) & nzchar(trimws(pt)))
      if (!isTRUE(powertrain_nonempty)) issues <- c(issues, "powertrain_blank")
    }
    if (!("facility_id" %in% names(runs))) {
      issues <- c(issues, "runs_missing_facility_id")
    } else {
      fid <- as.character(runs$facility_id)
      facility_id_nonempty <- all(!is.na(fid) & nzchar(trimws(fid)))
      if (!isTRUE(facility_id_nonempty)) issues <- c(issues, "facility_id_blank")
    }
    if ("retail_id" %in% names(runs)) {
      rid <- as.character(runs$retail_id)
      retail_id_nonempty <- all(!is.na(rid) & nzchar(trimws(rid)))
      if (!isTRUE(retail_id_nonempty)) issues <- c(issues, "WARN_retail_id_blank")
    } else {
      issues <- c(issues, "WARN_retail_id_missing_column")
    }
  }

  hard_issues <- issues[!grepl("^WARN_", issues)]
  status <- if (length(hard_issues) == 0L) {
    if (length(issues) == 0L) "PASS" else "WARN"
  } else {
    "FAIL"
  }
  data.frame(
    pair_dir = pair_dir,
    runs_rows = runs_n,
    summaries_rows = sums_n,
    origin_count = origin_count,
    pair_id_count = pair_id_count,
    powertrain_nonempty = powertrain_nonempty,
    facility_id_nonempty = facility_id_nonempty,
    retail_id_nonempty = retail_id_nonempty,
    status = status,
    issues = if (length(issues) == 0L) "" else paste(unique(issues), collapse = ";"),
    stringsAsFactors = FALSE
  )
}

rows <- lapply(pair_dirs, check_one_pair)
report <- data.table::rbindlist(rows, fill = TRUE, use.names = TRUE)
report <- as.data.frame(report, stringsAsFactors = FALSE)

cat("PAIR_BUNDLE_INTEGRITY_REPORT\n")
print(report[, c("status", "pair_dir", "runs_rows", "summaries_rows", "origin_count", "pair_id_count", "issues")], row.names = FALSE)

summary_tbl <- as.data.frame(table(report$status), stringsAsFactors = FALSE)
names(summary_tbl) <- c("status", "n_pairs")
summary_tbl <- summary_tbl[order(match(summary_tbl$status, c("PASS", "WARN", "FAIL"))), , drop = FALSE]

cat("\nSUMMARY\n")
print(summary_tbl, row.names = FALSE)

if (nzchar(opt$out_csv)) {
  dir.create(dirname(opt$out_csv), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(report, opt$out_csv)
  cat("\nWrote", opt$out_csv, "\n")
}

if (any(report$status == "FAIL")) {
  quit(save = "no", status = 1)
}
quit(save = "no", status = 0)
