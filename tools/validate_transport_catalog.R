#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(data.table)
})

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

duckdb_csv_query <- function(db, sql) {
  out <- tryCatch(system2("duckdb", args = c(db, "-csv"), input = sql, stdout = TRUE, stderr = TRUE), error = function(e) character())
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) return(data.table())
  if (length(out) == 0) return(data.table())
  fread(text = paste(out, collapse = "\n"), showProgress = FALSE)
}

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--db"), type = "character", default = "analysis/transport_catalog.duckdb"),
  make_option(c("--outdir"), type = "character", default = "analysis")
)))

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)
report_csv <- file.path(opt$outdir, "transport_catalog_validation.csv")
report_txt <- file.path(opt$outdir, "transport_catalog_validation.txt")

results <- data.table(check = character(), status = character(), detail = character())
add_result <- function(check, status, detail) {
  results <<- rbind(results, data.table(check = check, status = status, detail = detail), fill = TRUE)
}

tables <- duckdb_csv_query(opt$db, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'")
needed_tables <- c("runs", "manifests", "scenario_rows", "crossed_results", "realistic_results", "decomposition")
missing_tables <- setdiff(needed_tables, as.character(tables$table_name %||% character()))
if (length(missing_tables) > 0) {
  add_result("required_tables", "FAIL", paste("Missing tables:", paste(missing_tables, collapse = ", ")))
} else {
  add_result("required_tables", "PASS", "All required catalog tables present")
}

scenario_cols <- duckdb_csv_query(opt$db, "SELECT column_name FROM information_schema.columns WHERE table_name = 'scenario_rows' ORDER BY column_name")
required_cols <- c(
  "run_id", "layer_type", "factory", "powertrain", "reefer_state", "product_load", "replicate_id", "chunk_id",
  "route_completed", "trip_distance_miles", "trip_duration_hours", "congestion_delay_hours", "refrigeration_runtime_hours",
  "diesel_gallons", "traction_electricity_kwh", "charging_stops", "charging_time_hours", "total_trip_co2_kg",
  "total_kcal_delivered", "co2_per_1000kcal"
)
missing_cols <- setdiff(required_cols, as.character(scenario_cols$column_name %||% character()))
if (length(missing_cols) > 0) {
  add_result("scenario_rows_columns", "FAIL", paste("Missing columns:", paste(missing_cols, collapse = ", ")))
} else {
  add_result("scenario_rows_columns", "PASS", "scenario_rows includes required normalized columns")
}

dupes <- duckdb_csv_query(opt$db, paste(
  "SELECT run_id, layer_type, COALESCE(chunk_id, '') AS chunk_id, replicate_id, factory, powertrain, reefer_state, product_load, COUNT(*) AS n",
  "FROM scenario_rows GROUP BY 1,2,3,4,5,6,7,8 HAVING COUNT(*) > 1"
))
if (nrow(dupes) > 0) {
  add_result("scenario_row_duplicates", "FAIL", paste("Duplicate normalized scenario rows:", nrow(dupes)))
} else {
  add_result("scenario_row_duplicates", "PASS", "No duplicate scenario row keys detected")
}

crossed_bad <- duckdb_csv_query(opt$db, paste(
  "SELECT run_id, COUNT(DISTINCT factory || '|' || powertrain || '|' || reefer_state || '|' || product_load) AS n_cells",
  "FROM crossed_results GROUP BY 1 HAVING n_cells <> 16"
))
if (nrow(crossed_bad) > 0) {
  add_result("crossed_16_cell_coverage", "FAIL", paste("Crossed runs missing full 16-cell coverage:", paste(crossed_bad$run_id, collapse = ", ")))
} else {
  add_result("crossed_16_cell_coverage", "PASS", "All crossed runs include 16 distinct scenario cells")
}

realistic_bad <- duckdb_csv_query(opt$db, paste(
  "SELECT DISTINCT run_id FROM realistic_results",
  "WHERE NOT (",
  "(factory = 'kansas' AND product_load = 'dry' AND reefer_state = 'off')",
  "OR",
  "(factory = 'texas' AND product_load = 'refrigerated' AND reefer_state = 'on')",
  ")"
))
if (nrow(realistic_bad) > 0) {
  add_result("realistic_pairings", "FAIL", paste("realistic_results contains non-realistic pairings for run_ids:", paste(realistic_bad$run_id, collapse = ", ")))
} else {
  add_result("realistic_pairings", "PASS", "realistic_results is limited to realistic product-system pairings")
}

fwrite(results, report_csv)
writeLines(c(
  "Transport Catalog Validation",
  paste(sprintf("%s [%s] %s", results$check, results$status, results$detail), collapse = "\n")
), con = report_txt)

if (any(results$status == "FAIL")) quit(save = "no", status = 1)
cat(report_txt, "\n", sep = "")
