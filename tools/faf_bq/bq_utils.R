validate_bq_identifier <- function(name, value) {
  # Conservative allowlist to avoid accidental SQL/CLI injection.
  # This is not meant to fully validate GCP/BQ naming rules, just to ensure
  # caller-provided values cannot contain metacharacters.
  ok <- switch(
    name,
    # GCP project IDs are typically lowercase with hyphens; keep it permissive but safe.
    project = grepl("^[A-Za-z0-9-]+$", value),
    dataset = grepl("^[A-Za-z0-9_]+$", value),
    table = grepl("^[A-Za-z0-9_]+$", value),
    FALSE
  )
  if (!isTRUE(ok)) stop(sprintf("Invalid %s '%s'", name, value))
  invisible(TRUE)
}

script_self_path <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  hit <- args[grepl("^--file=", args)]
  if (length(hit) == 0) return("")
  sub("^--file=", "", hit[[1]])
}

script_dir <- function() {
  p <- script_self_path()
  if (!nzchar(p)) return(normalizePath(".", winslash = "/", mustWork = FALSE))
  dirname(normalizePath(p, winslash = "/", mustWork = TRUE))
}

must_bin <- function(bin_name) {
  p <- Sys.which(bin_name)
  if (!nzchar(p)) stop(bin_name, " not found in PATH.")
  p
}

