#!/usr/bin/env Rscript
# scripts/summarize_charging_events.R
#
# Summarize per-charge-stop events into a scenario-level QA table.
#
# Reads:  <run_dir>/charging_events.csv   (from R/charger_event_logger.R)
# Writes: <run_dir>/charging_qa_summary.csv
#         <run_dir>/charging_qa_summary.json
#
# Usage:
#   Rscript scripts/summarize_charging_events.R --run_dir runs/<run_id>
#   Rscript scripts/summarize_charging_events.R --run_dir runs/<run_id> --format json
#   make summarize-charging-events CHARGER_RUN_DIR=runs/<run_id>
#
# Output metrics per scenario_id / powertrain combination:
#   mean_wait_minutes       Mean wait time across all occupied stops
#   p95_wait_minutes        95th-percentile wait time
#   broken_event_count      Stops where charger_state == "broken"
#   occupied_event_count    Stops where charger_state == "occupied"
#   compatible_charger_count  Stops where compatible == TRUE
#   failed_charge_count     Stops where charge_duration_minutes == 0
#   reefer_delay_total_min  Sum of reefer_runtime_increment_minutes
#   hos_delay_total_min     Sum of hos_delay_minutes
#   total_stops             Total charge-stop events
#
# Idempotent: re-running overwrites existing summary files.

suppressPackageStartupMessages(library(optparse))
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table is required")
if (!requireNamespace("jsonlite",   quietly = TRUE)) stop("jsonlite is required")

if (file.exists("R/log_helpers.R"))        source("R/log_helpers.R")
if (file.exists("R/charger_event_logger.R")) source("R/charger_event_logger.R")

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--run_dir"), type = "character",
              help = "Path to run directory containing charging_events.csv"),
  make_option(c("--out"), type = "character", default = "",
              help = "Output directory (default: same as --run_dir)"),
  make_option(c("--format"), type = "character", default = "both",
              help = "Output format: csv | json | both (default: both)")
)))

if (is.null(opt$run_dir)) stop("--run_dir is required")
run_dir  <- normalizePath(opt$run_dir, mustWork = FALSE)
out_dir  <- if (nzchar(opt$out)) normalizePath(opt$out, mustWork = FALSE) else run_dir
events_f <- file.path(run_dir, "charging_events.csv")

if (exists("configure_log")) configure_log(tag = "summarize_charging")
if (exists("log_event"))     log_event("INFO", "start", sprintf("summarize_charging_events: run_dir=%s", run_dir))

# ---------------------------------------------------------------------------
# Load events
# ---------------------------------------------------------------------------
if (!file.exists(events_f)) {
  msg <- sprintf("charging_events.csv not found in %s — no stochastic charging events recorded", run_dir)
  if (exists("log_event")) log_event("WARN", "load", msg) else message("WARN: ", msg)

  # Write empty summary so downstream tools don't error
  empty <- data.table::data.table(
    scenario_id             = character(),
    powertrain              = character(),
    mean_wait_minutes       = numeric(),
    p95_wait_minutes        = numeric(),
    broken_event_count      = integer(),
    occupied_event_count    = integer(),
    compatible_charger_count = integer(),
    failed_charge_count     = integer(),
    reefer_delay_total_min  = numeric(),
    hos_delay_total_min     = numeric(),
    total_stops             = integer()
  )
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  if (opt$format %in% c("csv", "both"))
    data.table::fwrite(empty, file.path(out_dir, "charging_qa_summary.csv"))
  if (opt$format %in% c("json", "both"))
    jsonlite::write_json(list(runs = list(), source = events_f, status = "no_events"),
                        file.path(out_dir, "charging_qa_summary.json"), pretty = TRUE)
  if (exists("log_event")) log_event("INFO", "complete", "Empty summary written (no events)")
  quit(status = 0)
}

