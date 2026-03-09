#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(optparse))
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--runs_csv"), type = "character", default = "outputs/summaries/full_n20_runs_merged.csv"),
  make_option(c("--out_csv"), type = "character", default = "outputs/presentation/representative_runs.csv"),
  make_option(c("--bundle_root"), type = "character", default = ""),
  make_option(c("--require_matched_route"), type = "character", default = "false"),
  make_option(c("--tracks_dir"), type = "character", default = "outputs/sim_tracks"),
  make_option(c("--require_track_files"), type = "character", default = "false")
)))

runs <- data.table::fread(opt$runs_csv)
for (cn in c("run_id","powertrain","status","co2_per_1000kcal","delivery_time_min")) if (!cn %in% names(runs)) runs[, (cn) := NA]
runs[, run_id := as.character(run_id)]
runs[, co2_kg_total := if ("co2_kg_total" %in% names(runs)) suppressWarnings(as.numeric(co2_kg_total)) else NA_real_]
runs[, co2_per_1000kcal := suppressWarnings(as.numeric(co2_per_1000kcal))]
runs[!is.finite(co2_per_1000kcal) & is.finite(co2_kg_total), co2_per_1000kcal := co2_kg_total]
runs[, powertrain := tolower(as.character(powertrain))]
runs[!powertrain %in% c("diesel", "bev"), powertrain := ifelse(grepl("_bev_", run_id), "bev", ifelse(grepl("_diesel_", run_id), "diesel", powertrain))]
runs[, status := tolower(trimws(as.character(status)))]
runs[, delivery_time_min := suppressWarnings(as.numeric(delivery_time_min))]
if (!"route_id" %in% names(runs)) runs[, route_id := NA_character_]
if (!"origin_network" %in% names(runs)) runs[, origin_network := NA_character_]
if (!"traffic_mode" %in% names(runs)) runs[, traffic_mode := NA_character_]
if (!"scenario" %in% names(runs)) runs[, scenario := NA_character_]
if (!"product_type" %in% names(runs)) runs[, product_type := NA_character_]
runs[, product_type := tolower(trimws(as.character(product_type)))]
runs[!product_type %in% c("dry", "refrigerated"), product_type := ifelse(
  grepl("refrigerated", tolower(run_id), fixed = TRUE), "refrigerated",
  ifelse(grepl("dry", tolower(run_id), fixed = TRUE), "dry", NA_character_)
)]

if (nzchar(opt$bundle_root) && dir.exists(opt$bundle_root)) {
  summ_paths <- list.files(opt$bundle_root, pattern = "summaries\\.csv$", recursive = TRUE, full.names = TRUE)
  if (length(summ_paths) > 0) {
    summ_rows <- lapply(summ_paths, function(p) {
      d <- tryCatch(data.table::fread(p, showProgress = FALSE), error = function(e) NULL)
      if (is.null(d) || nrow(d) == 0) return(NULL)
      keep <- intersect(names(d), c("run_id","route_id","origin_network","traffic_mode","scenario","co2_per_1000kcal","delivery_time_min","status"))
      if (length(keep) == 0) return(NULL)
      out <- data.table::as.data.table(d[, ..keep])
      out[, run_id := as.character(run_id)]
      out
    })
    summ_rows <- Filter(Negate(is.null), summ_rows)
    if (length(summ_rows) > 0) {
      summ <- data.table::rbindlist(summ_rows, fill = TRUE, use.names = TRUE)
      for (nm in c("route_id","origin_network","traffic_mode","scenario")) if (!nm %in% names(summ)) summ[, (nm) := NA_character_]
      runs <- merge(
        runs,
        unique(summ[, .(run_id, route_id, origin_network, traffic_mode, scenario)]),
        by = "run_id",
        all.x = TRUE,
        suffixes = c("", ".summ")
      )
      for (nm in c("route_id","origin_network","traffic_mode","scenario")) {
        alt <- paste0(nm, ".summ")
        if (alt %in% names(runs)) {
          runs[is.na(get(nm)) | !nzchar(as.character(get(nm))), (nm) := as.character(get(alt))]
          runs[, (alt) := NULL]
        }
      }
    }
  }
}

ok <- runs[(is.na(status) | status %in% c("", "ok", "na", "nan", "plan_soc_violation")) & is.finite(co2_per_1000kcal)]
if (nrow(ok) == 0) ok <- runs[is.finite(co2_per_1000kcal)]
if (nrow(ok) == 0) stop("No valid rows for representative selection")

pick_group <- function(d, pt, fallback_any_status = FALSE, matched_route = FALSE) {
  if (nrow(d) == 0) return(NULL)
  med_co2 <- stats::median(d$co2_per_1000kcal, na.rm = TRUE)
  has_t <- any(is.finite(d$delivery_time_min))
  med_t <- if (has_t) stats::median(d$delivery_time_min, na.rm = TRUE) else NA_real_
  d[, score := abs(co2_per_1000kcal - med_co2) + if (has_t) 0.01 * abs(delivery_time_min - med_t) else 0]
  d <- d[order(score)]
  data.table::data.table(
    run_id = as.character(d$run_id[[1]]),
    powertrain = as.character(pt),
    route_id = as.character(d$route_id[[1]] %||% ""),
    origin_network = as.character(d$origin_network[[1]] %||% ""),
    traffic_mode = as.character(d$traffic_mode[[1]] %||% ""),
    scenario = as.character(d$scenario[[1]] %||% ""),
    matched_route = as.logical(matched_route),
    selection_rule = paste0(if (has_t) "closest_to_joint_median_co2_and_time" else "closest_to_median_co2",
      if (isTRUE(fallback_any_status)) "_fallback_any_status" else ""),
    median_co2_per_1000kcal = med_co2,
    median_delivery_time_min = med_t
  )
}

