#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

source_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
for (f in source_files) source(f, local = FALSE)

pick_dir <- function(root) {
  if (dir.exists(root)) return(root)
  stop("Run directory not found: ", root)
}

read_meta <- function(path) {
  if (!file.exists(path)) return(list())
  tryCatch(jsonlite::fromJSON(path), error = function(e) list())
}

option_list <- list(
  make_option(c("--runs_dir"), type = "character", default = "outputs/proposal", help = "Directory containing per-variant outputs."),
  make_option(c("--outdir"), type = "character", default = "outputs/analysis", help = "Output analysis directory."),
  make_option(c("--distance_min"), type = "double", default = 0.2, help = "Minimum distance multiplier for sensitivity sweep."),
  make_option(c("--distance_max"), type = "double", default = 2.0, help = "Maximum distance multiplier for sensitivity sweep."),
  make_option(c("--distance_step"), type = "double", default = 0.05, help = "Distance multiplier step for sensitivity sweep.")
)
opt <- parse_args(OptionParser(option_list = option_list))

runs_dir <- pick_dir(opt$runs_dir)
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

variant_dirs <- list.dirs(runs_dir, recursive = FALSE, full.names = TRUE)
variant_dirs <- variant_dirs[file.exists(file.path(variant_dirs, "results_summary.csv"))]
if (length(variant_dirs) == 0) stop("No variant outputs found under ", runs_dir)

variant_rows <- list()
for (d in variant_dirs) {
  rs <- utils::read.csv(file.path(d, "results_summary.csv"), stringsAsFactors = FALSE)
  md <- read_meta(file.path(d, "run_metadata.json"))
  q <- function(metric, col) {
    hit <- rs[rs$metric == metric, , drop = FALSE]
    if (nrow(hit) == 0 || !(col %in% names(hit))) return(NA_real_)
    as.numeric(hit[[col]][[1]])
  }

  variant_rows[[length(variant_rows) + 1]] <- data.frame(
    variant_id = if (!is.null(md$variant_id)) md$variant_id else basename(d),
    scenario_id = if (!is.null(md$scenario_id)) md$scenario_id else NA_character_,
    product_mode = if (!is.null(md$product_mode)) md$product_mode else NA_character_,
    spatial_structure = if (!is.null(md$spatial_structure)) md$spatial_structure else NA_character_,
    powertrain_config = if (!is.null(md$powertrain_config)) md$powertrain_config else NA_character_,
    regionalized_distance_scale = if (!is.null(md$regionalized_distance_scale)) as.numeric(md$regionalized_distance_scale) else NA_real_,
    ghg_total_mean = q("ghg_total", "mean"),
    ghg_total_p05 = q("ghg_total", "p05"),
    ghg_total_p50 = q("ghg_total", "p50"),
    ghg_total_p95 = q("ghg_total", "p95"),
    ghg_traction_mean = q("ghg_traction", "mean"),
    ghg_refrigeration_mean = q("ghg_refrigeration", "mean"),
    source_dir = d,
    stringsAsFactors = FALSE
  )
}
variant_summary <- do.call(rbind, variant_rows)
utils::write.csv(variant_summary, file.path(opt$outdir, "variant_summary.csv"), row.names = FALSE)

reefer_rows <- variant_summary[toupper(variant_summary$product_mode) == "REFRIGERATED", , drop = FALSE]
dry_rows <- variant_summary[toupper(variant_summary$product_mode) == "DRY", , drop = FALSE]
if (nrow(reefer_rows) == 0 || nrow(dry_rows) == 0) stop("Need both DRY and REFRIGERATED variant outputs.")

keys <- c("scenario_id", "spatial_structure", "powertrain_config")
joined <- merge(
  reefer_rows,
  dry_rows,
  by = keys,
  suffixes = c("_reefer", "_dry"),
  all = FALSE
)
if (nrow(joined) == 0) stop("No dry/refrigerated pairs matched on scenario/spatial/powertrain.")

mult <- seq(opt$distance_min, opt$distance_max, by = opt$distance_step)
comparison_rows <- list()
sens_rows <- list()
threshold_rows <- list()

for (i in seq_len(nrow(joined))) {
  r <- joined[i, , drop = FALSE]
  draws_path <- file.path(r$source_dir_reefer[[1]], "draws.csv.gz")
  if (!file.exists(draws_path)) next
  draws <- utils::read.csv(gzfile(draws_path), stringsAsFactors = FALSE)

  delta <- draws$diff_gco2
  dq <- summary_quantiles(delta)

  sens <- simulate_delta_over_distance(draws, multipliers = mult)
  sens$scenario_id <- r$scenario_id[[1]]
  sens$spatial_structure <- r$spatial_structure[[1]]
  sens$powertrain_config <- r$powertrain_config[[1]]
  sens_rows[[length(sens_rows) + 1]] <- sens

  th <- estimate_distance_threshold(sens, baseline_distance_miles = mean(draws$distance_miles, na.rm = TRUE))
  th$scenario_id <- r$scenario_id[[1]]
  th$spatial_structure <- r$spatial_structure[[1]]
  th$powertrain_config <- r$powertrain_config[[1]]
  threshold_rows[[length(threshold_rows) + 1]] <- th

  comparison_rows[[length(comparison_rows) + 1]] <- data.frame(
    scenario_id = r$scenario_id[[1]],
    spatial_structure = r$spatial_structure[[1]],
    powertrain_config = r$powertrain_config[[1]],
    dry_mean = r$ghg_total_mean_dry[[1]],
    dry_p05 = r$ghg_total_p05_dry[[1]],
    dry_p50 = r$ghg_total_p50_dry[[1]],
    dry_p95 = r$ghg_total_p95_dry[[1]],
    refrigerated_mean = r$ghg_total_mean_reefer[[1]],
    refrigerated_p05 = r$ghg_total_p05_reefer[[1]],
    refrigerated_p50 = r$ghg_total_p50_reefer[[1]],
    refrigerated_p95 = r$ghg_total_p95_reefer[[1]],
    delta_mean = dq[["mean"]],
    delta_p05 = dq[["p05"]],
    delta_p50 = dq[["p50"]],
    delta_p95 = dq[["p95"]],
    p_refrigerated_gt_dry = mean(delta > 0, na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}

if (length(comparison_rows) == 0) stop("No comparison rows produced. Ensure refrigerated variant draws are present.")
comparison <- do.call(rbind, comparison_rows)
utils::write.csv(comparison, file.path(opt$outdir, "scenario_comparison.csv"), row.names = FALSE)

if (length(sens_rows) > 0) {
  sens_all <- do.call(rbind, sens_rows)
  utils::write.csv(sens_all, file.path(opt$outdir, "distance_sensitivity.csv"), row.names = FALSE)
}
if (length(threshold_rows) > 0) {
  th_all <- do.call(rbind, threshold_rows)
  utils::write.csv(th_all, file.path(opt$outdir, "distance_thresholds.csv"), row.names = FALSE)
}

cat("Wrote analysis outputs to", opt$outdir, "\n")
