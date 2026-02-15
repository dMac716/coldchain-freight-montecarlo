#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

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
  make_option(c("--table"), type = "character")
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

if (Sys.which("bq") == "") stop("bq CLI not found in PATH.")
if (Sys.which("gsutil") == "") stop("gsutil not found in PATH.")

bq_show <- run_cmd("bq", c("--format=prettyjson", "show", paste0(opt$project, ":", opt$dataset)))
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

gs_loc <- run_cmd("gsutil", c("ls", "-Lb", paste0("gs://", bucket)))
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
load <- run_cmd(
  "bq",
  c(
    paste0("--location=", requested_loc),
    "load",
    "--replace",
    "--source_format=CSV",
    "--skip_leading_rows=1",
    "--autodetect",
    table_fqn,
    opt$gcs_uri
  )
)
if (load$status != 0L) {
  stop("bq load failed:\n", paste(load$out, collapse = "\n"))
}

log_info("Loaded table: ", table_fqn, " from ", opt$gcs_uri)
