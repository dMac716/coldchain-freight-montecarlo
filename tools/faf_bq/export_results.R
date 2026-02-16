#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(digest)
})

log_info <- function(...) cat("[faf_bq] ", paste0(..., collapse = ""), "\n", sep = "")

run_cmd <- function(cmd, args, stdin = NULL) {
  out <- tryCatch(
    system2(cmd, args, input = stdin, stdout = TRUE, stderr = TRUE),
    error = function(e) stop("Failed running ", cmd, ": ", conditionMessage(e))
  )
  status <- attr(out, "status")
  list(status = if (is.null(status)) 0L else as.integer(status), out = out)
}

run_bq_query_csv <- function(location, sql_text) {
  query <- run_cmd(
    "bq",
    c(
      paste0("--location=", toupper(location)),
      "query",
      "--use_legacy_sql=false",
      "--format=csv"
    ),
    stdin = sql_text
  )
  if (query$status != 0L) stop("bq query failed:\n", paste(query$out, collapse = "\n"))
  txt <- paste(query$out, collapse = "\n")
  tmp <- tempfile(fileext = ".csv")
  writeLines(txt, tmp)
  utils::read.csv(tmp, stringsAsFactors = FALSE)
}

option_list <- list(
  make_option(c("--project"), type = "character"),
  make_option(c("--dataset"), type = "character"),
  make_option(c("--location"), type = "character"),
  make_option(c("--table"), type = "character"),
  make_option(c("--weight_col"), type = "character", default = "tons_2024"),
  make_option(c("--sql_distance"), type = "character", default = "tools/faf_bq/query_distance_distributions.sql"),
  make_option(c("--sql_top_flows"), type = "character", default = "tools/faf_bq/query_top_od_flows.sql"),
  make_option(c("--top_n"), type = "integer", default = 200L),
  make_option(c("--out_distance_csv"), type = "character", default = "data/derived/faf_distance_distributions.csv"),
  make_option(c("--out_flows_csv"), type = "character", default = "data/derived/faf_top_od_flows.csv"),
  make_option(c("--out_meta"), type = "character", default = "data/derived/faf_distance_distributions_bq_metadata.json"),
  make_option(c("--gcs_uri"), type = "character", default = "")
)
opt <- parse_args(OptionParser(
  usage = "%prog [options]",
  description = "Run BigQuery SQL exports for FAF distance distributions and top OD flow artifacts.",
  option_list = option_list
))

validate_identifier <- function(name, value) {
  if (!grepl("^[A-Za-z0-9_]+$", value)) {
    stop(sprintf("Invalid %s '%s'; must match ^[A-Za-z0-9_]+$", name, value))
  }
}

required <- c("project", "dataset", "location", "table")
missing <- required[vapply(required, function(x) is.null(opt[[x]]) || !nzchar(opt[[x]]), logical(1))]
if (length(missing) > 0) stop("Missing required args: ", paste(missing, collapse = ", "))
if (!file.exists(opt$sql_distance)) stop("SQL file not found: ", opt$sql_distance)
if (!file.exists(opt$sql_top_flows)) stop("SQL file not found: ", opt$sql_top_flows)
if (Sys.which("bq") == "") stop("bq CLI not found in PATH.")

table_fqn <- paste0(opt$project, ".", opt$dataset, ".", opt$table)
validate_identifier("project", opt$project)
validate_identifier("dataset", opt$dataset)
validate_identifier("table", opt$table)

sql_dist <- paste(readLines(opt$sql_distance, warn = FALSE), collapse = "\n")
sql_dist <- gsub("\\{\\{TABLE_FQN\\}\\}", table_fqn, sql_dist)
weight_col <- tolower(trimws(opt$weight_col))
if (!weight_col %in% c("tons_2024", "tmiles_2024")) {
  stop("--weight_col must be one of: tons_2024, tmiles_2024")
}
sql_dist <- gsub("\\{\\{WEIGHT_COL\\}\\}", weight_col, sql_dist)

sql_flows <- paste(readLines(opt$sql_top_flows, warn = FALSE), collapse = "\n")
sql_flows <- gsub("\\{\\{TABLE_FQN\\}\\}", table_fqn, sql_flows)
sql_flows <- gsub("\\{\\{TOP_N\\}\\}", as.character(as.integer(opt$top_n)), sql_flows)

dist <- run_bq_query_csv(opt$location, sql_dist)
for (nm in c("p05_miles", "p50_miles", "p95_miles", "mean_miles", "min_miles", "max_miles", "n_records")) {
  if (nm %in% names(dist)) dist[[nm]] <- as.numeric(dist[[nm]])
}

dist_out <- data.frame(
  distance_distribution_id = ifelse(dist$scenario_id == "CENTRALIZED", "dist_centralized_food_truck_2024", "dist_regionalized_food_truck_2024"),
  scenario_id = dist$scenario_id,
  source_zip = "FAF5.7.1_2018-2024.csv@GCS",
  commodity_filter = "sctg2 in [01,02,03,04,05,06,07,08]",
  mode_filter = ifelse(dist$scenario_id == "CENTRALIZED", "dms_mode==1", "dms_mode==1 and dist_band<=4"),
  distance_model = "triangular_fit",
  p05_miles = dist$p05_miles,
  p50_miles = dist$p50_miles,
  p95_miles = dist$p95_miles,
  mean_miles = dist$mean_miles,
  min_miles = dist$min_miles,
  max_miles = dist$max_miles,
  n_records = dist$n_records,
  status = "OK",
  source_id = "faf5_7_1_2018_2024_gcs_csv",
  notes = paste0("Computed in BigQuery from GCS-loaded FAF OD with ", weight_col, " weighting."),
  stringsAsFactors = FALSE
)

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
dist_out <- rbind(dist_out, smoke)
dist_out <- dist_out[order(dist_out$scenario_id), , drop = FALSE]

flows <- run_bq_query_csv(opt$location, sql_flows)
for (nm in c("tons", "ton_miles", "distance_miles")) if (nm %in% names(flows)) flows[[nm]] <- as.numeric(flows[[nm]])

dir.create(dirname(opt$out_distance_csv), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(opt$out_flows_csv), recursive = TRUE, showWarnings = FALSE)

utils::write.csv(dist_out, opt$out_distance_csv, row.names = FALSE)
utils::write.csv(flows, opt$out_flows_csv, row.names = FALSE)

meta <- list(
  generated_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  pipeline = "optional_bigquery",
  project_id = opt$project,
  dataset = opt$dataset,
  table = opt$table,
  location = toupper(opt$location),
  gcs_uri = opt$gcs_uri,
  source_id = "faf5_7_1_2018_2024_gcs_csv",
  distance_query_sha256 = digest(sql_dist, algo = "sha256", serialize = FALSE),
  top_flows_query_sha256 = digest(sql_flows, algo = "sha256", serialize = FALSE),
  top_n = as.integer(opt$top_n),
  weighting = weight_col,
  table_ref = table_fqn,
  notes = "job_id values are omitted when using bq CLI CSV output mode."
)
writeLines(jsonlite::toJSON(meta, auto_unbox = TRUE, pretty = TRUE), opt$out_meta)

log_info("Wrote: ", opt$out_distance_csv)
log_info("Wrote: ", opt$out_flows_csv)
log_info("Wrote: ", opt$out_meta)
