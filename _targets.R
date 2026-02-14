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
    scenario_row,
    subset(inputs_raw$scenarios, scenario == "BASE")[1, , drop = FALSE]
  ),
  tar_target(
    product_row,
    subset(inputs_raw$products, product_name == scenario_row$product_name)[1, , drop = FALSE]
  ),
  tar_target(
    inputs_list,
    {
      x <- resolve_inputs(scenario_row, product_row)
      x$sampling <- build_sampling_from_factors(inputs_raw$factors, scenario_name = "BASE")
      x
    }
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
    run_monte_carlo_chunk(inputs_list, hist_config, n = 5000, seed = 123)
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
