#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--file"), type = "character", help = "Artifact JSON file to validate")
)
opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$file)) stop("--file is required.")

validate_artifact_schema_local(opt$file)
artifact <- jsonlite::fromJSON(opt$file, simplifyVector = FALSE)
expected <- artifact_canonical_sha256(artifact)
actual <- artifact$integrity$artifact_sha256
if (!is.character(actual) || length(actual) != 1 || !nzchar(actual)) {
  stop("Artifact integrity.artifact_sha256 is missing or invalid.")
}
if (!identical(expected, actual)) {
  stop(
    paste0(
      "Artifact checksum mismatch. expected=", expected,
      " actual=", actual
    )
  )
}

message("Artifact passed schema and canonical checksum checks: ", opt$file)
