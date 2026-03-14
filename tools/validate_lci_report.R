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
  make_option(c("--lci_dir"), type = "character", default = "", help = "LCI report directory"),
  make_option(c("--ledger_csv"), type = "character", default = "", help = "Ledger CSV path (optional override)"),
  make_option(c("--outdir"), type = "character", default = "outputs/validation/lci"),
  make_option(c("--fail_on_error"), type = "character", default = "true")
)
opt <- parse_args(OptionParser(option_list = option_list))

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
parse_bool <- function(x, default = TRUE) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Invalid boolean flag: ", x)
}

report <- list()
ri <- 0L
add_check <- function(check_id, status, message, target = NA_character_, details = NA_character_) {
  ri <<- ri + 1L
  report[[ri]] <<- data.frame(
    check_id = as.character(check_id),
    status = as.character(status),
    message = as.character(message),
    target = as.character(target),
    details = as.character(details),
    stringsAsFactors = FALSE
  )
}

ledger_path <- ""
if (nzchar(opt$ledger_csv)) {
  ledger_path <- opt$ledger_csv
} else if (nzchar(opt$lci_dir)) {
  ledger_path <- file.path(opt$lci_dir, "inventory_ledger.csv")
}
if (!nzchar(ledger_path) || !file.exists(ledger_path)) stop("Ledger CSV not found")

ledger <- data.table::fread(ledger_path, showProgress = FALSE)
metadata <- list()
if (nzchar(opt$lci_dir) && file.exists(file.path(opt$lci_dir, "inventory_ledger.json"))) {
  metadata <- tryCatch(jsonlite::fromJSON(file.path(opt$lci_dir, "inventory_ledger.json"), simplifyVector = TRUE)$metadata, error = function(e) list())
}

required_cols <- c(
  "run_id", "system_id", "stage", "process", "flow_name", "direction", "amount", "unit",
  "functional_unit_basis", "dataset_key", "source_file", "confidence"
)
miss <- setdiff(required_cols, names(ledger))
if (length(miss) == 0) {
  add_check("ledger_schema", "PASS", "Required ledger columns present", ledger_path)
} else {
  add_check("ledger_schema", "FAIL", paste("Missing ledger columns:", paste(miss, collapse = ", ")), ledger_path)
}

if ("functional_unit_basis" %in% names(ledger)) {
  fu_ok <- all(as.character(ledger$functional_unit_basis) == "per_1000kcal", na.rm = TRUE)
  add_check("functional_unit_basis", if (fu_ok) "PASS" else "FAIL", "functional_unit_basis equals per_1000kcal", ledger_path)
}

dist_ok <- FALSE
if (all(c("stage", "dataset_key") %in% names(ledger))) {
  dist_ok <- any(as.character(ledger$stage) == "distribution" & as.character(ledger$dataset_key) == "route_sim_distribution")
}
add_check("distribution_stage_present", if (dist_ok) "PASS" else "FAIL", "distribution stage contains route_sim_distribution rows", ledger_path)

scope <- tolower(as.character(metadata$inventory_scope %||% ""))
stages <- c("ingredients", "manufacturing", "packaging", "retail_storage", "household_storage", "eol")
if (!identical(scope, "distribution_stage_only")) {
  stage_checks <- lapply(stages, function(st) {
    d <- ledger[as.character(ledger$stage) == st]
    if (nrow(d) == 0) {
      list(stage = st, ok = FALSE, msg = "stage absent")
    } else {
      has_placeholder <- any(as.character(d$dataset_key) == "NEEDS_SOURCE_VALUE", na.rm = TRUE)
      list(stage = st, ok = has_placeholder, msg = if (has_placeholder) "placeholder explicitly tagged" else "no NEEDS_SOURCE_VALUE rows")
    }
  })
  for (x in stage_checks) {
    add_check(paste0("stage_placeholder_", x$stage), if (isTRUE(x$ok)) "PASS" else "FAIL", x$msg, ledger_path)
  }
}

cp <- as.character(metadata$currency_policy %||% "")
cp_ok <- nzchar(cp) && grepl("never auto-converted to USD", cp, fixed = TRUE)
add_check("currency_policy", if (cp_ok) "PASS" else "FAIL", "Currency policy present and preserves no-auto-convert rule", file.path(opt$lci_dir %||% "", "inventory_ledger.json"))

