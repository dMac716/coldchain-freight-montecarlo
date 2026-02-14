#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--scenario"), type = "character", default = "SMOKE_LOCAL", help = "Scenario name"),
  make_option(c("--n"), type = "integer", default = 5000L, help = "Number of samples"),
  make_option(c("--seed"), type = "integer", default = 123L, help = "Seed"),
  make_option(c("--outdir"), type = "character", default = "outputs/local", help = "Output directory")
)

opt <- parse_args(OptionParser(option_list = option_list))

inputs <- read_inputs_local()
scenario_row <- subset(inputs$scenarios, scenario == opt$scenario)
if (nrow(scenario_row) == 0) stop("Scenario not found.")
scenario_row <- scenario_row[1, , drop = FALSE]

product_row <- subset(inputs$products, product_name == scenario_row$product_name)
if (nrow(product_row) == 0) stop("Product not found for scenario.")
product_row <- product_row[1, , drop = FALSE]

inputs_list <- resolve_inputs(scenario_row, product_row)
inputs_list$sampling <- build_sampling_from_factors(inputs$factors, scenario_name = opt$scenario)
validate_inputs(inputs_list)

hist_config <- list(
  metric = inputs$histogram_config$metric,
  min = inputs$histogram_config$min,
  max = inputs$histogram_config$max,
  bins = inputs$histogram_config$bins
)
validate_hist_config(hist_config)

chunk <- run_monte_carlo_chunk(
  inputs = inputs_list,
  hist_config = hist_config,
  n = as.integer(opt$n),
  seed = as.integer(opt$seed)
)

if (!dir.exists(opt$outdir)) dir.create(opt$outdir, recursive = TRUE)
write_results_summary(chunk$stats, file.path(opt$outdir, "results_summary.csv"))

metadata <- list(
  scenario = opt$scenario,
  n = as.integer(opt$n),
  seed = as.integer(opt$seed),
  rng_kind = chunk$metadata$rng_kind,
  timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
)
writeLines(
  jsonlite::toJSON(metadata, auto_unbox = TRUE, pretty = TRUE),
  file.path(opt$outdir, "run_metadata.json")
)

message("Local run complete: ", opt$outdir)
