#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")

option_list <- list(
  make_option(c("--bundle_roots"), type = "character", default = "", help = "Comma-separated bundle root directories to scan"),
  make_option(c("--runs_out"), type = "character", default = "outputs/summaries/route_sim_runs_merged.csv"),
  make_option(c("--summary_out"), type = "character", default = "outputs/summaries/route_sim_summary_merged.csv"),
  make_option(c("--summary_by_origin_out"), type = "character", default = "", help = "Optional explicit path for origin-separated summary CSV")
)
opt <- parse_args(OptionParser(option_list = option_list))

parse_csv_tokens <- function(x) {
  raw <- as.character(x)
  if (!length(raw) || is.na(raw)) raw <- ""
  if (!nzchar(raw)) return(character())
  parts <- trimws(unlist(strsplit(raw, ",")))
  parts[nzchar(parts)]
}

bundle_roots <- parse_csv_tokens(opt$bundle_roots)
if (length(bundle_roots) == 0) stop("--bundle_roots is required")

source("R/sim/08_outputs.R", local = FALSE)

default_summary_by_origin_out <- function(summary_out) {
  d <- dirname(summary_out)
  b <- basename(summary_out)
  ext <- tools::file_ext(b)
  stem <- if (nzchar(ext)) sub(paste0("\\.", ext, "$"), "", b) else b
  file.path(d, paste0(stem, "_by_origin", if (nzchar(ext)) paste0(".", ext) else ".csv"))
}

required_cols <- c("run_id", "scenario", "powertrain", "co2_kg_total")

is_aggregate_runs_file <- function(path) {
  hdr <- tryCatch(data.table::fread(path, nrows = 0L, showProgress = FALSE), error = function(e) NULL)
  if (is.null(hdr)) return(FALSE)
  cols <- names(hdr)
  all(required_cols %in% cols)
}

scan_runs_files <- function(root) {
  if (!dir.exists(root)) return(character())
  files <- list.files(root, pattern = "runs\\.csv$", recursive = TRUE, full.names = TRUE)
  if (length(files) == 0) return(character())
  files[vapply(files, is_aggregate_runs_file, logical(1))]
}

runs_files <- unique(unlist(lapply(bundle_roots, scan_runs_files), use.names = FALSE))
pair_summary_files <- unique(unlist(lapply(bundle_roots, function(root) {
  if (!dir.exists(root)) return(character())
  files <- list.files(root, pattern = "summaries\\.csv$", recursive = TRUE, full.names = TRUE)
  files[grepl("/pair_", dirname(files))]
}), use.names = FALSE))

runs <- NULL
if (length(runs_files) > 0) {
  runs_list <- lapply(runs_files, function(path) {
    dt <- data.table::fread(path, showProgress = FALSE)
    dt[, source_runs_csv := path]
    dt
  })
  runs <- data.table::rbindlist(runs_list, fill = TRUE, use.names = TRUE)
} else if (length(pair_summary_files) > 0) {
  pair_rows <- lapply(pair_summary_files, function(path) {
    d <- data.table::fread(path, showProgress = FALSE)
    if (!all(c("run_id", "scenario", "co2_kg_total") %in% names(d))) return(NULL)
    d[, powertrain := ifelse(grepl("_(bev|diesel)_", run_id), sub("^.*_(bev|diesel)_.*$", "\\1", run_id), NA_character_)]
    d[, status := if ("status" %in% names(d)) as.character(status) else "OK"]
    if (!"diesel_gal_total" %in% names(d)) {
      d[, diesel_gal_total := rowSums(cbind(
        if ("diesel_gal_propulsion" %in% names(d)) as.numeric(diesel_gal_propulsion) else 0,
        if ("diesel_gal_tru" %in% names(d)) as.numeric(diesel_gal_tru) else 0
      ), na.rm = TRUE)]
    }
    if (!"energy_kwh_total" %in% names(d)) {
      d[, energy_kwh_total := rowSums(cbind(
        if ("energy_kwh_propulsion" %in% names(d)) as.numeric(energy_kwh_propulsion) else 0,
        if ("energy_kwh_tru" %in% names(d)) as.numeric(energy_kwh_tru) else 0
      ), na.rm = TRUE)]
    }
    d[, source_runs_csv := path]
    keep <- intersect(
      c(
        "run_id", "pair_id", "scenario", "powertrain", "origin_network", "traffic_mode", "status",
        "co2_kg_total", "diesel_gal_total", "energy_kwh_total", "source_runs_csv"
      ),
      names(d)
    )
    d[, ..keep]
  })
  pair_rows <- Filter(Negate(is.null), pair_rows)
  if (length(pair_rows) > 0) {
    runs <- data.table::rbindlist(pair_rows, fill = TRUE, use.names = TRUE)
  }
}
if (is.null(runs) || nrow(runs) == 0) {
  stop(
    "No aggregate runs.csv files found under bundle_roots: ",
    paste(bundle_roots, collapse = ", "),
    ". Also could not reconstruct from pair summaries."
  )
}

# Preserve these key columns across mixed inputs.
if (!"pair_id" %in% names(runs)) runs[, pair_id := NA_character_]
if (!"origin_network" %in% names(runs)) runs[, origin_network := NA_character_]
if (!"diesel_gal_total" %in% names(runs)) {
  runs[, diesel_gal_total := rowSums(cbind(
    if ("diesel_gal_propulsion" %in% names(runs)) as.numeric(diesel_gal_propulsion) else 0,
    if ("diesel_gal_tru" %in% names(runs)) as.numeric(diesel_gal_tru) else 0
  ), na.rm = TRUE)]
}
if (!"energy_kwh_total" %in% names(runs)) {
  runs[, energy_kwh_total := rowSums(cbind(
    if ("energy_kwh_propulsion" %in% names(runs)) as.numeric(energy_kwh_propulsion) else 0,
    if ("energy_kwh_tru" %in% names(runs)) as.numeric(energy_kwh_tru) else 0
  ), na.rm = TRUE)]
}

sum_df <- summarize_route_sim_runs(as.data.frame(runs))
by_origin <- runs[, .(
  n_runs = .N,
  co2_kg_mean = mean(as.numeric(co2_kg_total), na.rm = TRUE),
  co2_kg_p50 = as.numeric(stats::quantile(as.numeric(co2_kg_total), 0.50, na.rm = TRUE, names = FALSE)),
  diesel_gal_total_mean = mean(as.numeric(diesel_gal_total), na.rm = TRUE),
  energy_kwh_total_mean = mean(as.numeric(energy_kwh_total), na.rm = TRUE)
), by = .(scenario, powertrain, origin_network, traffic_mode)]

dir.create(dirname(opt$runs_out), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(opt$summary_out), recursive = TRUE, showWarnings = FALSE)
summary_by_origin_out <- if (nzchar(opt$summary_by_origin_out)) opt$summary_by_origin_out else default_summary_by_origin_out(opt$summary_out)
dir.create(dirname(summary_by_origin_out), recursive = TRUE, showWarnings = FALSE)
data.table::fwrite(runs, opt$runs_out)
data.table::fwrite(sum_df, opt$summary_out)
data.table::fwrite(by_origin, summary_by_origin_out)

if (length(runs_files) > 0) {
  cat("Merged", nrow(runs), "rows from", length(runs_files), "aggregate files", "\n")
} else {
  cat("Merged", nrow(runs), "rows reconstructed from", length(pair_summary_files), "pair summary files", "\n")
}
cat("Wrote", opt$runs_out, "\n")
cat("Wrote", opt$summary_out, "\n")
cat("Wrote", summary_by_origin_out, "\n")
