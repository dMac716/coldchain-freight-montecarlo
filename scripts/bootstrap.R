#!/usr/bin/env Rscript
# scripts/bootstrap.R
# Installs required R packages and verifies repository structure.
# Called by devcontainer postCreateCommand. Safe to re-run (idempotent).

# Inline fallback log — overridden by R/log_helpers.R when available.
log_event <- function(level = "INFO", phase = "unknown", msg = "") {
  cat(sprintf(
    '[%s] [bootstrap] run_id="unknown" lane="local" seed="unknown" phase="%s" status="%s" msg="%s"\n',
    format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    phase, level, msg
  ))
  invisible(NULL)
}
if (file.exists("R/log_helpers.R")) {
  source("R/log_helpers.R")
  configure_log(tag = "bootstrap")
}

default_user_library <- function() {
  env_path <- Sys.getenv("R_LIBS_USER", unset = "")
  if (nzchar(env_path)) {
    return(normalizePath(path.expand(env_path), winslash = "/", mustWork = FALSE))
  }
  normalizePath(
    file.path(path.expand("~"), ".local", "share", "R", "site-library"),
    winslash = "/",
    mustWork = FALSE
  )
}

dir_is_writable <- function(path) {
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(path)) return(FALSE)
  probe <- file.path(path, sprintf(".write_probe_%d", Sys.getpid()))
  ok <- tryCatch(
    file.create(probe),
    warning = function(w) FALSE,
    error = function(e) FALSE
  )
  if (isTRUE(ok) && file.exists(probe)) unlink(probe, force = TRUE)
  isTRUE(ok)
}

select_library_path <- function() {
  user_lib <- default_user_library()
  candidate_libs <- unique(c(
    user_lib,
    normalizePath(.libPaths(), winslash = "/", mustWork = FALSE)
  ))
  writable <- vapply(candidate_libs, dir_is_writable, logical(1))
  if (!any(writable)) {
    log_event(
      "ERROR",
      "bootstrap",
      paste(
        "No writable R package library found.",
        "Re-run: bash .devcontainer/postCreate.sh && Rscript scripts/bootstrap.R"
      )
    )
    quit(status = 1)
  }
  candidate_libs[[which(writable)[1]]]
}

library_target <- select_library_path()
Sys.setenv(R_LIBS_USER = library_target)
.libPaths(unique(c(library_target, .libPaths())))

log_event("INFO", "bootstrap", paste("Using R package library:", library_target))
log_event("INFO", "bootstrap", paste("Active .libPaths():", paste(.libPaths(), collapse = " | ")))

# ---------------------------------------------------------------------------
# renv.lock awareness — prefer locked versions when renv is available
# ---------------------------------------------------------------------------
renv_lock <- "renv.lock"
if (file.exists(renv_lock)) {
  log_event("INFO", "bootstrap", "renv.lock detected — attempting renv::restore() for locked package versions.")
  renv_ok <- tryCatch({
    if (!requireNamespace("renv", quietly = TRUE)) {
      install.packages(
        "renv",
        lib = library_target,
        repos = "https://cloud.r-project.org",
        quiet = TRUE
      )
    }
    renv::restore(prompt = FALSE)
    TRUE
  }, error = function(e) {
    log_event("WARN", "bootstrap", paste("renv::restore() failed, falling back to manual install:", conditionMessage(e)))
    FALSE
  })
  if (isTRUE(renv_ok)) {
    log_event("INFO", "bootstrap", "renv::restore() succeeded.")
    # Still verify the specific required packages below
  }
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
  log_event("INFO", "bootstrap", paste("Installing packages:", paste(missing_pkgs, collapse = ", ")))
  # F14 FIX: detectCores() can return NA in containers; guard against that.
  n_cores <- tryCatch(parallel::detectCores(logical = FALSE), error = function(e) NA_integer_)
  n_cpus  <- max(1L, if (is.na(n_cores)) 1L else as.integer(n_cores) - 1L, 1L)
  install.packages(
    missing_pkgs,
    lib      = library_target,
    repos    = "https://cloud.r-project.org",
    quiet    = TRUE,
    Ncpus    = n_cpus
  )
} else {
  log_event("INFO", "bootstrap", "All required R packages already installed.")
}

# Verify installation
still_missing <- required_pkgs[!vapply(required_pkgs, requireNamespace,
                                       logical(1), quietly = TRUE)]
if (length(still_missing) > 0) {
  log_event("ERROR", "bootstrap", paste("Failed to install:", paste(still_missing, collapse = ", ")))
  quit(status = 1)
}

log_event("INFO", "bootstrap", "All R packages verified.")

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
      log_event("ERROR", "bootstrap", paste("Critical source directory missing:", d))
      quit(status = 1)
    }
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    log_event("INFO", "bootstrap", paste("Created directory:", d))
  } else {
    log_event("INFO", "bootstrap", paste("Directory OK:", d))
  }
}

# ---------------------------------------------------------------------------
# Initialize runs/index.json if absent
# ---------------------------------------------------------------------------
registry_path <- file.path("runs", "index.json")
if (!file.exists(registry_path)) {
  jsonlite::write_json(list(), registry_path, pretty = TRUE, auto_unbox = TRUE)
  log_event("INFO", "bootstrap", paste("Initialized empty run registry:", registry_path))
}

log_event("INFO", "bootstrap", "Bootstrap complete.")
