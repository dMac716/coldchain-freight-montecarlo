#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--manifest"), type = "character", default = "data/snapshots/manifest.csv", help = "Manifest path"),
  make_option(c("--init"), action = "store_true", default = FALSE, help = "Initialize empty manifest if missing"),
  make_option(c("--strict"), action = "store_true", default = FALSE, help = "Exit non-zero when issues are found")
)
opt <- parse_args(OptionParser(option_list = option_list))

required_cols <- c("snapshot_id", "source", "path", "sha256", "timestamp_utc", "notes")

if (!file.exists(opt$manifest)) {
  if (isTRUE(opt$init)) {
    dir.create(dirname(opt$manifest), recursive = TRUE, showWarnings = FALSE)
    out <- data.frame(
      snapshot_id = character(),
      source = character(),
      path = character(),
      sha256 = character(),
      timestamp_utc = character(),
      notes = character(),
      stringsAsFactors = FALSE
    )
    utils::write.csv(out, opt$manifest, row.names = FALSE)
    message("Initialized manifest: ", opt$manifest)
    quit(status = 0L)
  }
  msg <- paste0("Manifest not found: ", opt$manifest, ". Use --init to create one.")
  if (isTRUE(opt$strict)) stop(msg)
  message(msg)
  quit(status = 0L)
}

manifest <- utils::read.csv(opt$manifest, stringsAsFactors = FALSE)
missing_cols <- setdiff(required_cols, names(manifest))
if (length(missing_cols) > 0) {
  stop("Manifest missing required columns: ", paste(missing_cols, collapse = ", "))
}

issues <- character()
for (i in seq_len(nrow(manifest))) {
  row <- manifest[i, , drop = FALSE]
  p <- row$path[[1]]
  s <- row$sha256[[1]]
  if (!nzchar(p) || !file.exists(p)) {
    issues <- c(issues, paste0("Row ", i, ": path missing or not found: ", p))
    next
  }
  if (nzchar(s)) {
    actual <- sha256_file(p)
    if (!identical(tolower(actual), tolower(s))) {
      issues <- c(issues, paste0("Row ", i, ": sha256 mismatch for ", p))
    }
  }
}

if (length(issues) == 0) {
  message("Snapshot manifest check passed: ", opt$manifest)
  quit(status = 0L)
}

message("Snapshot manifest check found issues:")
for (x in issues) message(" - ", x)

if (isTRUE(opt$strict)) quit(status = 1L)
quit(status = 0L)
