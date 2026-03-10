#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--run_group"), type = "character", help = "Run group id"),
  make_option(c("--mode"), type = "character", default = "SMOKE_LOCAL", help = "Run mode: SMOKE_LOCAL or REAL_RUN"),
  make_option(c("--distance_mode"), type = "character", default = "FAF_DISTRIBUTION", help = "Distance mode: FAF_DISTRIBUTION, ROAD_NETWORK_FIXED_DEST, ROAD_NETWORK_PHYSICS")
)
opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$run_group)) stop("--run_group is required.")
mode <- normalize_run_mode(opt$mode)
distance_mode <- normalize_distance_mode(opt$distance_mode)
Sys.setenv(DISTANCE_MODE = distance_mode)

configure_log(
  tag  = "aggregate",
  lane = Sys.getenv("COLDCHAIN_LANE", unset = "local")
)
log_event("INFO", "start", sprintf(
  "aggregate starting: run_group=%s mode=%s", opt$run_group, opt$mode
))

inputs <- read_inputs_local()
assert_mode_data_ready(mode, inputs$scenarios, inputs$histogram_config, inputs = inputs, distance_mode = distance_mode)

if (mode == "REAL_RUN" && nrow(inputs$scenario_matrix) > 0) {
  rg_rows <- subset(inputs$scenario_matrix, run_group == opt$run_group)
  if (nrow(rg_rows) > 0 && "status" %in% names(rg_rows) && any(grepl("MISSING", rg_rows$status, fixed = TRUE))) {
    stop("REAL_RUN gate failed: run_group contains variants with missing status.")
  }
}

files <- list.files("contrib/chunks", pattern = paste0("chunk_", opt$run_group), full.names = TRUE)
if (length(files) == 0) stop("No chunk artifacts found for run_group.")

artifacts <- list()
for (f in files) {
  validate_artifact_schema_local(f)
  artifacts[[f]] <- jsonlite::fromJSON(f, simplifyVector = FALSE)
}

ref <- artifacts[[1]]
keep <- list()
for (f in names(artifacts)) {
  a <- artifacts[[f]]
  if (a$model_version != ref$model_version ||
      a$inputs_hash != ref$inputs_hash ||
      a$metric_definitions_hash != ref$metric_definitions_hash) {
    message("Skipping artifact with mismatched model or inputs: ", f)
    log_event("WARN", "aggregate", sprintf("skipping mismatched artifact: %s", f))
    next
  }
  keep[[f]] <- a
}

if (length(keep) == 0) stop("No compatible artifacts to merge.")

metric_names <- names(ref$metrics)

chunk_results <- list()
for (a in keep) {
  stats <- list()
  hists <- list()
  for (nm in metric_names) {
    m <- a$metrics[[nm]]
    stats[[nm]] <- list(
      n = m$n,
      sum = m$sum,
      sum_sq = m$sum_sq,
      min = m$min,
      max = m$max
    )
    h <- m$histogram
    hists[[nm]] <- list(
      bin_edges = unlist(h$bin_edges),
      counts = unlist(h$bin_counts),
      underflow = h$underflow,
      overflow = h$overflow
    )
  }
  chunk_results[[length(chunk_results) + 1]] <- list(stats = stats, hist = hists)
}

merged <- merge_chunk_results(chunk_results)
enforce_hist_coverage(
  hist_list = merged$hist,
  n_list = lapply(merged$stats, function(s) s$n),
  mode = mode,
  threshold = 0.001,
  context = paste0("aggregate run_group=", opt$run_group)
)

prob_gt_zero <- function(hist) {
  edges <- hist$bin_edges
  counts <- hist$counts
  n_total <- sum(counts) + hist$underflow + hist$overflow
  if (n_total == 0) return(NA_real_)

  prob <- 0
  for (i in seq_along(counts)) {
    left <- edges[i]
    right <- edges[i + 1]
    if (right <= 0) next
    if (left >= 0) {
      prob <- prob + counts[i]
    } else {
      frac <- (right - 0) / (right - left)
      prob <- prob + counts[i] * frac
    }
  }
  if (edges[length(edges)] <= 0) {
    prob <- prob + hist$overflow
  } else if (edges[1] > 0) {
    prob <- prob + hist$underflow
  }
  prob / n_total
}

summary_parts <- vector("list", length(metric_names) + 1L)

for (i in seq_along(metric_names)) {
  nm <- metric_names[[i]]
  s <- merged$stats[[nm]]
  hs <- hist_summary(merged$hist[[nm]])
  summary_parts[[i]] <- data.frame(
    metric = nm,
    mean = s$mean,
    var = s$var,
    p05 = hs$p05,
    p50 = hs$p50,
    p95 = hs$p95,
    stringsAsFactors = FALSE
  )
}

p_diff_gt_zero <- prob_gt_zero(merged$hist$diff_gco2)
summary_parts[[length(summary_parts)]] <- data.frame(
  metric = "diff_gco2_gt_zero",
  mean = p_diff_gt_zero,
  var = NA_real_,
  p05 = NA_real_,
  p50 = NA_real_,
  p95 = NA_real_,
  stringsAsFactors = FALSE
)
summary_rows <- do.call(rbind, summary_parts)

outdir <- file.path("outputs", "aggregate")
if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
utils::write.csv(summary_rows, file.path(outdir, "results_summary.csv"), row.names = FALSE)

for (nm in metric_names) {
  h <- merged$hist[[nm]]
  bins <- data.frame(
    bin_left = h$bin_edges[-length(h$bin_edges)],
    bin_right = h$bin_edges[-1],
    count = h$counts,
    stringsAsFactors = FALSE
  )
  utils::write.csv(bins, file.path(outdir, paste0("hist_", nm, ".csv")), row.names = FALSE)
}

metadata <- list(
  run_group_id = opt$run_group,
  mode = mode,
  distance_mode = distance_mode,
  model_version = ref$model_version,
  inputs_hash = ref$inputs_hash,
  metric_definitions_hash = ref$metric_definitions_hash,
  chunk_count = length(keep),
  n_total = merged$stats[[1]]$n,
  timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  notes = "Quantiles from merged histogram; diff_gco2>0 probability uses uniform-within-bin approximation."
)
writeLines(jsonlite::toJSON(metadata, auto_unbox = TRUE, pretty = TRUE),
           file.path(outdir, "aggregate_metadata.json"))

message("Aggregation complete: ", outdir)
log_event("INFO", "complete", sprintf("aggregate complete: outdir=%s", outdir))
