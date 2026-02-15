#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(digest)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--scenario"), type = "character", help = "Scenario selector (scenario_id or variant_id)"),
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
validate_sampling_priors(inputs$sampling_priors)
assert_scenarios_distance_linkage(inputs$scenarios, inputs$distance_distributions)

variant_rows <- select_variant_rows(inputs, opt$scenario)
if (nrow(variant_rows) == 0) stop("No scenario variants selected.")

hist_config_df <- inputs$histogram_config
hist_config <- list(
  metric = hist_config_df$metric,
  min = hist_config_df$min,
  max = hist_config_df$max,
  bins = hist_config_df$bins
)
validate_hist_config(hist_config)

if (!dir.exists(opt$outdir)) dir.create(opt$outdir, recursive = TRUE)
if (!dir.exists("contrib/chunks")) dir.create("contrib/chunks", recursive = TRUE)

seed_base <- if (is.na(opt$seed)) sample.int(.Machine$integer.max, 1) else as.integer(opt$seed)

for (i in seq_len(nrow(variant_rows))) {
  variant_row <- variant_rows[i, , drop = FALSE]
  variant_id <- variant_row$variant_id[[1]]

  resolved <- resolve_variant_inputs(inputs, variant_row = variant_row, mode = mode)
  inputs_list <- resolved$inputs_list

  assert_mode_data_ready(
    mode,
    inputs$scenarios,
    hist_config_df,
    scenario_name = variant_row$scenario_id[[1]],
    variant_row = variant_row,
    inputs = inputs,
    priors_map = resolved$priors
  )
  validate_inputs(inputs_list)

  seed_used <- as.integer(seed_base + i - 1L)
  chunk <- run_monte_carlo_chunk(inputs = inputs_list, hist_config = hist_config, n = opt$n, seed = seed_used)
  enforce_hist_coverage(
    hist_list = chunk$hist,
    n_list = lapply(chunk$stats, function(s) s$n),
    mode = mode,
    threshold = 0.001,
    context = paste0("run_chunk variant=", variant_id)
  )

  outdir_variant <- if (nrow(variant_rows) == 1) opt$outdir else file.path(opt$outdir, variant_id)
  if (!dir.exists(outdir_variant)) dir.create(outdir_variant, recursive = TRUE)
  write_results_summary(chunk$stats, file.path(outdir_variant, "results_summary.csv"))

  run_metadata <- list(
    selector = opt$scenario,
    variant_id = variant_id,
    scenario_id = variant_row$scenario_id[[1]],
    run_group = variant_row$run_group[[1]],
    mode = mode,
    n = opt$n,
    seed = seed_used,
    rng_kind = chunk$metadata$rng_kind,
    sampled_variables = names(inputs_list$sampling),
    timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )
  writeLines(jsonlite::toJSON(run_metadata, auto_unbox = TRUE, pretty = TRUE),
             file.path(outdir_variant, "run_metadata.json"))

  resolved_parts <- list()
  base_fields <- required_model_param_ids()
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
      sp <- inputs_list$sampling[[nm]]
      resolved_parts[[length(resolved_parts) + 1]] <- data.frame(
        name = paste0(nm, "_distribution"),
        value = sp$distribution,
        kind = "sampling",
        stringsAsFactors = FALSE
      )
      resolved_parts[[length(resolved_parts) + 1]] <- data.frame(
        name = paste0(nm, "_p1"),
        value = sp$p1,
        kind = "sampling",
        stringsAsFactors = FALSE
      )
      resolved_parts[[length(resolved_parts) + 1]] <- data.frame(
        name = paste0(nm, "_p2"),
        value = ifelse(is.null(sp$p2), NA, sp$p2),
        kind = "sampling",
        stringsAsFactors = FALSE
      )
      resolved_parts[[length(resolved_parts) + 1]] <- data.frame(
        name = paste0(nm, "_p3"),
        value = ifelse(is.null(sp$p3), NA, sp$p3),
        kind = "sampling",
        stringsAsFactors = FALSE
      )
    }
  }
  resolved_rows <- do.call(rbind, resolved_parts)
  inputs_resolved_path <- file.path(outdir_variant, "inputs_resolved.csv")
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

  run_group_id <- variant_row$run_group[[1]]
  run_id <- paste0(
    run_group_id, "_", variant_id, "_",
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

  artifact_path <- file.path("contrib/chunks", paste0("chunk_", run_group_id, "_", run_id, ".json"))
  writeLines(jsonlite::toJSON(artifact, auto_unbox = TRUE, pretty = TRUE), artifact_path)

  artifact_sha <- artifact_canonical_sha256_from_file(artifact_path)
  artifact_roundtrip <- jsonlite::fromJSON(artifact_path, simplifyVector = FALSE)
  artifact_roundtrip$integrity$artifact_sha256 <- artifact_sha
  writeLines(jsonlite::toJSON(artifact_roundtrip, auto_unbox = TRUE, pretty = TRUE), artifact_path)

  message("Chunk written: ", artifact_path)
}
