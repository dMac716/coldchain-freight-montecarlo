#!/usr/bin/env Rscript

Sys.setenv(
  OMP_NUM_THREADS = "1",
  OPENBLAS_NUM_THREADS = "1",
  MKL_NUM_THREADS = "1",
  VECLIB_MAXIMUM_THREADS = "1",
  NUMEXPR_NUM_THREADS = "1"
)

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")
data.table::setDTthreads(1L)

option_list <- list(
  make_option(c("--dry_bundle_root"), type = "character", default = ""),
  make_option(c("--refrigerated_bundle_root"), type = "character", default = ""),
  make_option(c("--dry_lci_dir"), type = "character", default = ""),
  make_option(c("--refrigerated_lci_dir"), type = "character", default = ""),
  make_option(c("--outdir"), type = "character", default = "outputs/validation/end_to_end")
)
opt <- parse_args(OptionParser(option_list = option_list))

required_args <- c("dry_bundle_root", "refrigerated_bundle_root", "dry_lci_dir", "refrigerated_lci_dir")
for (nm in required_args) {
  if (!nzchar(as.character(opt[[nm]] %||% ""))) stop("--", nm, " is required")
}
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

add_check <- function(lst, check_id, status, message, target = NA_character_) {
  lst[[length(lst) + 1L]] <- data.frame(
    check_id = as.character(check_id),
    status = as.character(status),
    message = as.character(message),
    target = as.character(target),
    stringsAsFactors = FALSE
  )
  lst
}

run_validator <- function(script, args) {
  out <- tempfile("validator_out_")
  cmd <- c(file.path("tools", script), args)
  status <- system2("Rscript", cmd, stdout = out, stderr = out)
  list(status = status, log = tryCatch(readLines(out, warn = FALSE), error = function(e) character()))
}

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)
checks <- list()

# Simulation validations
sim_dry_out <- file.path(opt$outdir, "sim_dry")
sim_ref_out <- file.path(opt$outdir, "sim_refrigerated")

r1 <- run_validator("validate_route_sim_outputs.R", c("--input_dir", opt$dry_bundle_root, "--outdir", sim_dry_out, "--fail_on_error", "false"))
r2 <- run_validator("validate_route_sim_outputs.R", c("--input_dir", opt$refrigerated_bundle_root, "--outdir", sim_ref_out, "--fail_on_error", "false"))

checks <- add_check(checks, "sim_validator_dry_exec", if (identical(r1$status, 0L)) "PASS" else "FAIL", "Dry simulation validator executed", opt$dry_bundle_root)
checks <- add_check(checks, "sim_validator_refrigerated_exec", if (identical(r2$status, 0L)) "PASS" else "FAIL", "Refrigerated simulation validator executed", opt$refrigerated_bundle_root)

# LCI validations
lci_dry_out <- file.path(opt$outdir, "lci_dry")
lci_ref_out <- file.path(opt$outdir, "lci_refrigerated")

r3 <- run_validator("validate_lci_report.R", c("--lci_dir", opt$dry_lci_dir, "--outdir", lci_dry_out, "--fail_on_error", "false"))
r4 <- run_validator("validate_lci_report.R", c("--lci_dir", opt$refrigerated_lci_dir, "--outdir", lci_ref_out, "--fail_on_error", "false"))

checks <- add_check(checks, "lci_validator_dry_exec", if (identical(r3$status, 0L)) "PASS" else "FAIL", "Dry LCI validator executed", opt$dry_lci_dir)
checks <- add_check(checks, "lci_validator_refrigerated_exec", if (identical(r4$status, 0L)) "PASS" else "FAIL", "Refrigerated LCI validator executed", opt$refrigerated_lci_dir)

# Parse validator outputs and bubble up FAIL rows.
collect_fails <- function(csv_path, prefix) {
  if (!file.exists(csv_path)) return(data.frame())
  d <- data.table::fread(csv_path, showProgress = FALSE)
  d <- d[as.character(status) == "FAIL"]
  if (nrow(d) == 0) return(data.frame())
  data.frame(
    check_id = paste0(prefix, "::", as.character(d$check_id)),
    status = "FAIL",
    message = as.character(d$message),
    target = as.character(d$target %||% NA_character_),
    stringsAsFactors = FALSE
  )
}

fails <- data.frame()
fails <- data.table::rbindlist(list(
  fails,
  collect_fails(file.path(sim_dry_out, "validation_report.csv"), "sim_dry"),
  collect_fails(file.path(sim_ref_out, "validation_report.csv"), "sim_refrigerated"),
  collect_fails(file.path(lci_dry_out, "lci_validation_report.csv"), "lci_dry"),
  collect_fails(file.path(lci_ref_out, "lci_validation_report.csv"), "lci_refrigerated")
), fill = TRUE)

if (nrow(fails) > 0) {
  for (i in seq_len(nrow(fails))) {
    checks <- add_check(checks, as.character(fails$check_id[[i]]), "FAIL", as.character(fails$message[[i]]), as.character(fails$target[[i]]))
  }
}

# Merged ledger validation: both systems present, distribution present.
ledger_dry <- file.path(opt$dry_lci_dir, "inventory_ledger.csv")
ledger_ref <- file.path(opt$refrigerated_lci_dir, "inventory_ledger.csv")
if (!file.exists(ledger_dry) || !file.exists(ledger_ref)) {
  checks <- add_check(checks, "merged_ledger_sources", "FAIL", "One or both source ledgers missing", paste(ledger_dry, ledger_ref, sep = " | "))
} else {
  d1 <- data.table::fread(ledger_dry, showProgress = FALSE)
  d2 <- data.table::fread(ledger_ref, showProgress = FALSE)
  merged <- data.table::rbindlist(list(d1, d2), fill = TRUE, use.names = TRUE)

  systems <- sort(unique(tolower(as.character(merged$system_id %||% character()))))
  has_dry <- "dry" %in% systems
  has_ref <- "refrigerated" %in% systems
  checks <- add_check(checks, "merged_system_presence", if (has_dry && has_ref) "PASS" else "FAIL", "Merged ledger contains both dry and refrigerated systems", paste(systems, collapse = ","))

  dist_ok <- all(c("stage", "dataset_key") %in% names(merged)) && any(as.character(merged$stage) == "distribution" & as.character(merged$dataset_key) == "route_sim_distribution")
  checks <- add_check(checks, "merged_distribution_present", if (dist_ok) "PASS" else "FAIL", "Merged ledger includes distribution stage from route sim", "merged_inventory_ledger")

  merged_out <- file.path(opt$outdir, "merged_inventory_ledger.csv")
  data.table::fwrite(merged, merged_out)
}

summary_df <- if (length(checks) > 0) data.table::rbindlist(checks, fill = TRUE) else data.frame()
out_csv <- file.path(opt$outdir, "project_validation_summary.csv")
out_json <- file.path(opt$outdir, "project_validation_summary.json")

data.table::fwrite(summary_df, out_csv)
jsonlite::write_json(list(
  generated_at_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
  inputs = as.list(opt),
  checks = summary_df
), out_json, pretty = TRUE, auto_unbox = TRUE, null = "null")

cat("Wrote", out_csv, "\n")
cat("Wrote", out_json, "\n")

if (any(as.character(summary_df$status) == "FAIL")) {
  stop("End-to-end validation failed")
}
