#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(digest)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--scenario"), type = "character", help = "Scenario name"),
  make_option(c("--n"), type = "integer", help = "Number of samples"),
  make_option(c("--seed"), type = "integer", default = NA_integer_, help = "Seed (optional)"),
  make_option(c("--outdir"), type = "character", default = "outputs/local", help = "Output directory"),
  make_option(c("--mode"), type = "character", default = "SMOKE_LOCAL", help = "Run mode: SMOKE_LOCAL or REAL_RUN")
)

opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$scenario) || is.null(opt$n)) {
  stop("--scenario and --n are required.")
}
mode <- normalize_run_mode(opt$mode)

inputs <- read_inputs_local()
scenarios <- inputs$scenarios
products <- inputs$products
factors <- inputs$factors
hist_config_df <- inputs$histogram_config

scenario_row <- subset(scenarios, scenario == opt$scenario)
if (nrow(scenario_row) == 0) stop("Scenario not found.")
scenario_row <- scenario_row[1, , drop = FALSE]

product_row <- subset(products, product_name == scenario_row$product_name)
if (nrow(product_row) == 0) stop("Product not found for scenario.")
product_row <- product_row[1, , drop = FALSE]

inputs_list <- resolve_inputs(scenario_row, product_row)
inputs_list$sampling <- build_sampling_from_factors(factors, scenario_name = opt$scenario)

hist_config <- list(
  metric = hist_config_df$metric,
  min = hist_config_df$min,
  max = hist_config_df$max,
  bins = hist_config_df$bins
)
validate_hist_config(hist_config)
assert_mode_data_ready(mode, scenarios, hist_config_df, scenario_name = opt$scenario)
validate_inputs(inputs_list)

seed_used <- if (is.na(opt$seed)) sample.int(.Machine$integer.max, 1) else opt$seed

chunk <- run_monte_carlo_chunk(inputs = inputs_list, hist_config = hist_config, n = opt$n, seed = seed_used)
enforce_hist_coverage(
  hist_list = chunk$hist,
  n_list = lapply(chunk$stats, function(s) s$n),
  mode = mode,
  threshold = 0.001,
  context = paste0("run_chunk scenario=", opt$scenario)
)

# Write local outputs
if (!dir.exists(opt$outdir)) dir.create(opt$outdir, recursive = TRUE)
write_results_summary(chunk$stats, file.path(opt$outdir, "results_summary.csv"))

run_metadata <- list(
  scenario = opt$scenario,
  mode = mode,
  n = opt$n,
  seed = seed_used,
  rng_kind = chunk$metadata$rng_kind,
  sampled_variables = names(inputs_list$sampling),
  timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
)
writeLines(jsonlite::toJSON(run_metadata, auto_unbox = TRUE, pretty = TRUE),
           file.path(opt$outdir, "run_metadata.json"))

# Build resolved inputs table for hashing.
resolved_parts <- list()
base_fields <- c(
  "FU_kcal", "kcal_per_kg_dry", "kcal_per_kg_reefer",
  "pkg_kg_per_kg_dry", "pkg_kg_per_kg_reefer",
  "distance_miles", "truck_g_per_ton_mile", "reefer_extra_g_per_ton_mile",
  "util_dry", "util_reefer"
)
for (nm in base_fields) {
  resolved_parts[[length(resolved_parts) + 1]] <- data.frame(
    name = nm,
    value = inputs_list[[nm]],
    kind = "base",
    stringsAsFactors = FALSE
  )
}
if (length(inputs_list$sampling) > 0) {
  for (nm in names(inputs_list$sampling)) {
    tri <- inputs_list$sampling[[nm]]
    resolved_parts[[length(resolved_parts) + 1]] <- data.frame(
      name = paste0(nm, "_min"),
      value = tri$min,
      kind = "sampling",
      stringsAsFactors = FALSE
    )
    resolved_parts[[length(resolved_parts) + 1]] <- data.frame(
      name = paste0(nm, "_mode"),
      value = tri$mode,
      kind = "sampling",
      stringsAsFactors = FALSE
    )
    resolved_parts[[length(resolved_parts) + 1]] <- data.frame(
      name = paste0(nm, "_max"),
      value = tri$max,
      kind = "sampling",
      stringsAsFactors = FALSE
    )
  }
}
resolved_rows <- do.call(rbind, resolved_parts)
inputs_resolved_path <- file.path(opt$outdir, "inputs_resolved.csv")
write.csv(resolved_rows, inputs_resolved_path, row.names = FALSE)

inputs_hash <- sha256_file(inputs_resolved_path)
metric_definitions_hash <- sha256_file(file.path("data/inputs_local", "histogram_config.csv"))

model_version <- "nogit"
git_bin <- Sys.which("git")
if (nzchar(git_bin) && dir.exists(".git")) {
  git_out <- tryCatch(
    suppressWarnings(system2(git_bin, c("rev-parse", "--short", "HEAD"), stdout = TRUE, stderr = FALSE)),
    error = function(e) character()
  )
  if (length(git_out) > 0 && nzchar(git_out[[1]])) {
    model_version <- trimws(git_out[[1]])
  }
}

run_group_id <- opt$scenario
run_id <- paste0(
  run_group_id, "_",
  format(Sys.time(), "%Y%m%dT%H%M%S", tz = "UTC"),
  "_", sample(1000:9999, 1)
)

metrics_payload <- list()
for (nm in names(chunk$stats)) {
  h <- chunk$hist[[nm]]
  metrics_payload[[nm]] <- list(
    n = chunk$stats[[nm]]$n,
    sum = chunk$stats[[nm]]$sum,
    sum_sq = chunk$stats[[nm]]$sum_sq,
    min = chunk$stats[[nm]]$min,
    max = chunk$stats[[nm]]$max,
    histogram = list(
      bin_edges = unname(h$bin_edges),
      bin_counts = unname(h$counts),
      underflow = h$underflow,
      overflow = h$overflow
    )
  )
}

artifact <- list(
  run_id = run_id,
  run_group_id = run_group_id,
  model_version = model_version,
  inputs_hash = inputs_hash,
  metric_definitions_hash = metric_definitions_hash,
  timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  rng_kind = chunk$metadata$rng_kind,
  seed = as.integer(seed_used),
  n_chunk = opt$n,
  metrics = metrics_payload,
  integrity = list(
    artifact_sha256 = paste(rep("0", 64), collapse = ""),
    inputs_resolved_sha256 = inputs_hash
  )
)

if (!dir.exists("contrib/chunks")) dir.create("contrib/chunks", recursive = TRUE)
artifact_path <- file.path("contrib/chunks", paste0("chunk_", run_group_id, "_", run_id, ".json"))
writeLines(jsonlite::toJSON(artifact, auto_unbox = TRUE, pretty = TRUE), artifact_path)

artifact_sha <- artifact_canonical_sha256_from_file(artifact_path)
artifact_roundtrip <- jsonlite::fromJSON(artifact_path, simplifyVector = FALSE)
artifact_roundtrip$integrity$artifact_sha256 <- artifact_sha
writeLines(jsonlite::toJSON(artifact_roundtrip, auto_unbox = TRUE, pretty = TRUE), artifact_path)

message("Chunk written: ", artifact_path)