prov_path <- if (nzchar(opt$lci_dir)) file.path(opt$lci_dir, "provenance_manifest.csv") else ""
if (nzchar(prov_path) && file.exists(prov_path)) {
  prov <- data.table::fread(prov_path, showProgress = FALSE)
  add_check("provenance_exists", "PASS", "provenance_manifest.csv exists", prov_path)
  if ("dataset_key" %in% names(prov) && "dataset_key" %in% names(ledger)) {
    lkeys <- unique(as.character(ledger$dataset_key))
    lkeys <- lkeys[nzchar(lkeys)]
    pkeys <- unique(as.character(prov$dataset_key))
    missing <- setdiff(lkeys, pkeys)
    if (length(missing) == 0) {
      add_check("provenance_key_match", "PASS", "All ledger dataset_keys present in provenance", prov_path)
    } else {
      add_check("provenance_key_match", "FAIL", paste("Missing provenance dataset_keys:", paste(missing, collapse = ", ")), prov_path)
    }
  }
} else {
  add_check("provenance_exists", "FAIL", "provenance_manifest.csv missing", prov_path)
}

calc_completion <- function(d) {
  n <- nrow(d)
  n_real <- if (n > 0) sum(!is.na(d$dataset_key) & nzchar(as.character(d$dataset_key)) & as.character(d$dataset_key) != "NEEDS_SOURCE_VALUE") else 0L
  n_placeholder <- if (n > 0) sum(is.na(d$dataset_key) | !nzchar(as.character(d$dataset_key)) | as.character(d$dataset_key) == "NEEDS_SOURCE_VALUE") else 0L
  pct <- if (n > 0) 100 * as.numeric(n_real) / as.numeric(n) else NA_real_
  status <- if (n == 0) "EXCLUDED" else if (n_real > 0) "COMPLETE" else "PLACEHOLDER"
  data.frame(n_rows = as.integer(n), n_real_rows = as.integer(n_real), n_placeholder_rows = as.integer(n_placeholder), completion_pct = pct, stage_status = status, stringsAsFactors = FALSE)
}

by_stage <- lapply(sort(unique(as.character(ledger$stage))), function(st) {
  cbind(data.frame(stage = st, stringsAsFactors = FALSE), calc_completion(ledger[as.character(ledger$stage) == st]))
})
by_stage <- if (length(by_stage) > 0) data.table::rbindlist(by_stage, fill = TRUE) else data.frame()

by_system <- lapply(sort(unique(as.character(ledger$system_id))), function(sys) {
  cbind(data.frame(system_id = sys, stringsAsFactors = FALSE), calc_completion(ledger[as.character(ledger$system_id) == sys]))
})
by_system <- if (length(by_system) > 0) data.table::rbindlist(by_system, fill = TRUE) else data.frame()

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)
report_df <- if (length(report) > 0) data.table::rbindlist(report, fill = TRUE) else data.frame()
if (nrow(report_df) == 0) {
  report_df <- data.frame(check_id = "no_checks", status = "FAIL", message = "No checks were executed", target = ledger_path, details = NA_character_, stringsAsFactors = FALSE)
}

report_csv <- file.path(opt$outdir, "lci_validation_report.csv")
report_json <- file.path(opt$outdir, "lci_validation_report.json")
comp_stage_csv <- file.path(opt$outdir, "lci_completeness_by_stage.csv")
comp_system_csv <- file.path(opt$outdir, "lci_completeness_by_system.csv")

data.table::fwrite(report_df, report_csv)
data.table::fwrite(by_stage, comp_stage_csv)
data.table::fwrite(by_system, comp_system_csv)
jsonlite::write_json(list(
  generated_at_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
  ledger_csv = ledger_path,
  checks = report_df,
  completeness_by_stage = by_stage,
  completeness_by_system = by_system
), report_json, pretty = TRUE, auto_unbox = TRUE, null = "null")

cat("Wrote", report_csv, "\n")
cat("Wrote", report_json, "\n")
cat("Wrote", comp_stage_csv, "\n")
cat("Wrote", comp_system_csv, "\n")

if (isTRUE(parse_bool(opt$fail_on_error, default = TRUE)) && any(report_df$status == "FAIL")) {
  stop("LCI validation failed")
}
