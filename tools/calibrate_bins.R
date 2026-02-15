#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--run_group"), type = "character", help = "Run group id used for pilot artifacts"),
  make_option(c("--hist_csv"), type = "character", default = "data/inputs_local/histogram_config.csv", help = "Histogram config CSV path"),
  make_option(c("--q_low"), type = "double", default = 0.001, help = "Lower quantile for bounds"),
  make_option(c("--q_high"), type = "double", default = 0.999, help = "Upper quantile for bounds"),
  make_option(c("--pad_frac"), type = "double", default = 0.05, help = "Fractional padding around quantile span"),
  make_option(c("--bins"), type = "integer", default = NA_integer_, help = "Optional fixed bin count for all metrics")
)
opt <- parse_args(OptionParser(option_list = option_list))

if (is.null(opt$run_group)) stop("--run_group is required.")
if (!file.exists(opt$hist_csv)) stop("Histogram config CSV not found: ", opt$hist_csv)
if (opt$q_low < 0 || opt$q_high > 1 || opt$q_low >= opt$q_high) {
  stop("Require 0 <= q_low < q_high <= 1.")
}
if (opt$pad_frac < 0) stop("pad_frac must be >= 0.")

files <- list.files("contrib/chunks", pattern = paste0("chunk_", opt$run_group), full.names = TRUE)
if (length(files) == 0) stop("No chunk artifacts found for run_group.")

artifacts <- lapply(files, function(f) {
  validate_artifact_schema_local(f)
  jsonlite::fromJSON(f, simplifyVector = FALSE)
})

ref <- artifacts[[1]]
keep <- artifacts[vapply(artifacts, function(a) {
  isTRUE(a$model_version == ref$model_version &&
           a$inputs_hash == ref$inputs_hash &&
           a$metric_definitions_hash == ref$metric_definitions_hash)
}, logical(1))]

if (length(keep) == 0) stop("No compatible artifacts found for calibration.")

metric_names <- names(ref$metrics)
chunk_results <- lapply(keep, function(a) {
  stats <- list()
  hists <- list()
  for (nm in metric_names) {
    m <- a$metrics[[nm]]
    stats[[nm]] <- list(n = m$n, sum = m$sum, sum_sq = m$sum_sq, min = m$min, max = m$max)
    h <- m$histogram
    hists[[nm]] <- list(
      bin_edges = unlist(h$bin_edges),
      counts = unlist(h$bin_counts),
      underflow = h$underflow,
      overflow = h$overflow
    )
  }
  list(stats = stats, hist = hists)
})

merged <- merge_chunk_results(chunk_results)
hist_cfg <- utils::read.csv(opt$hist_csv, stringsAsFactors = FALSE)
if (!all(c("metric", "min", "max", "bins") %in% names(hist_cfg))) {
  stop("Histogram config must include metric,min,max,bins columns.")
}

utc_now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
for (i in seq_len(nrow(hist_cfg))) {
  nm <- hist_cfg$metric[[i]]
  if (!nm %in% names(merged$hist)) next
  h <- merged$hist[[nm]]

  ql <- hist_quantile(h, opt$q_low)
  qh <- hist_quantile(h, opt$q_high)
  if (!is.finite(ql) || !is.finite(qh)) next
  span <- qh - ql
  if (!is.finite(span) || span <= 0) {
    span <- max(abs(ql), abs(qh), 1) * 0.01
  }
  pad <- span * opt$pad_frac
  hist_cfg$min[[i]] <- ql - pad
  hist_cfg$max[[i]] <- qh + pad
  if (!is.na(opt$bins)) hist_cfg$bins[[i]] <- as.integer(opt$bins)
}

if (!"status" %in% names(hist_cfg)) hist_cfg$status <- NA_character_
if (!"notes" %in% names(hist_cfg)) hist_cfg$notes <- NA_character_
if (!"calibration_run_group" %in% names(hist_cfg)) hist_cfg$calibration_run_group <- NA_character_
if (!"calibrated_at_utc" %in% names(hist_cfg)) hist_cfg$calibrated_at_utc <- NA_character_
if (!"calibration_method" %in% names(hist_cfg)) hist_cfg$calibration_method <- NA_character_

hist_cfg$status <- "CALIBRATED_FROM_PILOT"
hist_cfg$calibration_run_group <- opt$run_group
hist_cfg$calibrated_at_utc <- utc_now
hist_cfg$calibration_method <- paste0(
  "quantiles[", format(opt$q_low, trim = TRUE), ",", format(opt$q_high, trim = TRUE),
  "] pad_frac=", format(opt$pad_frac, trim = TRUE)
)
hist_cfg$notes <- paste0(
  "Calibrated from merged pilot artifacts for run_group=", opt$run_group,
  " at ", utc_now
)

utils::write.csv(hist_cfg, opt$hist_csv, row.names = FALSE)
message("Histogram calibration complete: ", opt$hist_csv)
