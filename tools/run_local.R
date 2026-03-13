#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--scenario"), type = "character", default = "SMOKE_LOCAL", help = "Scenario selector (scenario_id or variant_id)"),
  make_option(c("--n"), type = "integer", default = 5000L, help = "Number of samples"),
  make_option(c("--seed"), type = "integer", default = 123L, help = "Seed"),
  make_option(c("--outdir"), type = "character", default = "outputs/local", help = "Output directory"),
  make_option(c("--mode"), type = "character", default = "SMOKE_LOCAL", help = "Run mode: SMOKE_LOCAL or REAL_RUN"),
  make_option(c("--distance_mode"), type = "character", default = "FAF_DISTRIBUTION", help = "Distance mode: FAF_DISTRIBUTION, ROAD_NETWORK_FIXED_DEST, ROAD_NETWORK_PHYSICS")
)

opt <- parse_args(OptionParser(option_list = option_list))
mode <- normalize_run_mode(opt$mode)
distance_mode <- normalize_distance_mode(opt$distance_mode)
Sys.setenv(DISTANCE_MODE = distance_mode)

configure_log(
  tag  = "run_local",
  seed = as.character(opt$seed),
  lane = Sys.getenv("COLDCHAIN_LANE", unset = "local")
)
log_event("INFO", "start", sprintf(
  "run_local starting: scenario=%s n=%d mode=%s seed=%d",
  opt$scenario, opt$n, opt$mode, opt$seed
))

inputs <- read_inputs_local()
validate_sampling_priors(inputs$sampling_priors)
assert_scenarios_distance_linkage(inputs$scenarios, inputs$distance_distributions)
assert_variant_dimensions_present(inputs$scenario_matrix)

variant_rows <- select_variant_rows(inputs, opt$scenario)
hist_config <- list(
  metric = inputs$histogram_config$metric,
  min = inputs$histogram_config$min,
  max = inputs$histogram_config$max,
  bins = inputs$histogram_config$bins
)
validate_hist_config(hist_config)

if (!dir.exists(opt$outdir)) dir.create(opt$outdir, recursive = TRUE)

for (i in seq_len(nrow(variant_rows))) {
  variant_row <- variant_rows[i, , drop = FALSE]
  resolved <- resolve_variant_inputs(inputs, variant_row, mode = mode)

  assert_mode_data_ready(
    mode,
    inputs$scenarios,
    inputs$histogram_config,
    scenario_name = variant_row$scenario_id[[1]],
    variant_row = variant_row,
    inputs = inputs,
    priors_map = resolved$priors,
    distance_mode = distance_mode
  )
  validate_inputs(resolved$inputs_list)

  seed_used <- as.integer(opt$seed + i - 1L)
  chunk <- run_monte_carlo_chunk(
    inputs = resolved$inputs_list,
    hist_config = hist_config,
    n = as.integer(opt$n),
    seed = seed_used
  )
  enforce_hist_coverage(
    hist_list = chunk$hist,
    n_list = lapply(chunk$stats, function(s) s$n),
    mode = mode,
    threshold = 0.001,
    context = paste0("run_local variant=", variant_row$variant_id[[1]])
  )

  outdir_variant <- if (nrow(variant_rows) == 1) opt$outdir else file.path(opt$outdir, variant_row$variant_id[[1]])
  if (!dir.exists(outdir_variant)) dir.create(outdir_variant, recursive = TRUE)
  write_results_summary(chunk$stats, file.path(outdir_variant, "results_summary.csv"), hist = chunk$hist)

  metadata <- list(
    selector = opt$scenario,
    variant_id = variant_row$variant_id[[1]],
    scenario_id = variant_row$scenario_id[[1]],
    product_mode = resolved$variant_dims$product_mode,
    spatial_structure = resolved$variant_dims$spatial_structure,
    powertrain_config = resolved$variant_dims$powertrain_config,
    regionalized_distance_scale = resolved$inputs_list$regionalized_distance_scale,
    distance_mode = distance_mode,
    mode = mode,
    n = as.integer(opt$n),
    seed = seed_used,
    rng_kind = chunk$metadata$rng_kind,
    sampled_variables = names(resolved$inputs_list$sampling),
    timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )
  writeLines(
    jsonlite::toJSON(metadata, auto_unbox = TRUE, pretty = TRUE),
    file.path(outdir_variant, "run_metadata.json")
  )

  draws_out <- chunk$draws
  draws_out$variant_id <- variant_row$variant_id[[1]]
  draws_out$scenario_id <- variant_row$scenario_id[[1]]
  draws_out$product_mode <- resolved$variant_dims$product_mode
  draws_out$spatial_structure <- resolved$variant_dims$spatial_structure
  draws_out$powertrain_config <- resolved$variant_dims$powertrain_config
  utils::write.csv(draws_out, gzfile(file.path(outdir_variant, "draws.csv.gz")), row.names = FALSE)
}

message("Local run complete: ", opt$outdir)
log_event("INFO", "complete", sprintf("run_local complete: outdir=%s", opt$outdir))
