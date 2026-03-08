#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

option_list <- list(
  make_option(c("--mode"), type = "character", default = "SMOKE_LOCAL", help = "Run mode: SMOKE_LOCAL or REAL_RUN"),
  make_option(c("--outdir"), type = "character", default = "outputs/validation/inputs", help = "Output directory for validation report")
)
opt <- parse_args(OptionParser(option_list = option_list))
mode <- normalize_run_mode(opt$mode)

if (!dir.exists(opt$outdir)) dir.create(opt$outdir, recursive = TRUE)

rows <- list()
ri <- 0L
add_check <- function(name, status, detail = "") {
  ri <<- ri + 1L
  rows[[ri]] <<- data.frame(
    check = as.character(name),
    status = as.character(status),
    detail = as.character(detail),
    stringsAsFactors = FALSE
  )
}

run_guard <- function(name, expr) {
  ok <- TRUE
  msg <- ""
  tryCatch(
    force(expr),
    error = function(e) {
      ok <<- FALSE
      msg <<- as.character(e$message)
    }
  )
  if (ok) add_check(name, "PASS") else add_check(name, "FAIL", msg)
}

required_files <- c(
  "data/inputs_local/scenarios.csv",
  "data/inputs_local/scenario_matrix.csv",
  "data/inputs_local/products.csv",
  "data/inputs_local/emissions_factors.csv",
  "data/inputs_local/sampling_priors.csv",
  "data/inputs_local/grid_ci.csv",
  "data/inputs_local/histogram_config.csv",
  "data/derived/faf_distance_distributions.csv"
)
for (f in required_files) {
  if (!file.exists(f)) {
    add_check(paste0("file_exists:", f), "FAIL", "missing")
  } else if (file.info(f)$size <= 0) {
    add_check(paste0("file_exists:", f), "FAIL", "empty")
  } else {
    add_check(paste0("file_exists:", f), "PASS")
  }
}

inputs <- read_inputs_local()

required_cols <- list(
  scenarios = c("scenario_id", "distance_distribution_id", "status"),
  scenario_matrix = c("variant_id", "scenario_id", "powertrain", "status"),
  products = c("product_id", "kcal_per_kg", "status"),
  emissions_factors = c("factor_id", "powertrain", "status"),
  sampling_priors = c("param_id", "distribution", "p1", "status"),
  grid_ci = c("grid_case", "co2_g_per_kwh", "status"),
  histogram_config = c("metric", "min", "max", "bins", "status"),
  distance_distributions = c("distance_distribution_id", "scenario_id", "status")
)
for (nm in names(required_cols)) {
  tbl <- inputs[[nm]]
  miss <- setdiff(required_cols[[nm]], names(tbl))
  if (length(miss) == 0L) {
    add_check(paste0("required_columns:", nm), "PASS")
  } else {
    add_check(paste0("required_columns:", nm), "FAIL", paste(miss, collapse = ","))
  }
}

run_guard("sampling_priors_schema", validate_sampling_priors(inputs$sampling_priors))
run_guard("scenario_matrix_dimensions", assert_variant_dimensions_present(inputs$scenario_matrix))
run_guard("scenario_distance_linkage", assert_scenarios_distance_linkage(inputs$scenarios, inputs$distance_distributions))
run_guard(
  "histogram_config_schema",
  validate_hist_config(list(
    metric = inputs$histogram_config$metric,
    min = inputs$histogram_config$min,
    max = inputs$histogram_config$max,
    bins = inputs$histogram_config$bins
  ))
)

# Additional referential checks with clearer messages.
sid_miss <- setdiff(unique(as.character(inputs$scenario_matrix$scenario_id)), unique(as.character(inputs$scenarios$scenario_id)))
if (length(sid_miss) == 0L) {
  add_check("scenario_matrix_refs_scenarios", "PASS")
} else {
  add_check("scenario_matrix_refs_scenarios", "FAIL", paste(sid_miss, collapse = "|"))
}

did_miss <- setdiff(unique(as.character(inputs$scenarios$distance_distribution_id)), unique(as.character(inputs$distance_distributions$distance_distribution_id)))
if (length(did_miss) == 0L) {
  add_check("scenarios_refs_distance_distributions", "PASS")
} else {
  add_check("scenarios_refs_distance_distributions", "FAIL", paste(did_miss, collapse = "|"))
}

status_col <- function(df) if ("status" %in% names(df)) toupper(trimws(as.character(df$status))) else character()

needs_source_n <- sum(status_col(inputs$emissions_factors) == "NEEDS_SOURCE_VALUE", na.rm = TRUE)
packaging_tbd_n <- sum(status_col(inputs$products) == "PACKAGING_MASS_TBD", na.rm = TRUE)

add_check("emissions_factors_NEEDS_SOURCE_VALUE_count", "INFO", as.character(needs_source_n))
add_check("products_PACKAGING_MASS_TBD_count", "INFO", as.character(packaging_tbd_n))

if (identical(mode, "REAL_RUN")) {
  if (needs_source_n > 0L) add_check("real_run_gate_emissions_factors", "FAIL", "NEEDS_SOURCE_VALUE present") else add_check("real_run_gate_emissions_factors", "PASS")
  if (packaging_tbd_n > 0L) add_check("real_run_gate_packaging_mass", "FAIL", "PACKAGING_MASS_TBD present") else add_check("real_run_gate_packaging_mass", "PASS")
} else {
  if (needs_source_n > 0L) add_check("smoke_local_warn_emissions_factors", "WARN", "NEEDS_SOURCE_VALUE present") else add_check("smoke_local_warn_emissions_factors", "PASS")
  if (packaging_tbd_n > 0L) add_check("smoke_local_warn_packaging_mass", "WARN", "PACKAGING_MASS_TBD present") else add_check("smoke_local_warn_packaging_mass", "PASS")
}

report <- do.call(rbind, rows)
report_csv <- file.path(opt$outdir, "input_validation_report.csv")
utils::write.csv(report, report_csv, row.names = FALSE)

summary <- list(
  mode = mode,
  generated_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  n_checks = nrow(report),
  n_fail = sum(report$status == "FAIL"),
  n_warn = sum(report$status == "WARN"),
  n_info = sum(report$status == "INFO"),
  report_csv = report_csv
)
jsonlite::write_json(summary, path = file.path(opt$outdir, "input_validation_summary.json"), pretty = TRUE, auto_unbox = TRUE)

cat("Wrote", report_csv, "\n")
cat("FAIL=", summary$n_fail, " WARN=", summary$n_warn, " INFO=", summary$n_info, "\n", sep = "")

if (summary$n_fail > 0) quit(save = "no", status = 1)
quit(save = "no", status = 0)
