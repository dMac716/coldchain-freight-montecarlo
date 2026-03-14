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
  make_option(c("--input_dir"), type = "character", default = "", help = "Bundle root or pair_* directory"),
  make_option(c("--outdir"), type = "character", default = "outputs/validation/route_sim"),
  make_option(c("--fail_on_error"), type = "character", default = "true"),
  make_option(c("--bev_single_charge_range_miles"), type = "double", default = 250)
)
opt <- parse_args(OptionParser(option_list = option_list))

parse_bool <- function(x, default = TRUE) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Invalid boolean flag: ", x)
}
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

if (!nzchar(opt$input_dir) || !dir.exists(opt$input_dir)) {
  stop("--input_dir must exist")
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

expected_origins <- c("dry_factory_set", "refrigerated_factory_set")
required_pair_files <- c("runs.jsonl", "runs.csv", "summaries.csv", "artifacts.json", "params.json")
required_runs_cols <- c("run_id", "pair_id", "origin_network", "traffic_mode")
required_summary_cols <- c(
  "run_id", "pair_id", "scenario", "origin_network", "traffic_mode", "route_id",
  "co2_kg_total", "delivery_time_min", "driver_driving_min", "driver_on_duty_min",
  "driver_off_duty_min", "energy_kwh_propulsion", "energy_kwh_tru", "diesel_gal_propulsion", "diesel_gal_tru"
)
required_aggregate_cols <- c(
  "run_id", "pair_id", "scenario", "powertrain", "origin_network", "traffic_mode",
  "co2_kg_total", "queue_delay_minutes", "load_unload_min", "refuel_stop_min", "connector_overhead_min"
)

find_pair_dirs <- function(input_dir) {
  if (all(file.exists(file.path(input_dir, c("runs.csv", "summaries.csv"))))) {
    return(normalizePath(input_dir, winslash = "/", mustWork = TRUE))
  }
  d <- list.dirs(input_dir, recursive = FALSE, full.names = TRUE)
  d <- d[grepl("(^|/)pair_", d)]
  d[file.exists(file.path(d, "runs.csv")) & file.exists(file.path(d, "summaries.csv"))]
}

pair_dirs <- find_pair_dirs(opt$input_dir)
input_is_pair_dir <- all(file.exists(file.path(opt$input_dir, c("runs.csv", "summaries.csv", "params.json", "artifacts.json", "runs.jsonl"))))
all_pair_runs <- list()
all_pair_summaries <- list()
pri <- 0L
psi <- 0L
if (length(pair_dirs) == 0) {
  add_check("pair_dirs_present", "FAIL", "No pair_* directories found", opt$input_dir)
} else {
  add_check("pair_dirs_present", "PASS", paste("Found", length(pair_dirs), "pair directories"), opt$input_dir)
}

for (pd in pair_dirs) {
  missing_files <- required_pair_files[!file.exists(file.path(pd, required_pair_files))]
  if (length(missing_files) > 0) {
    add_check("pair_files", "FAIL", paste("Missing required pair files:", paste(missing_files, collapse = ", ")), pd)
    next
  }
  add_check("pair_files", "PASS", "All required pair files present", pd)

  runs <- tryCatch(data.table::fread(file.path(pd, "runs.csv"), showProgress = FALSE), error = function(e) NULL)
  sums <- tryCatch(data.table::fread(file.path(pd, "summaries.csv"), showProgress = FALSE), error = function(e) NULL)
  if (is.null(runs) || is.null(sums)) {
    add_check("pair_read", "FAIL", "Failed to read runs.csv or summaries.csv", pd)
    next
  }
  pri <- pri + 1L
  runs[, pair_dir := pd]
  all_pair_runs[[pri]] <- runs
  psi <- psi + 1L
  sums[, pair_dir := pd]
  all_pair_summaries[[psi]] <- sums

  if (nrow(runs) == 2L) {
    add_check("pair_member_count", "PASS", "Pair runs.csv has exactly 2 rows", pd)
  } else {
    add_check("pair_member_count", "FAIL", paste("Pair runs.csv expected 2 rows but got", nrow(runs)), pd)
  }

  miss_runs <- setdiff(required_runs_cols, names(runs))
  if (length(miss_runs) == 0) {
    add_check("pair_runs_schema", "PASS", "Pair runs.csv required columns present", pd)
  } else {
    add_check("pair_runs_schema", "FAIL", paste("Missing pair runs columns:", paste(miss_runs, collapse = ", ")), pd)
  }

  miss_sums <- setdiff(required_summary_cols, names(sums))
  if (length(miss_sums) == 0) {
    add_check("pair_summaries_schema", "PASS", "Pair summaries.csv required columns present", pd)
  } else {
    add_check("pair_summaries_schema", "FAIL", paste("Missing pair summary columns:", paste(miss_sums, collapse = ", ")), pd)
  }

  origins <- sort(unique(as.character(runs$origin_network %||% NA_character_)))
  if (length(origins) == 2L && all(origins %in% expected_origins)) {
    add_check("pair_origin_labels", "PASS", paste("Origin labels valid:", paste(origins, collapse = ",")), pd)
  } else {
    add_check("pair_origin_labels", "FAIL", paste("Origin labels invalid:", paste(origins, collapse = ",")), pd)
  }

  if (all(c("origin_network", "product_type") %in% names(runs))) {
    pts <- unique(tolower(trimws(as.character(runs$product_type))))
    pts <- pts[nzchar(pts) & !is.na(pts)]
    ok <- length(pts) == 1L && pts[[1]] %in% c("dry", "refrigerated")
    add_check("pair_product_type_consistency", if (ok) "PASS" else "FAIL",
      paste0("Pair members share one product_type (dry|refrigerated). observed=", paste(pts, collapse = ",")), pd)
  }

  if (all(c("product_type", "energy_kwh_tru", "diesel_gal_tru") %in% names(sums))) {
    pt <- tolower(trimws(as.character(sums$product_type)))
    ktru <- suppressWarnings(as.numeric(sums$energy_kwh_tru))
    gtru <- suppressWarnings(as.numeric(sums$diesel_gal_tru))
    dry_idx <- which(pt == "dry")
    refr_idx <- which(pt == "refrigerated")
    dry_ok <- if (length(dry_idx) == 0) TRUE else all((!is.finite(ktru[dry_idx]) | abs(ktru[dry_idx]) < 1e-9) &
      (!is.finite(gtru[dry_idx]) | abs(gtru[dry_idx]) < 1e-9))
    refr_ok <- if (length(refr_idx) == 0) TRUE else any((is.finite(ktru[refr_idx]) & ktru[refr_idx] > 0) |
      (is.finite(gtru[refr_idx]) & gtru[refr_idx] > 0))
    add_check("pair_tru_policy_by_product_type", if (dry_ok && refr_ok) "PASS" else "FAIL",
      "Dry product has zero TRU usage; refrigerated product has TRU usage", pd)
  }

  num_cols <- intersect(c("co2_kg_total", "delivery_time_min", "driver_driving_min", "driver_on_duty_min", "driver_off_duty_min"), names(sums))
  if (length(num_cols) > 0) {
    bad <- vapply(num_cols, function(nm) {
      x <- suppressWarnings(as.numeric(sums[[nm]]))
      any(!is.finite(x) | x < 0, na.rm = TRUE)
    }, logical(1))
    if (!any(bad)) {
      add_check("pair_numeric_nonnegative", "PASS", "Key summary numeric fields finite and nonnegative", pd)
    } else {
      add_check("pair_numeric_nonnegative", "FAIL", paste("Invalid numeric columns:", paste(names(bad)[bad], collapse = ", ")), pd)
    }
  }
}

if (length(all_pair_summaries) > 0) {
  sums_all <- data.table::rbindlist(all_pair_summaries, fill = TRUE, use.names = TRUE)
  if (!"powertrain" %in% names(sums_all)) {
    sums_all[, powertrain := ifelse(
      grepl("_(bev|diesel)_", as.character(run_id)),
      sub("^.*_(bev|diesel)_.*$", "\\1", as.character(run_id)),
      NA_character_
    )]
  }
  sums_all[, powertrain := tolower(as.character(powertrain))]
  if (!"charge_stops" %in% names(sums_all)) sums_all[, charge_stops := NA_real_]
  if (!"time_charging_min" %in% names(sums_all)) sums_all[, time_charging_min := NA_real_]
  if (!"distance_miles" %in% names(sums_all)) sums_all[, distance_miles := NA_real_]
  if (!"status" %in% names(sums_all)) sums_all[, status := "OK"]

  bev <- sums_all[powertrain == "bev"]
  if (nrow(bev) > 0) {
    ek <- suppressWarnings(as.numeric(bev$energy_kwh_propulsion))
    cs <- suppressWarnings(as.numeric(bev$charge_stops))
    tc <- suppressWarnings(as.numeric(bev$time_charging_min))
    dm <- suppressWarnings(as.numeric(bev$distance_miles))
    limit_mi <- as.numeric(opt$bev_single_charge_range_miles %||% 250)

    bad_energy <- any(!is.finite(ek) | ek <= 0, na.rm = TRUE)
    add_check("bev_energy_positive", if (bad_energy) "FAIL" else "PASS", "BEV propulsion energy_kwh_propulsion > 0", opt$input_dir)

    bad_charge_nonneg <- any(is.finite(cs) & cs < 0, na.rm = TRUE)
    add_check("bev_charge_stops_nonnegative", if (bad_charge_nonneg) "FAIL" else "PASS", "BEV charge_stops >= 0", opt$input_dir)

    needs_charge <- is.finite(dm) & dm > limit_mi
    bad_needs_charge <- any(needs_charge & (!is.finite(cs) | cs <= 0), na.rm = TRUE)
    add_check("bev_longhaul_requires_charge", if (bad_needs_charge) "FAIL" else "PASS", paste0("BEV routes >", limit_mi, " miles require charge_stops > 0"), opt$input_dir)

    bad_charge_time <- any(is.finite(cs) & cs > 0 & (!is.finite(tc) | tc <= 0), na.rm = TRUE)
    add_check("bev_charge_time_consistency", if (bad_charge_time) "FAIL" else "PASS", "BEV time_charging_min > 0 when charge_stops > 0", opt$input_dir)
  }

  breakdown_cols <- c(
    "trip_duration_total_h", "driver_driving_min", "time_charging_min", "time_refuel_min",
    "time_traffic_delay_min", "driver_off_duty_min", "time_load_unload_min", "charge_stops", "refuel_stops"
  )
  for (cn in breakdown_cols) if (!cn %in% names(sums_all)) sums_all[, (cn) := NA_real_]
  rt <- sums_all[, lapply(.SD, function(x) mean(suppressWarnings(as.numeric(x)), na.rm = TRUE)), by = .(
    scenario = as.character(scenario %||% NA_character_),
    powertrain = as.character(powertrain %||% NA_character_),
    origin_network = as.character(origin_network %||% NA_character_),
    traffic_mode = as.character(traffic_mode %||% NA_character_)
  ), .SDcols = breakdown_cols]
  dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(rt, file.path(opt$outdir, "route_time_breakdown.csv"))
}

aggregate_runs <- file.path(opt$input_dir, "runs.csv")
if (!isTRUE(input_is_pair_dir) && file.exists(aggregate_runs)) {
  ar <- tryCatch(data.table::fread(aggregate_runs, showProgress = FALSE), error = function(e) NULL)
  if (is.null(ar)) {
    add_check("aggregate_read", "FAIL", "Failed to read aggregate runs.csv", aggregate_runs)
  } else {
    miss <- setdiff(required_aggregate_cols, names(ar))
    if (length(miss) == 0) {
      add_check("aggregate_schema", "PASS", "Aggregate runs.csv required columns present", aggregate_runs)
    } else {
      add_check("aggregate_schema", "FAIL", paste("Missing aggregate columns:", paste(miss, collapse = ", ")), aggregate_runs)
    }

    if (all(c("origin_network", "powertrain") %in% names(ar))) {
      on_ok <- !any(is.na(ar$origin_network) | !nzchar(as.character(ar$origin_network)))
      add_check("aggregate_origin_nonnull", if (on_ok) "PASS" else "FAIL", "origin_network non-null in aggregate runs.csv", aggregate_runs)

      pow <- tolower(as.character(ar$powertrain %||% ""))
      diesel_has_diesel <- TRUE
      bev_has_electric <- TRUE
      if ("diesel_gal_total" %in% names(ar)) {
        x <- suppressWarnings(as.numeric(ar$diesel_gal_total))
        diesel_has_diesel <- !any(pow == "diesel" & x <= 0, na.rm = TRUE)
      }
      if (all(c("energy_kwh_propulsion", "energy_kwh_tru") %in% names(ar))) {
        x <- suppressWarnings(as.numeric(ar$energy_kwh_propulsion)) + suppressWarnings(as.numeric(ar$energy_kwh_tru))
        bev_has_electric <- !any(pow == "bev" & x <= 0, na.rm = TRUE)
      }
      add_check("aggregate_physical_plausibility_diesel", if (diesel_has_diesel) "PASS" else "FAIL", "Diesel runs show positive diesel use", aggregate_runs)
      add_check("aggregate_physical_plausibility_bev", if (bev_has_electric) "PASS" else "FAIL", "BEV runs show positive electricity use", aggregate_runs)
    }
  }
}

report_df <- if (length(report) > 0) data.table::rbindlist(report, fill = TRUE) else data.frame()
if (!is.data.frame(report_df)) report_df <- as.data.frame(report_df)
if (nrow(report_df) == 0) {
  report_df <- data.frame(check_id = "no_checks", status = "FAIL", message = "No checks were executed", target = opt$input_dir, details = NA_character_, stringsAsFactors = FALSE)
}

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)
report_csv <- file.path(opt$outdir, "validation_report.csv")
report_json <- file.path(opt$outdir, "validation_report.json")

data.table::fwrite(report_df, report_csv)
jsonlite::write_json(list(
  generated_at_utc = as.character(format(Sys.time(), tz = "UTC", usetz = TRUE)),
  input_dir = as.character(opt$input_dir),
  checks = report_df
), report_json, pretty = TRUE, auto_unbox = TRUE, null = "null")

cat("Wrote", report_csv, "\n")
cat("Wrote", report_json, "\n")

if (isTRUE(parse_bool(opt$fail_on_error, default = TRUE)) && any(report_df$status == "FAIL")) {
  stop("Route simulation validation failed")
}
