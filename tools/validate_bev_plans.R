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
  make_option(c("--bev_plans_csv"), type = "character", default = "data/derived/bev_route_plans.csv"),
  make_option(c("--routes_csv"), type = "character", default = "data/derived/routes_facility_to_petco.csv"),
  make_option(c("--bundle_root"), type = "character", default = "", help = "Optional run bundle root to derive used route_ids and observed charging time"),
  make_option(c("--outdir"), type = "character", default = "outputs/validation/bev_plans"),
  make_option(c("--single_charge_range_miles"), type = "double", default = 250),
  make_option(c("--allow_no_plan_fallback"), type = "character", default = "false"),
  make_option(c("--fail_on_error"), type = "character", default = "true")
)
opt <- parse_args(OptionParser(option_list = option_list))

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
parse_bool <- function(x, default = FALSE) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Invalid boolean flag: ", x)
}

if (!file.exists(opt$bev_plans_csv)) stop("BEV plans CSV not found: ", opt$bev_plans_csv)
if (!file.exists(opt$routes_csv)) stop("Routes CSV not found: ", opt$routes_csv)
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

plans <- data.table::fread(opt$bev_plans_csv, showProgress = FALSE)
routes <- data.table::fread(opt$routes_csv, showProgress = FALSE)
if (!"route_id" %in% names(plans)) stop("bev_plans_csv missing route_id column")
if (!"route_id" %in% names(routes)) stop("routes_csv missing route_id column")

used_route_ids <- unique(as.character(routes$route_id))
observed_charge <- data.table::data.table()
if (nzchar(opt$bundle_root) && dir.exists(opt$bundle_root)) {
  sum_files <- list.files(opt$bundle_root, pattern = "summaries\\.csv$", recursive = TRUE, full.names = TRUE)
  if (length(sum_files) > 0) {
    sum_list <- lapply(sum_files, function(path) {
      d <- tryCatch(data.table::fread(path, showProgress = FALSE), error = function(e) NULL)
      if (is.null(d) || nrow(d) == 0 || !"route_id" %in% names(d)) return(NULL)
      d
    })
    sum_list <- Filter(Negate(is.null), sum_list)
    if (length(sum_list) > 0) {
      sums <- data.table::rbindlist(sum_list, fill = TRUE, use.names = TRUE)
      used_route_ids <- unique(c(used_route_ids, as.character(sums$route_id)))
      if ("time_charging_min" %in% names(sums)) {
        observed_charge <- sums[, .(
          observed_total_planned_charging_time_min = mean(as.numeric(time_charging_min), na.rm = TRUE)
        ), by = .(route_id = as.character(route_id))]
      }
    }
  }
}
used_route_ids <- used_route_ids[nzchar(used_route_ids)]

plan_rows <- plans[, .(
  plan_exists = TRUE,
  n_plans = .N,
  number_of_charging_stops = as.integer(mean(as.numeric(waypoint_count), na.rm = TRUE)),
  station_ids_used = paste(sort(unique(unlist(strsplit(paste(as.character(waypoint_station_ids), collapse = "|"), "\\|")))), collapse = "|"),
  total_planned_charging_time_min = if ("total_planned_charging_time_min" %in% names(plans)) {
    mean(as.numeric(total_planned_charging_time_min), na.rm = TRUE)
  } else {
    NA_real_
  }
), by = .(route_id = as.character(route_id))]

route_dist <- routes[, .(
  total_distance_m = suppressWarnings(max(as.numeric(distance_m), na.rm = TRUE)),
  facility_id = as.character(facility_id[[1]] %||% NA_character_)
), by = .(route_id = as.character(route_id))]

audit <- data.table::data.table(route_id = used_route_ids)
audit <- merge(audit, route_dist, by = "route_id", all.x = TRUE)
audit <- merge(audit, plan_rows, by = "route_id", all.x = TRUE)
if (nrow(observed_charge) > 0) {
  audit <- merge(audit, observed_charge, by = "route_id", all.x = TRUE)
}
audit[is.na(plan_exists), `:=`(plan_exists = FALSE, n_plans = 0L, number_of_charging_stops = 0L, station_ids_used = "")]

range_miles <- as.numeric(opt$single_charge_range_miles %||% 250)
audit[, is_longhaul := is.finite(as.numeric(total_distance_m)) & as.numeric(total_distance_m) > range_miles * 1609.34]
allow_fallback <- parse_bool(opt$allow_no_plan_fallback, default = FALSE)
audit[, validation_status := ifelse(is_longhaul & !plan_exists & !allow_fallback, "FAIL", "PASS")]
audit[, validation_message := ifelse(
  validation_status == "FAIL",
  "Long-haul route has no BEV plan and no fallback allowed",
  "OK"
)]

out_csv <- file.path(opt$outdir, "bev_plan_validation_report.csv")
out_json <- file.path(opt$outdir, "bev_plan_validation_report.json")
data.table::fwrite(audit, out_csv)
jsonlite::write_json(list(
  generated_at_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
  bev_plans_csv = normalizePath(opt$bev_plans_csv, winslash = "/", mustWork = TRUE),
  routes_csv = normalizePath(opt$routes_csv, winslash = "/", mustWork = TRUE),
  single_charge_range_miles = range_miles,
  allow_no_plan_fallback = allow_fallback,
  rows = as.data.frame(audit)
), out_json, pretty = TRUE, auto_unbox = TRUE, null = "null")

cat("Wrote", out_csv, "\n")
cat("Wrote", out_json, "\n")

if (parse_bool(opt$fail_on_error, default = TRUE) && any(audit$validation_status == "FAIL")) {
  stop("BEV route-plan validation failed")
}
