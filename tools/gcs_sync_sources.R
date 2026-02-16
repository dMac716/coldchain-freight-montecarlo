#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

log_info <- function(...) message("[gcs_sync] ", paste0(..., collapse = ""))

option_list <- list(
  make_option(c("--env_file"), type = "character", default = "config/gcp.env", help = "Path to env file (default: config/gcp.env)."),
  make_option(c("--outdir"), type = "character", default = "data/cache/faf", help = "Destination directory for downloaded FAF files.")
)
opt <- parse_args(OptionParser(
  usage = "%prog [options]",
  description = "Optional sync of FAF CSV from GCS into local cache for offline processing.",
  option_list = option_list
))

parse_env_file <- function(path) {
  if (!file.exists(path)) return(list())
  x <- readLines(path, warn = FALSE)
  x <- trimws(x)
  x <- x[nzchar(x) & !startsWith(x, "#")]
  out <- list()
  for (line in x) {
    pos <- regexpr("=", line, fixed = TRUE)
    if (pos < 1) next
    key <- trimws(substr(line, 1, pos - 1))
    val <- trimws(substr(line, pos + 1, nchar(line)))
    out[[key]] <- val
  }
  out
}

env <- parse_env_file(opt$env_file)
gcs_uri <- Sys.getenv("FAF_OD_GCS_URI", unset = "")
if (!nzchar(gcs_uri) && !is.null(env$FAF_OD_GCS_URI)) gcs_uri <- env$FAF_OD_GCS_URI

if (!nzchar(gcs_uri) || !startsWith(gcs_uri, "gs://")) {
  log_info("No FAF_OD_GCS_URI configured. No-op.")
  quit(save = "no", status = 0)
}

if (Sys.which("gsutil") == "") {
  log_info("gsutil not found. No-op.")
  quit(save = "no", status = 0)
}

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)
dest <- file.path(opt$outdir, basename(gcs_uri))
cmd <- system2("gsutil", c("cp", gcs_uri, dest), stdout = TRUE, stderr = TRUE)
st <- attr(cmd, "status")
if (!is.null(st) && st != 0) {
  stop("gsutil cp failed:\n", paste(cmd, collapse = "\n"))
}

manifest <- if (file.exists("sources/sources_manifest.csv")) {
  utils::read.csv("sources/sources_manifest.csv", stringsAsFactors = FALSE)
} else data.frame()

expected_sha <- NA_character_
if (nrow(manifest) > 0 && all(c("filename", "notes") %in% names(manifest))) {
  row <- manifest[manifest$filename == basename(gcs_uri), , drop = FALSE]
  if (nrow(row) > 0) {
    note <- row$notes[[1]]
    m <- regmatches(note, regexpr("sha256[:=]\\s*([A-Fa-f0-9]{64})", note, perl = TRUE))
    if (length(m) > 0 && nzchar(m)) {
      expected_sha <- sub(".*sha256[:=]\\s*", "", m, perl = TRUE)
      expected_sha <- tolower(expected_sha)
    }
  }
}

if (is.finite(file.info(dest)$size) && file.info(dest)$size > 0) {
  if (requireNamespace("digest", quietly = TRUE)) {
    got_sha <- digest::digest(file = dest, algo = "sha256")
    if (is.na(expected_sha)) {
      log_info("Downloaded ", dest, " (sha256=", got_sha, "). No expected checksum found in sources_manifest notes; skipping strict verification.")
    } else if (!identical(tolower(got_sha), expected_sha)) {
      stop("Checksum mismatch for ", dest, ". expected=", expected_sha, " got=", got_sha)
    } else {
      log_info("Checksum verified for ", dest)
    }
  } else {
    log_info("R package 'digest' not installed; skipping sha256 verification for ", dest)
  }
}

log_info("Downloaded source: ", dest)
