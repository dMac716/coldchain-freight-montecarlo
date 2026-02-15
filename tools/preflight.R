#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--mode"), type = "character", default = "SMOKE_LOCAL", help = "Run mode: SMOKE_LOCAL or REAL_RUN"),
  make_option(c("--scenario"), type = "character", default = "SMOKE_LOCAL", help = "Scenario selector (scenario_id or variant_id)"),
  make_option(c("--run_group"), type = "character", default = "SMOKE_LOCAL", help = "Run group used for chunk compatibility checks")
)
opt <- parse_args(OptionParser(option_list = option_list))
mode <- normalize_run_mode(opt$mode)

inputs <- read_inputs_local()
validate_sampling_priors(inputs$sampling_priors)
assert_scenarios_distance_linkage(inputs$scenarios, inputs$distance_distributions)

hist_config <- list(
  metric = inputs$histogram_config$metric,
  min = inputs$histogram_config$min,
  max = inputs$histogram_config$max,
  bins = inputs$histogram_config$bins
)
validate_hist_config(hist_config)

variant_rows <- select_variant_rows(inputs, opt$scenario)
if (nrow(variant_rows) == 0) stop("No variants selected for scenario: ", opt$scenario)

for (i in seq_len(nrow(variant_rows))) {
  variant_row <- variant_rows[i, , drop = FALSE]
  resolved <- resolve_variant_inputs(inputs, variant_row = variant_row, mode = mode)
  assert_mode_data_ready(
    mode,
    inputs$scenarios,
    inputs$histogram_config,
    scenario_name = variant_row$scenario_id[[1]],
    variant_row = variant_row,
    inputs = inputs,
    priors_map = resolved$priors
  )
  validate_inputs(resolved$inputs_list)
}

chunk_dir <- "contrib/chunks"
files <- if (dir.exists(chunk_dir)) {
  list.files(chunk_dir, pattern = paste0("^chunk_", opt$run_group, ".*\\.json$"), full.names = TRUE)
} else {
  character(0)
}

if (length(files) > 1) {
  model <- character(length(files))
  in_hash <- character(length(files))
  met_hash <- character(length(files))
  for (i in seq_along(files)) {
    a <- jsonlite::fromJSON(files[[i]], simplifyVector = FALSE)
    model[[i]] <- a$model_version
    in_hash[[i]] <- a$inputs_hash
    met_hash[[i]] <- a$metric_definitions_hash
  }
  if (length(unique(model)) > 1 || length(unique(in_hash)) > 1 || length(unique(met_hash)) > 1) {
    stop(
      "Mixed chunk artifacts detected for run_group=", opt$run_group,
      ". Run `make clean-chunks` before new runs."
    )
  }
}

cat("Preflight OK\n")
cat("  mode:", mode, "\n")
cat("  scenario selector:", opt$scenario, "\n")
cat("  variants:", nrow(variant_rows), "\n")
cat("  chunk files checked:", length(files), "\n")