ev <- data.table::fread(events_f, na.strings = c("", "NA"))
if (exists("log_event")) log_event("INFO", "load", sprintf("Loaded %d rows from %s", nrow(ev), events_f))

# ---------------------------------------------------------------------------
# Coerce columns
# ---------------------------------------------------------------------------
for (col in c("wait_time_minutes", "charge_duration_minutes",
              "reefer_runtime_increment_minutes", "hos_delay_minutes")) {
  if (!col %in% names(ev)) ev[, (col) := 0]
  ev[, (col) := as.numeric(get(col))]
  ev[is.na(get(col)), (col) := 0]
}
for (col in c("compatible")) {
  if (!col %in% names(ev)) ev[, (col) := NA]
  ev[, (col) := as.logical(get(col))]
}
for (col in c("charger_state")) {
  if (!col %in% names(ev)) ev[, (col) := "unknown"]
  ev[, (col) := as.character(get(col))]
}
for (col in c("scenario_id", "powertrain")) {
  if (!col %in% names(ev)) ev[, (col) := NA_character_]
  ev[, (col) := as.character(get(col))]
}

# ---------------------------------------------------------------------------
# Compute QA metrics
# ---------------------------------------------------------------------------
group_cols <- intersect(c("scenario_id", "powertrain"), names(ev))

compute_metrics <- function(d) {
  occupied <- d[charger_state == "occupied"]
  data.table::data.table(
    mean_wait_minutes        = if (nrow(occupied) > 0) mean(occupied$wait_time_minutes, na.rm = TRUE) else 0,
    p95_wait_minutes         = if (nrow(occupied) > 0) quantile(occupied$wait_time_minutes, 0.95, na.rm = TRUE) else 0,
    broken_event_count       = as.integer(sum(d$charger_state == "broken",   na.rm = TRUE)),
    occupied_event_count     = as.integer(sum(d$charger_state == "occupied", na.rm = TRUE)),
    compatible_charger_count = as.integer(sum(isTRUE(d$compatible) | d$compatible == TRUE, na.rm = TRUE)),
    failed_charge_count      = as.integer(sum(d$charge_duration_minutes == 0, na.rm = TRUE)),
    reefer_delay_total_min   = sum(d$reefer_runtime_increment_minutes, na.rm = TRUE),
    hos_delay_total_min      = sum(d$hos_delay_minutes, na.rm = TRUE),
    total_stops              = nrow(d)
  )
}

if (length(group_cols) > 0) {
  summary_dt <- ev[, compute_metrics(.SD), by = group_cols]
} else {
  summary_dt <- compute_metrics(ev)
}

# Round floats for readability
float_cols <- c("mean_wait_minutes", "p95_wait_minutes", "reefer_delay_total_min", "hos_delay_total_min")
for (col in float_cols) {
  if (col %in% names(summary_dt)) summary_dt[, (col) := round(get(col), 2)]
}

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (opt$format %in% c("csv", "both")) {
  out_csv <- file.path(out_dir, "charging_qa_summary.csv")
  data.table::fwrite(summary_dt, out_csv)
  if (exists("log_event")) log_event("INFO", "write", sprintf("CSV: %s", out_csv))
}

if (opt$format %in% c("json", "both")) {
  out_json <- file.path(out_dir, "charging_qa_summary.json")
  jsonlite::write_json(
    list(
      run_dir  = run_dir,
      source   = events_f,
      status   = "ok",
      n_rows   = nrow(ev),
      metrics  = jsonlite::fromJSON(jsonlite::toJSON(summary_dt, auto_unbox = TRUE))
    ),
    out_json, pretty = TRUE, auto_unbox = TRUE
  )
  if (exists("log_event")) log_event("INFO", "write", sprintf("JSON: %s", out_json))
}

# Print to stdout for interactive use
print(summary_dt)
if (exists("log_event")) log_event("INFO", "complete", sprintf("summarize_charging_events done: %d groups", nrow(summary_dt)))
