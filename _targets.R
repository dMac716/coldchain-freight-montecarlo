library(targets)

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

tar_option_set(
  packages = c("digest", "jsonlite")
)

list(
  tar_target(
    inputs_raw,
    read_inputs_local()
  ),
  tar_target(
    smoke_variant,
    select_variant_rows(inputs_raw, "SMOKE_LOCAL")[1, , drop = FALSE]
  ),
  tar_target(
    resolved_smoke,
    resolve_variant_inputs(inputs_raw, smoke_variant, mode = "SMOKE_LOCAL")
  ),
  tar_target(
    hist_config,
    list(
      metric = inputs_raw$histogram_config$metric,
      min = inputs_raw$histogram_config$min,
      max = inputs_raw$histogram_config$max,
      bins = inputs_raw$histogram_config$bins
    )
  ),
  tar_target(
    chunk_results,
    run_monte_carlo_chunk(resolved_smoke$inputs_list, hist_config, n = 5000, seed = 123)
  ),
  tar_target(
    write_local_outputs,
    {
      outdir <- "outputs/local"
      if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)
      write_results_summary(chunk_results$stats, file.path(outdir, "results_summary.csv"))
      file.path(outdir, "results_summary.csv")
    },
    format = "file"
  )
)
