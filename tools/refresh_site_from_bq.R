#!/usr/bin/env Rscript

# Disabled external contributions for now (local-only branch).
# Original BigQuery refresh implementation is intentionally kept below for easy restore.
stop("Disabled in local-only mode: tools/refresh_site_from_bq.R (BigQuery refresh disabled).")

suppressPackageStartupMessages({
  library(optparse)
})

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--project"), type = "character", default = Sys.getenv("GCP_PROJECT", "")),
  make_option(c("--dataset"), type = "character", default = Sys.getenv("BQ_DATASET", "coldchain_sim")),
  make_option(c("--n"), type = "integer", default = 50L),
  make_option(c("--outdir"), type = "character", default = "site/data")
)))

if (!nzchar(opt$project)) stop("--project or GCP_PROJECT is required")
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

run_query <- function(sql, out_csv) {
  args <- c(
    "--project_id", opt$project,
    "query",
    "--use_legacy_sql=false",
    "--format=csv",
    sql
  )
  out <- tryCatch(system2("bq", args = args, stdout = TRUE, stderr = TRUE), error = function(e) stop("failed to run bq query: ", conditionMessage(e)))
  if (length(out) == 0) stop("bq query produced no output")
  writeLines(out, out_csv)
  out_csv
}

n <- as.integer(opt$n)
prj <- opt$project
ds <- opt$dataset

sql_runs <- sprintf(
  "SELECT run_id, created_at_utc, runner, status, scenario, route_id, route_plan_id, seed, mc_draws, gcs_prefix, inputs_hash\nFROM `%s.%s.runs`\nORDER BY created_at_utc DESC\nLIMIT %d",
  prj, ds, n
)

sql_summaries <- sprintf(
  "WITH latest AS (\n  SELECT run_id\n  FROM `%s.%s.runs`\n  ORDER BY created_at_utc DESC\n  LIMIT %d\n)\nSELECT s.*\nFROM `%s.%s.summaries` s\nJOIN latest l USING(run_id)",
  prj, ds, n, prj, ds
)

runs_out <- file.path(opt$outdir, "runs_latest.csv")
summ_out <- file.path(opt$outdir, "summaries_latest.csv")
run_query(sql_runs, runs_out)
run_query(sql_summaries, summ_out)

cat("Wrote", runs_out, "\n")
cat("Wrote", summ_out, "\n")
