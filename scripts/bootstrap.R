#!/usr/bin/env Rscript
# scripts/bootstrap.R
# Installs required R packages and verifies repository structure.
# Called by devcontainer postCreateCommand. Safe to re-run (idempotent).

log_msg <- function(level, msg) {
  cat(sprintf("[%s] [bootstrap] [%s] %s\n",
              format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
              level, msg))
}

# ---------------------------------------------------------------------------
# Required packages
# ---------------------------------------------------------------------------
required_pkgs <- c(
  "optparse",
  "jsonlite",
  "digest",
  "testthat",
  "leaflet",
  "data.table",
  "yaml",
  "ggplot2",
  "readxl",
  "arrow",
  "scales",
  "viridis",
  "patchwork",
  "dplyr",
  "tidyr"
)

missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace,
                                      logical(1), quietly = TRUE)]

if (length(missing_pkgs) > 0) {
  log_msg("INFO", paste("Installing packages:", paste(missing_pkgs, collapse = ", ")))
  install.packages(
    missing_pkgs,
    repos    = "https://cloud.r-project.org",
    quiet    = TRUE,
    Ncpus    = max(1L, parallel::detectCores() - 1L)
  )
} else {
  log_msg("INFO", "All required R packages already installed.")
}

# Verify installation
still_missing <- required_pkgs[!vapply(required_pkgs, requireNamespace,
                                       logical(1), quietly = TRUE)]
if (length(still_missing) > 0) {
  log_msg("ERROR", paste("Failed to install:", paste(still_missing, collapse = ", ")))
  quit(status = 1)
}

log_msg("INFO", "All R packages verified.")

# ---------------------------------------------------------------------------
# Required directories
# ---------------------------------------------------------------------------
required_dirs <- c(
  "R",
  "R/io",
  "data/derived",
  "tools",
  "runs"
)

# Critical directories that must exist as source (not auto-created)
source_dirs <- c("R", "tools")

for (d in required_dirs) {
  if (!dir.exists(d)) {
    if (d %in% source_dirs) {
      log_msg("ERROR", paste("Critical source directory missing:", d))
      quit(status = 1)
    }
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    log_msg("INFO", paste("Created directory:", d))
  } else {
    log_msg("INFO", paste("Directory OK:", d))
  }
}

# ---------------------------------------------------------------------------
# Initialize runs/index.json if absent
# ---------------------------------------------------------------------------
registry_path <- file.path("runs", "index.json")
if (!file.exists(registry_path)) {
  jsonlite::write_json(list(), registry_path, pretty = TRUE, auto_unbox = TRUE)
  log_msg("INFO", paste("Initialized empty run registry:", registry_path))
}

log_msg("INFO", "Bootstrap complete.")