pick_pt <- function(pt) {
  d_ok <- ok[powertrain == pt]
  if (nrow(d_ok) > 0) return(pick_group(d_ok, pt, fallback_any_status = FALSE, matched_route = FALSE))
  d_any <- runs[powertrain == pt & is.finite(co2_per_1000kcal)]
  if (nrow(d_any) > 0) return(pick_group(d_any, pt, fallback_any_status = TRUE, matched_route = FALSE))
  NULL
}

parse_bool <- function(x, default = TRUE) {
  raw <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(raw)) return(isTRUE(default))
  if (raw %in% c("1", "true", "yes", "y")) return(TRUE)
  if (raw %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Boolean flag must be true/false")
}
`%||%` <- function(x, y) if (is.null(x)) y else x
require_matched_route <- parse_bool(opt$require_matched_route, default = TRUE)
require_track_files <- parse_bool(opt$require_track_files, default = TRUE)

normalize_run_id <- function(x) {
  tolower(gsub("\\.csv(\\.gz)?$", "", as.character(x), perl = TRUE))
}

if (isTRUE(require_track_files)) {
  if (!dir.exists(opt$tracks_dir)) stop("tracks_dir does not exist: ", opt$tracks_dir)
  track_files <- list.files(opt$tracks_dir, pattern = "\\.csv(\\.gz)?$", full.names = FALSE)
  track_ids <- normalize_run_id(track_files)
  if (length(track_ids) == 0) stop("No track files found under tracks_dir: ", opt$tracks_dir)
  runs[, run_id_norm := normalize_run_id(run_id)]
  runs <- runs[run_id_norm %in% track_ids]
  runs[, run_id_norm := NULL]
  if (nrow(runs) == 0) stop("No runs have matching track files under tracks_dir: ", opt$tracks_dir)
}

matched <- ok[
  !is.na(route_id) & nzchar(route_id) &
    !is.na(origin_network) & nzchar(origin_network) &
    !is.na(traffic_mode) & nzchar(traffic_mode) &
    !is.na(scenario) & nzchar(scenario)
]
grp <- matched[, .(
  n_pt = data.table::uniqueN(powertrain),
  has_diesel = any(powertrain == "diesel"),
  has_bev = any(powertrain == "bev"),
  mean_co2 = mean(co2_per_1000kcal, na.rm = TRUE),
  mean_t = mean(delivery_time_min, na.rm = TRUE)
), by = .(scenario, origin_network, traffic_mode, route_id)]
grp <- grp[n_pt >= 2 & has_diesel & has_bev]

if (nrow(grp) > 0) {
  med_co2 <- stats::median(grp$mean_co2, na.rm = TRUE)
  med_t <- stats::median(grp$mean_t, na.rm = TRUE)
  grp[, grp_score := abs(mean_co2 - med_co2) + 0.01 * abs(mean_t - med_t)]
  data.table::setorder(grp, grp_score)
  g <- grp[1]

  pick_one <- function(pt) {
    d <- matched[
      powertrain == pt &
      scenario == g$scenario &
      origin_network == g$origin_network &
      traffic_mode == g$traffic_mode &
      route_id == g$route_id
    ]
    if (nrow(d) == 0) return(NULL)
    # Prefer refrigerated runs for animation/diagnostic representatives when available.
    # This avoids selecting dry rows that legitimately have zero TRU values.
    if ("product_type" %in% names(d) && any(tolower(as.character(d$product_type)) == "refrigerated", na.rm = TRUE)) {
      d_ref <- d[tolower(as.character(product_type)) == "refrigerated"]
      if (nrow(d_ref) > 0) d <- d_ref
    }
    pick_group(d, pt, fallback_any_status = FALSE, matched_route = TRUE)
  }

  out_list <- list(pick_one("diesel"), pick_one("bev"))
  out_list <- Filter(Negate(is.null), out_list)
  if (length(out_list) == 2) {
    out <- data.table::rbindlist(out_list, fill = TRUE, use.names = TRUE)
  } else {
    out <- NULL
  }
} else {
  out <- NULL
}

if (is.null(out) || nrow(out) < 2) {
  if (isTRUE(require_matched_route)) {
    stop("No matched diesel/BEV route candidates found. Provide runs with shared route_id/origin/traffic/scenario.")
  }
  out_list <- list(
    pick_pt("diesel"),
    pick_pt("bev")
  )
  out_list <- Filter(Negate(is.null), out_list)
  if (length(out_list) == 0) stop("No representative runs selected")
  out <- data.table::rbindlist(out_list, fill = TRUE, use.names = TRUE)
}

dir.create(dirname(opt$out_csv), recursive = TRUE, showWarnings = FALSE)
data.table::fwrite(out, opt$out_csv)
cat("Wrote", opt$out_csv, "\n")
