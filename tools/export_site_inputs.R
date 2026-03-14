#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(data.table)
})

duckdb_csv_query <- function(db, sql) {
  out <- tryCatch(system2("duckdb", args = c(db, "-csv"), input = sql, stdout = TRUE, stderr = TRUE), error = function(e) character())
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) stop(paste(out, collapse = "\n"))
  if (length(out) == 0) return(data.table())
  fread(text = paste(out, collapse = "\n"), showProgress = FALSE)
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--db"), type = "character", default = "analysis/transport_catalog.duckdb"),
  make_option(c("--run_id"), type = "character", default = "latest"),
  make_option(c("--outdir"), type = "character", default = "site/data/transport")
)))

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

run_id <- opt$run_id
if (identical(run_id, "latest")) {
  latest <- duckdb_csv_query(opt$db, paste(
    "SELECT run_id FROM runs",
    "WHERE validation_passed = TRUE",
    "ORDER BY timestamp_utc DESC LIMIT 1"
  ))
  if (nrow(latest) == 0) stop("No validation-passed runs found in runs table")
  run_id <- as.character(latest$run_id[[1]])
}

crossed_summary <- duckdb_csv_query(opt$db, sprintf("SELECT * FROM crossed_summary WHERE run_id = '%s' ORDER BY scenario_cell, metric", run_id))
effects <- duckdb_csv_query(opt$db, sprintf("SELECT * FROM decomposition WHERE run_id = '%s' ORDER BY effect, comparison, metric", run_id))
realistic_rows <- duckdb_csv_query(opt$db, sprintf("SELECT * FROM realistic_results WHERE run_id = '%s' ORDER BY replicate_id, scenario_name", run_id))
graphics <- duckdb_csv_query(opt$db, sprintf(paste(
  "SELECT run_id, layer_type, scenario_name, powertrain,",
  "AVG(co2_per_1000kcal) AS mean_co2_per_1000kcal,",
  "QUANTILE_CONT(co2_per_1000kcal, 0.05) AS p05_co2_per_1000kcal,",
  "QUANTILE_CONT(co2_per_1000kcal, 0.95) AS p95_co2_per_1000kcal",
  "FROM realistic_results WHERE run_id = '%s'",
  "GROUP BY 1,2,3,4 ORDER BY scenario_name"
), run_id))

fwrite(crossed_summary, file.path(opt$outdir, "crossed_factory_transport_summary.csv"))
fwrite(effects, file.path(opt$outdir, "transport_effect_decomposition.csv"))
fwrite(realistic_rows, file.path(opt$outdir, "transport_sim_rows.csv"))
fwrite(graphics, file.path(opt$outdir, "transport_sim_graphics_inputs.csv"))
cat(opt$outdir, "\n", sep = "")
