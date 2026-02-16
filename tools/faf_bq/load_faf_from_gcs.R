#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

args0 <- commandArgs(trailingOnly = FALSE)
hit0 <- args0[grepl("^--file=", args0)]
this_file <- if (length(hit0) > 0) sub("^--file=", "", hit0[[1]]) else ""
if (!nzchar(this_file)) stop("Unable to resolve script path for sourcing bq_utils.R")
source(file.path(dirname(normalizePath(this_file)), "bq_utils.R"))

log_info <- function(...) cat("[faf_bq] ", paste0(..., collapse = ""), "\n", sep = "")

run_cmd <- function(cmd, args) {
  out <- tryCatch(
    system2(cmd, args, stdout = TRUE, stderr = TRUE),
    warning = function(w) attr(w, "stdout"),
    error = function(e) stop("Failed running ", cmd, ": ", conditionMessage(e))
  )
  status <- attr(out, "status")
  list(status = if (is.null(status)) 0L else as.integer(status), out = out)
}

option_list <- list(
  make_option(c("--project"), type = "character"),
  make_option(c("--dataset"), type = "character"),
  make_option(c("--location"), type = "character"),
  make_option(c("--gcs_uri"), type = "character"),
  make_option(c("--table"), type = "character"),
  make_option(c("--max_bad_rows"), type = "integer", default = 0L, help = "Max allowed rows failing numeric casts in post-load validation."),
  make_option(c("--schema"), type = "character", default = "", help = "Optional BigQuery schema file path. If provided, disables --autodetect.")
)

opt <- parse_args(OptionParser(
  usage = "%prog [options]",
  description = "Load FAF OD CSV from GCS into BigQuery table with location validation.",
  option_list = option_list
))

required <- c("project", "dataset", "location", "gcs_uri", "table")
missing <- required[vapply(required, function(x) is.null(opt[[x]]) || !nzchar(opt[[x]]), logical(1))]
if (length(missing) > 0) stop("Missing required args: ", paste(missing, collapse = ", "))

bucket <- sub("^gs://([^/]+).*$", "\\1", opt$gcs_uri)
if (!nzchar(bucket) || identical(bucket, opt$gcs_uri)) {
  stop("Invalid --gcs_uri. Expected gs://bucket/path.csv")
}

bq_bin <- must_bin("bq")
gsutil_bin <- must_bin("gsutil")

validate_bq_identifier("project", opt$project)
validate_bq_identifier("dataset", opt$dataset)
validate_bq_identifier("table", opt$table)

bq_show <- run_cmd(
  bq_bin,
  c(
    paste0("--project_id=", opt$project),
    "--format=prettyjson",
    "show",
    paste0(opt$project, ":", opt$dataset)
  )
)
if (bq_show$status != 0L) {
  stop(
    "Unable to show dataset ", opt$project, ":", opt$dataset,
    ". Ensure dataset exists and credentials are configured.\n",
    paste(bq_show$out, collapse = "\n")
  )
}

dataset_info <- jsonlite::fromJSON(paste(bq_show$out, collapse = "\n"), simplifyVector = TRUE)
dataset_loc <- toupper(dataset_info$location)
requested_loc <- toupper(opt$location)
if (!identical(dataset_loc, requested_loc)) {
  stop(
    "BQ location mismatch: dataset location is ", dataset_loc,
    " but BQ_LOCATION is ", requested_loc,
    ". Update config to match."
  )
}

gs_loc <- run_cmd(gsutil_bin, c("-u", opt$project, "ls", "-Lb", paste0("gs://", bucket)))
if (gs_loc$status != 0L) {
  stop("Unable to inspect bucket location for gs://", bucket, "\n", paste(gs_loc$out, collapse = "\n"))
}
loc_line <- gs_loc$out[grepl("Location constraint:", gs_loc$out, ignore.case = TRUE)]
if (length(loc_line) == 0) {
  stop("Could not detect bucket location for gs://", bucket)
}
bucket_loc <- toupper(trimws(sub(".*Location constraint:\\s*", "", loc_line[[1]])))
if (bucket_loc == "US" && requested_loc == "US") {
  # OK
} else if (!identical(bucket_loc, requested_loc)) {
  stop(
    "GCS/BQ location mismatch: bucket ", bucket, " is ", bucket_loc,
    " but BQ_LOCATION is ", requested_loc,
    ". Use a dataset in the same location as the bucket."
  )
}

table_fqn <- paste0(opt$project, ":", opt$dataset, ".", opt$table)
schema_arg <- character()
if (nzchar(opt$schema)) {
  if (!file.exists(opt$schema)) stop("Schema file not found: ", opt$schema)
  schema_arg <- opt$schema
}

load_args <- c(
  paste0("--project_id=", opt$project),
  paste0("--location=", requested_loc),
  "load",
  "--replace",
  "--source_format=CSV",
  "--skip_leading_rows=1"
)
if (nzchar(opt$schema)) {
  load_args <- c(load_args, table_fqn, opt$gcs_uri, schema_arg)
} else {
  load_args <- c(load_args, "--autodetect", table_fqn, opt$gcs_uri)
}
load <- run_cmd(
  bq_bin,
  load_args
)
if (load$status != 0L) {
  stop("bq load failed:\n", paste(load$out, collapse = "\n"))
}

table_sql_fqn <- paste0("`", opt$project, ".", opt$dataset, ".", opt$table, "`")
sql_validate <- paste(
  "SELECT",
  "  COUNTIF(SAFE_CAST(dist_band AS INT64) IS NULL AND dist_band IS NOT NULL) AS bad_dist_band,",
  "  COUNTIF(SAFE_CAST(tons_2024 AS FLOAT64) IS NULL AND tons_2024 IS NOT NULL) AS bad_tons_2024,",
  "  COUNTIF(SAFE_CAST(tmiles_2024 AS FLOAT64) IS NULL AND tmiles_2024 IS NOT NULL) AS bad_tmiles_2024",
  "FROM", table_sql_fqn,
  sep = "\n"
)
v <- run_cmd(
  bq_bin,
  c(
    paste0("--project_id=", opt$project),
    paste0("--location=", requested_loc),
    "query",
    "--quiet",
    "--use_legacy_sql=false",
    "--format=csv",
    sql_validate
  )
)
if (v$status != 0L) stop("Post-load validation query failed:\n", paste(v$out, collapse = "\n"))
v_txt <- paste(v$out, collapse = "\n")
tmp <- tempfile(fileext = ".csv")
writeLines(v_txt, tmp)
v_df <- utils::read.csv(tmp, stringsAsFactors = FALSE)
bad_counts <- c(bad_dist_band = NA_integer_, bad_tons_2024 = NA_integer_, bad_tmiles_2024 = NA_integer_)
for (nm in names(bad_counts)) {
  if (nm %in% names(v_df)) bad_counts[[nm]] <- as.integer(v_df[[nm]][[1]])
}
max_bad <- as.integer(opt$max_bad_rows)
if (is.finite(max_bad) && any(is.finite(bad_counts) & bad_counts > max_bad)) {
  stop(
    "Post-load validation failed (max_bad_rows=", max_bad, "): ",
    paste(names(bad_counts), bad_counts, sep = "=", collapse = ", "),
    ". Consider reloading with an explicit --schema and/or inspect the CSV formatting."
  )
}

log_info("Loaded table: ", table_fqn, " from ", opt$gcs_uri)
