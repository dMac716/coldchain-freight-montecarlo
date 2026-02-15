#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(digest)
})

run_cmd <- function(cmd, args, stdin = NULL) {
  out <- tryCatch(
    system2(cmd, args, input = stdin, stdout = TRUE, stderr = TRUE),
    error = function(e) stop("Failed running ", cmd, ": ", conditionMessage(e))
  )
  status <- attr(out, "status")
  list(status = if (is.null(status)) 0L else as.integer(status), out = out)
}

option_list <- list(
  make_option(c("--project"), type = "character"),
  make_option(c("--dataset"), type = "character"),
  make_option(c("--location"), type = "character"),
  make_option(c("--table"), type = "character"),
  make_option(c("--sql"), type = "character", default = "tools/faf_bq/query_distance_distributions.sql"),
  make_option(c("--out_csv"), type = "character", default = "data/derived/faf_distance_distributions.csv"),
  make_option(c("--out_meta"), type = "character", default = "data/derived/faf_distance_distributions_bq_metadata.json"),
  make_option(c("--gcs_uri"), type = "character", default = "")
)
opt <- parse_args(OptionParser(option_list = option_list))

required <- c("project", "dataset", "location", "table")
missing <- required[vapply(required, function(x) is.null(opt[[x]]) || !nzchar(opt[[x]]), logical(1))]
if (length(missing) > 0) stop("Missing required args: ", paste(missing, collapse = ", "))
if (!file.exists(opt$sql)) stop("SQL file not found: ", opt$sql)
if (Sys.which("bq") == "") stop("bq CLI not found in PATH.")

sql <- paste(readLines(opt$sql, warn = FALSE), collapse = "\n")
table_fqn <- paste0(opt$project, ".", opt$dataset, ".", opt$table)
sql <- gsub("\\{\\{TABLE_FQN\\}\\}", table_fqn, sql)

query <- run_cmd(
  "bq",
  c(
    paste0("--location=", toupper(opt$location)),
    "query",
    "--use_legacy_sql=false",
    "--format=csv"
  ),
  stdin = sql
)
if (query$status != 0L) {
  stop("bq query failed:\n", paste(query$out, collapse = "\n"))
}

csv_text <- paste(query$out, collapse = "\n")
tmp_csv <- tempfile(fileext = ".csv")
writeLines(csv_text, tmp_csv)
raw <- utils::read.csv(tmp_csv, stringsAsFactors = FALSE)

for (nm in c("p05_miles", "p50_miles", "p95_miles", "mean_miles", "min_miles", "max_miles", "n_records")) {
  if (nm %in% names(raw)) raw[[nm]] <- as.numeric(raw[[nm]])
}

# Project-specific output schema expected by runtime tools.
out <- data.frame(
  distance_distribution_id = ifelse(raw$scenario_id == "CENTRALIZED", "dist_centralized_food_truck_2024", "dist_regionalized_food_truck_2024"),
  scenario_id = raw$scenario_id,
  source_zip = "FAF5.7.1_2018-2024.csv@GCS",
  commodity_filter = "sctg2 in [01,02,03,04,05,06,07,08]",
  mode_filter = ifelse(raw$scenario_id == "CENTRALIZED", "dms_mode==1", "dms_mode==1 and dist_band<=4"),
  distance_model = "triangular_fit",
  p05_miles = raw$p05_miles,
  p50_miles = raw$p50_miles,
  p95_miles = raw$p95_miles,
  mean_miles = raw$mean_miles,
  min_miles = raw$min_miles,
  max_miles = raw$max_miles,
  n_records = raw$n_records,
  status = "OK",
  source_id = "faf5_7_1_2018_2024_zip",
  notes = "Computed in BigQuery from GCS-loaded FAF OD with tons_2024 weighting.",
  stringsAsFactors = FALSE
)

# Keep synthetic smoke row for offline smoke workflows.
smoke <- data.frame(
  distance_distribution_id = "dist_smoke_local",
  scenario_id = "SMOKE_LOCAL",
  source_zip = "synthetic",
  commodity_filter = "n/a",
  mode_filter = "n/a",
  distance_model = "fixed",
  p05_miles = 1200,
  p50_miles = 1200,
  p95_miles = 1200,
  mean_miles = 1200,
  min_miles = 1200,
  max_miles = 1200,
  n_records = 1,
  status = "SMOKE_READY",
  source_id = "scope_locked_proposal_2026",
  notes = "Synthetic smoke distribution.",
  stringsAsFactors = FALSE
)
out <- rbind(out, smoke)

out <- out[order(out$scenario_id), , drop = FALSE]
dir.create(dirname(opt$out_csv), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, opt$out_csv, row.names = FALSE)

meta <- list(
  generated_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  pipeline = "optional_bigquery",
  project_id = opt$project,
  dataset = opt$dataset,
  table = opt$table,
  location = toupper(opt$location),
  gcs_uri = opt$gcs_uri,
  source_id = "faf5_7_1_2018_2024_zip",
  sql_sha256 = digest(sql, algo = "sha256", serialize = FALSE),
  commodity_filter = "sctg2 in [01-08]",
  mode_filter = "dms_mode==1"
)
writeLines(jsonlite::toJSON(meta, auto_unbox = TRUE, pretty = TRUE), opt$out_meta)

cat("Wrote:", opt$out_csv, "and", opt$out_meta, "\n")
