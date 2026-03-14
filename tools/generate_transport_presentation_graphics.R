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
if (!requireNamespace("jsonlite", quietly = TRUE)) stop("jsonlite package required")
data.table::setDTthreads(1L)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

option_list <- list(
  make_option(c("--bundle_root"), type = "character", default = "outputs/run_bundle/full_n20_fix"),
  make_option(c("--validation_root"), type = "character", default = "outputs/validation/full_n20_fix"),
  make_option(c("--outdir"), type = "character", default = "outputs/presentation/transport_graphics"),
  make_option(c("--require_validation"), type = "character", default = "true"),
  make_option(c("--fps"), type = "integer", default = 20L),
  make_option(c("--duration_sec"), type = "double", default = 6)
)
opt <- parse_args(OptionParser(option_list = option_list))

parse_bool <- function(x, default = TRUE) {
  v <- tolower(trimws(as.character(x %||% "")))
  if (!nzchar(v)) return(isTRUE(default))
  if (v %in% c("1", "true", "yes", "y")) return(TRUE)
  if (v %in% c("0", "false", "no", "n")) return(FALSE)
  stop("Invalid boolean flag: ", x)
}

if (!dir.exists(opt$bundle_root)) stop("bundle_root not found: ", opt$bundle_root)
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

origin_levels <- c("dry_factory_set", "refrigerated_factory_set")

pair_summary_files <- list.files(
  opt$bundle_root,
  pattern = "summaries\\.csv$",
  recursive = TRUE,
  full.names = TRUE
)
pair_summary_files <- pair_summary_files[grepl("/pair_", dirname(pair_summary_files))]
if (length(pair_summary_files) == 0) stop("No pair summaries found under bundle_root: ", opt$bundle_root)

rows <- lapply(pair_summary_files, function(path) {
  d <- tryCatch(data.table::fread(path, showProgress = FALSE), error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  d[, source_summary_csv := path]
  d
})
rows <- Filter(Negate(is.null), rows)
if (length(rows) == 0) stop("No readable pair summaries found")
runs <- data.table::rbindlist(rows, fill = TRUE, use.names = TRUE)

need_cols <- c("run_id", "pair_id", "scenario", "origin_network", "traffic_mode", "status")
for (cn in need_cols) if (!cn %in% names(runs)) runs[, (cn) := NA_character_]
if (!"powertrain" %in% names(runs)) {
  runs[, powertrain := ifelse(
    grepl("_(bev|diesel)_", as.character(run_id)),
    sub("^.*_(bev|diesel)_.*$", "\\1", as.character(run_id)),
    NA_character_
  )]
}
runs[, powertrain := tolower(as.character(powertrain))]
runs[, scenario := as.character(scenario)]
runs[, origin_network := as.character(origin_network)]
runs[, traffic_mode := tolower(as.character(traffic_mode))]
runs[, status := as.character(status)]
runs[, status_norm := tolower(trimws(status))]

if (!"co2_per_1000kcal" %in% names(runs)) runs[, co2_per_1000kcal := NA_real_]
if (!"co2_kg_total" %in% names(runs)) runs[, co2_kg_total := NA_real_]
if (!"kcal_delivered" %in% names(runs)) runs[, kcal_delivered := NA_real_]
if (!"kcal_per_truck" %in% names(runs)) runs[, kcal_per_truck := NA_real_]
runs[, co2_per_1000kcal := suppressWarnings(as.numeric(co2_per_1000kcal))]
runs[, co2_kg_total := suppressWarnings(as.numeric(co2_kg_total))]
runs[, kcal_delivered := suppressWarnings(as.numeric(kcal_delivered))]
runs[, kcal_per_truck := suppressWarnings(as.numeric(kcal_per_truck))]
runs[!is.finite(co2_per_1000kcal) & is.finite(co2_kg_total) & is.finite(kcal_delivered) & kcal_delivered > 0,
  co2_per_1000kcal := co2_kg_total / (kcal_delivered / 1000)]
runs[!is.finite(co2_per_1000kcal) & is.finite(co2_kg_total) & is.finite(kcal_per_truck) & kcal_per_truck > 0,
  co2_per_1000kcal := co2_kg_total / (kcal_per_truck / 1000)]

for (cn in c("energy_kwh_propulsion", "energy_kwh_tru", "diesel_gal_propulsion", "diesel_gal_tru",
             "delivery_time_min", "trip_duration_total_h", "driver_driving_min", "driver_on_duty_min",
             "driver_off_duty_min", "time_charging_min", "time_refuel_min", "time_traffic_delay_min",
             "time_load_unload_min", "charge_stops", "refuel_stops")) {
  if (!cn %in% names(runs)) runs[, (cn) := NA_real_]
  runs[, (cn) := suppressWarnings(as.numeric(get(cn)))]
}

# Use only validated scenario/powertrain groups when validation reports are available.
valid_groups <- data.table::data.table()
if (isTRUE(parse_bool(opt$require_validation, default = TRUE)) && dir.exists(opt$validation_root)) {
  vfiles <- list.files(opt$validation_root, pattern = "validation_report\\.csv$", recursive = TRUE, full.names = TRUE)
  vfiles <- vfiles[grepl("/route_", dirname(vfiles))]
  if (length(vfiles) > 0) {
    vg <- lapply(vfiles, function(path) {
      d <- tryCatch(data.table::fread(path, showProgress = FALSE), error = function(e) NULL)
      if (is.null(d) || nrow(d) == 0) return(NULL)
      route_dir <- basename(dirname(path)) # route_SCENARIO_powertrain
      sc_pt <- sub("^route_", "", route_dir)
      pt <- sub("^.*_(diesel|bev)$", "\\1", sc_pt)
      sc <- sub("_(diesel|bev)$", "", sc_pt)
      fail <- any(as.character(d$status) == "FAIL", na.rm = TRUE)
      data.table::data.table(scenario = sc, powertrain = pt, has_fail = fail)
    })
    vg <- Filter(Negate(is.null), vg)
    if (length(vg) > 0) {
      valid_groups <- data.table::rbindlist(vg, fill = TRUE, use.names = TRUE)
      valid_groups <- unique(valid_groups[has_fail == FALSE, .(scenario, powertrain)])
    }
  }
}
if (nrow(valid_groups) > 0) {
  runs <- merge(runs, valid_groups, by = c("scenario", "powertrain"))
}

# Candidate selection: same scenario/powertrain/traffic/status=OK and matched origins by pair_id.
ok <- runs[
  (is.na(status_norm) | status_norm %in% c("ok", "", "na", "nan")) &
    origin_network %in% origin_levels &
    is.finite(co2_per_1000kcal)
]
if (nrow(ok) == 0) stop("No valid OK runs with finite co2_per_1000kcal after filtering")

pair_counts <- ok[, .(
  n_pairs_matched = {
    x <- .SD[, .N, by = .(pair_id, origin_network)][, .(n_orig = data.table::uniqueN(origin_network)), by = pair_id]
    sum(x$n_orig == 2L, na.rm = TRUE)
  },
  n_rows = .N
), by = .(scenario, powertrain, traffic_mode)]

if (nrow(pair_counts) == 0) stop("No candidate comparable cases found")

scenario_rank <- function(s) {
  if (identical(s, "CENTRALIZED")) return(1L)
  if (identical(s, "REGIONALIZED")) return(2L)
  if (identical(s, "SMOKE_LOCAL")) return(3L)
  9L
}
pair_counts[, s_rank := vapply(as.character(scenario), scenario_rank, integer(1))]
pair_counts[, p_rank := ifelse(as.character(powertrain) == "diesel", 1L, 2L)]
pair_counts[, t_rank := ifelse(as.character(traffic_mode) == "stochastic", 1L, 2L)]
data.table::setorder(pair_counts, -n_pairs_matched, -n_rows, s_rank, p_rank, t_rank)
chosen <- pair_counts[1]

sel <- ok[
  scenario == chosen$scenario &
    powertrain == chosen$powertrain &
    traffic_mode == chosen$traffic_mode
]
# Enforce matched pairs.
pair_ok <- sel[, .(n_orig = data.table::uniqueN(origin_network)), by = pair_id][n_orig == 2L]
sel <- merge(sel, pair_ok[, .(pair_id)], by = "pair_id")
if (nrow(sel) == 0) stop("Chosen case has no matched pairs after enforcement")

sel[, origin_network := factor(origin_network, levels = origin_levels)]
sel[, total_trip_time_h := ifelse(
  is.finite(trip_duration_total_h), trip_duration_total_h,
  ifelse(is.finite(delivery_time_min), delivery_time_min / 60, NA_real_)
)]
data.table::fwrite(
  sel,
  file.path(opt$outdir, "transport_mc_filtered_runs.csv")
)

# Metadata about filter logic and selected case.
metadata <- list(
  source = list(
    bundle_root = normalizePath(opt$bundle_root, winslash = "/", mustWork = TRUE),
    validation_root = if (dir.exists(opt$validation_root)) normalizePath(opt$validation_root, winslash = "/", mustWork = TRUE) else NA_character_,
    pair_summary_files = as.list(sort(unique(sel$source_summary_csv)))
  ),
  filter = list(
    scenario = as.character(chosen$scenario),
    powertrain = as.character(chosen$powertrain),
    traffic_mode = as.character(chosen$traffic_mode),
    status = "OK_or_blank_or_missing",
    origin_network = origin_levels,
    matched_pairs_enforced = TRUE,
    functional_unit_basis = "per_1000kcal",
    metric_main = "co2_per_1000kcal"
  ),
  counts = list(
    n_rows_selected = nrow(sel),
    n_pairs_matched = data.table::uniqueN(sel$pair_id),
    n_by_origin = as.list(sel[, .N, by = origin_network][order(origin_network)]$N)
  )
)
jsonlite::write_json(metadata, file.path(opt$outdir, "transport_graphics_filter_metadata.json"), pretty = TRUE, auto_unbox = TRUE, null = "null")

# Graphic 1 summary table.
summ1 <- sel[, .(
  system = as.character(origin_network[[1]]),
  n_runs = .N,
  n_pairs_matched = data.table::uniqueN(pair_id),
  mean = mean(co2_per_1000kcal, na.rm = TRUE),
  median = as.numeric(stats::quantile(co2_per_1000kcal, 0.5, na.rm = TRUE, names = FALSE)),
  sd = stats::sd(co2_per_1000kcal, na.rm = TRUE),
  p05 = as.numeric(stats::quantile(co2_per_1000kcal, 0.05, na.rm = TRUE, names = FALSE)),
  p25 = as.numeric(stats::quantile(co2_per_1000kcal, 0.25, na.rm = TRUE, names = FALSE)),
  p75 = as.numeric(stats::quantile(co2_per_1000kcal, 0.75, na.rm = TRUE, names = FALSE)),
  p95 = as.numeric(stats::quantile(co2_per_1000kcal, 0.95, na.rm = TRUE, names = FALSE)),
  min = min(co2_per_1000kcal, na.rm = TRUE),
  max = max(co2_per_1000kcal, na.rm = TRUE)
), by = origin_network]
summ1 <- summ1[, .(system, n_runs, n_pairs_matched, mean, median, sd, p05, p25, p75, p95, min, max)]
data.table::fwrite(summ1, file.path(opt$outdir, "transport_mc_distribution_summary.csv"))

plot_distribution <- function(path, device = c("png", "svg")) {
  device <- match.arg(device)
  if (device == "png") {
    png(path, width = 1400, height = 900, res = 150)
  } else {
    svg(path, width = 11, height = 7)
  }
  on.exit(dev.off(), add = TRUE)
  par(mar = c(5, 6, 6, 2) + 0.1)
  cols <- c("#2F80ED", "#EB5757")
  boxplot(
    co2_per_1000kcal ~ origin_network,
    data = sel,
    col = c("#d9e8ff", "#ffe1e1"),
    border = c("#1f5fbf", "#b13a3a"),
    ylab = "kg CO2 / 1000 kcal delivered",
    xlab = "System / Origin Network",
    main = "Transport Monte Carlo Emissions Distribution",
    sub = paste0("Scenario=", chosen$scenario, " | Powertrain=", chosen$powertrain, " | Traffic=", chosen$traffic_mode, " | Matched pairs=", data.table::uniqueN(sel$pair_id))
  )
  set.seed(123)
  for (i in seq_along(origin_levels)) {
    y <- sel[origin_network == origin_levels[[i]], co2_per_1000kcal]
    x <- jitter(rep(i, length(y)), amount = 0.12)
    points(x, y, pch = 16, col = grDevices::adjustcolor(cols[[i]], alpha.f = 0.45), cex = 0.75)
    m <- mean(y, na.rm = TRUE)
    ql <- as.numeric(stats::quantile(y, 0.025, na.rm = TRUE, names = FALSE))
    qh <- as.numeric(stats::quantile(y, 0.975, na.rm = TRUE, names = FALSE))
    segments(i, ql, i, qh, lwd = 3, col = cols[[i]])
    points(i, m, pch = 23, bg = cols[[i]], col = "white", cex = 1.5)
  }
  legend("topleft", inset = 0.01, bty = "n",
         legend = c("Dry factory set", "Refrigerated factory set", "Mean marker", "95% empirical interval"),
         pch = c(16, 16, 23, NA), lty = c(NA, NA, NA, 1), lwd = c(NA, NA, NA, 3),
         col = c(cols[[1]], cols[[2]], "black", "black"), pt.bg = c(NA, NA, "black", NA))
}
plot_distribution(file.path(opt$outdir, "transport_mc_distribution.png"), "png")
plot_distribution(file.path(opt$outdir, "transport_mc_distribution.svg"), "svg")

# Graphic 2: transport burden breakdown normalized per 1000 kcal.
sel[, kcal_norm := ifelse(is.finite(kcal_delivered) & kcal_delivered > 0, kcal_delivered,
                          ifelse(is.finite(kcal_per_truck) & kcal_per_truck > 0, kcal_per_truck, NA_real_))]
sel[, kcal_thousand := ifelse(is.finite(kcal_norm) & kcal_norm > 0, kcal_norm / 1000, NA_real_)]
metric_basis <- if (identical(as.character(chosen$powertrain), "bev")) "kWh / 1000 kcal" else "diesel gal / 1000 kcal"
if (identical(as.character(chosen$powertrain), "bev")) {
  sel[, propulsion_component := energy_kwh_propulsion / kcal_thousand]
  sel[, tru_component := energy_kwh_tru / kcal_thousand]
} else {
  sel[, propulsion_component := diesel_gal_propulsion / kcal_thousand]
  sel[, tru_component := diesel_gal_tru / kcal_thousand]
}
sel[, total_component := propulsion_component + tru_component]

breakdown <- sel[, .(
  system = as.character(origin_network[[1]]),
  metric_basis = metric_basis,
  propulsion_component = mean(propulsion_component, na.rm = TRUE),
  tru_component = mean(tru_component, na.rm = TRUE),
  total = mean(total_component, na.rm = TRUE)
), by = origin_network][, .(system, metric_basis, propulsion_component, tru_component, total)]
data.table::fwrite(breakdown, file.path(opt$outdir, "transport_burden_breakdown_values.csv"))

plot_breakdown <- function(path, device = c("png", "svg")) {
  device <- match.arg(device)
  if (device == "png") {
    png(path, width = 1400, height = 900, res = 150)
  } else {
    svg(path, width = 11, height = 7)
  }
  on.exit(dev.off(), add = TRUE)
  par(mar = c(5, 6, 6, 2) + 0.1)
  m <- rbind(
    breakdown$propulsion_component,
    breakdown$tru_component
  )
  colnames(m) <- breakdown$system
  rownames(m) <- c("Propulsion", "TRU/Refrigeration")
  cols <- c("#2D9CDB", "#F2994A")
  bp <- barplot(
    m,
    beside = FALSE,
    col = cols,
    ylim = c(0, max(colSums(m, na.rm = TRUE), na.rm = TRUE) * 1.25),
    ylab = metric_basis,
    xlab = "System / Origin Network",
    main = "Transport Burden Breakdown by System",
    sub = paste0("Scenario=", chosen$scenario, " | Powertrain=", chosen$powertrain, " | Traffic=", chosen$traffic_mode)
  )
  text(bp, colSums(m, na.rm = TRUE), labels = sprintf("Total: %.3f", colSums(m, na.rm = TRUE)), pos = 3, cex = 0.9)
  legend("topleft", inset = 0.01, legend = rownames(m), fill = cols, bty = "n")
}
plot_breakdown(file.path(opt$outdir, "transport_burden_breakdown.png"), "png")
plot_breakdown(file.path(opt$outdir, "transport_burden_breakdown.svg"), "svg")

# Animation: point-build distribution using actual selected runs.
anim_data <- data.table::copy(sel[, .(pair_id, origin_network, co2_per_1000kcal)])
data.table::setorder(anim_data, pair_id, origin_network)
anim_data[, row_index := .I]
n_points <- nrow(anim_data)
fps <- as.integer(opt$fps %||% 20L)
if (!is.finite(fps) || fps < 5L) fps <- 20L
duration <- as.numeric(opt$duration_sec %||% 6)
if (!is.finite(duration) || duration < 2) duration <- 6
n_frames <- max(30L, as.integer(ceiling(duration * fps)))

frame_dir <- file.path(opt$outdir, "_frames_transport_mc")
dir.create(frame_dir, recursive = TRUE, showWarnings = FALSE)

y_min <- min(anim_data$co2_per_1000kcal, na.rm = TRUE)
y_max <- max(anim_data$co2_per_1000kcal, na.rm = TRUE)
pad <- 0.08 * max(1e-9, y_max - y_min)
y_lim <- c(y_min - pad, y_max + pad)
cols <- c(dry_factory_set = "#2F80ED", refrigerated_factory_set = "#EB5757")
means <- anim_data[, .(m = mean(co2_per_1000kcal, na.rm = TRUE)), by = origin_network]

for (f in seq_len(n_frames)) {
  k <- as.integer(ceiling(n_points * f / n_frames))
  df <- anim_data[row_index <= k]
  fp <- file.path(frame_dir, sprintf("frame_%04d.png", f))
  png(fp, width = 1400, height = 900, res = 150)
  par(mar = c(5, 6, 6, 2) + 0.1)
  plot(NA, xlim = c(0.5, 2.5), ylim = y_lim, xaxt = "n",
       xlab = "System / Origin Network",
       ylab = "kg CO2 / 1000 kcal delivered",
       main = "Monte Carlo Build: Transport Emissions Distribution",
       sub = paste0("Scenario=", chosen$scenario, " | Powertrain=", chosen$powertrain, " | Traffic=", chosen$traffic_mode,
                    " | Frame ", f, "/", n_frames))
  axis(1, at = c(1, 2), labels = origin_levels)
  if (nrow(df) > 0) {
    set.seed(100 + f)
    x <- ifelse(df$origin_network == origin_levels[[1]], 1, 2) + stats::runif(nrow(df), -0.15, 0.15)
    pcols <- ifelse(df$origin_network == origin_levels[[1]], cols[[1]], cols[[2]])
    points(x, df$co2_per_1000kcal, pch = 16, col = grDevices::adjustcolor(pcols, alpha.f = 0.55), cex = 0.8)
  }
  for (i in seq_along(origin_levels)) {
    mn <- means[origin_network == origin_levels[[i]], m]
    if (length(mn) == 1 && is.finite(mn)) {
      segments(i - 0.25, mn, i + 0.25, mn, lwd = 3, col = cols[[origin_levels[[i]]]])
      points(i, mn, pch = 23, bg = cols[[origin_levels[[i]]]], col = "white", cex = 1.25)
    }
  }
  legend("topleft", inset = 0.01, bty = "n",
         legend = c("Dry factory set", "Refrigerated factory set", "Mean"),
         pch = c(16, 16, 23),
         col = c(cols[[1]], cols[[2]], "black"),
         pt.bg = c(NA, NA, "black"))
  dev.off()
}

file.copy(file.path(frame_dir, sprintf("frame_%04d.png", n_frames)),
          file.path(opt$outdir, "transport_mc_animation_last_frame.png"),
          overwrite = TRUE)

gif_path <- file.path(opt$outdir, "transport_mc_animation.gif")
mp4_path <- file.path(opt$outdir, "transport_mc_animation.mp4")
gif_ok <- FALSE
mp4_ok <- FALSE

frame_glob <- file.path(frame_dir, "frame_*.png")
frame_files <- sort(list.files(frame_dir, pattern = "^frame_\\d+\\.png$", full.names = TRUE))
if (length(frame_files) > 0 && nzchar(Sys.which("magick"))) {
  cmd <- paste(
    "magick -delay", as.integer(round(100 / fps)),
    paste(shQuote(frame_files), collapse = " "),
    shQuote(gif_path)
  )
  gif_ok <- identical(system(cmd), 0L) && file.exists(gif_path)
}
if (!gif_ok && length(frame_files) > 0 && nzchar(Sys.which("convert"))) {
  cmd <- paste(
    "convert -delay", as.integer(round(100 / fps)), "-loop 0",
    paste(shQuote(frame_files), collapse = " "),
    shQuote(gif_path)
  )
  gif_ok <- identical(system(cmd), 0L) && file.exists(gif_path)
}
if (nzchar(Sys.which("ffmpeg"))) {
  cmd <- sprintf("ffmpeg -y -framerate %d -i %s -pix_fmt yuv420p %s",
                 fps, shQuote(file.path(frame_dir, "frame_%04d.png")), shQuote(mp4_path))
  mp4_ok <- identical(system(cmd), 0L) && file.exists(mp4_path)
} else {
  mp4_ok <- FALSE
}

# Notes README.
notes <- c(
  "# Transport Presentation Graphics Notes",
  "",
  "## Sources Used",
  paste0("- bundle_root: ", normalizePath(opt$bundle_root, winslash = "/", mustWork = TRUE)),
  paste0("- pair summaries scanned: ", length(pair_summary_files)),
  if (dir.exists(opt$validation_root)) paste0("- validation_root: ", normalizePath(opt$validation_root, winslash = "/", mustWork = TRUE)) else "- validation_root: not provided/available",
  "",
  "## Filter Logic Applied",
  paste0("- scenario = ", chosen$scenario),
  paste0("- powertrain = ", chosen$powertrain),
  paste0("- traffic_mode = ", chosen$traffic_mode),
  "- status in {OK, blank, missing/NA}",
  "- origin_network in {dry_factory_set, refrigerated_factory_set}",
  "- matched pair_id enforced (both origins required per pair)",
  "- functional_unit_basis = per_1000kcal",
  "",
  "## Rows In/Out",
  paste0("- candidate valid rows before case selection: ", nrow(ok)),
  paste0("- rows in selected case before pair matching: ", pair_counts[scenario == chosen$scenario & powertrain == chosen$powertrain & traffic_mode == chosen$traffic_mode, n_rows]),
  paste0("- rows after matched-pair enforcement: ", nrow(sel)),
  paste0("- matched pairs used: ", data.table::uniqueN(sel$pair_id)),
  "",
  "## Metric and Units",
  "- Graphic 1 metric: co2_per_1000kcal (kg CO2 / 1000 kcal delivered)",
  paste0("- Graphic 2 basis: ", metric_basis),
  "- Graphic 2 uses propulsion and TRU components normalized per 1000 kcal from run-level values",
  "",
  "## Pairing and Assumptions",
  "- Paired-comparison logic preserved using pair_id matching.",
  "- No cross-scenario/powertrain mixing inside the selected case.",
  "- For Graphic 2, direct CO2 propulsion/TRU split was not used when not cleanly populated; direct fuel/energy components were used per FU basis.",
  "- Packaging assumptions are representative logistics assumptions (retailer-informed/derived), not exact manufacturer-certified shipping specifications.",
  "- Packaging assumptions primarily affect cube utilization and truckload assignment; route energy/emissions physics are still driven by distance, speed/traffic, powertrain, and charging/refueling behavior.",
  "",
  "## Animation",
  paste0("- GIF created: ", if (gif_ok) "yes" else "no"),
  paste0("- MP4 created: ", if (mp4_ok) "yes" else "no"),
  "- Last frame PNG exported for static-slide fallback."
)
writeLines(notes, file.path(opt$outdir, "transport_graphics_README.md"))

cat("Wrote", file.path(opt$outdir, "transport_mc_distribution.png"), "\n")
cat("Wrote", file.path(opt$outdir, "transport_mc_distribution.svg"), "\n")
cat("Wrote", file.path(opt$outdir, "transport_mc_distribution_summary.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "transport_mc_filtered_runs.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "transport_burden_breakdown.png"), "\n")
cat("Wrote", file.path(opt$outdir, "transport_burden_breakdown.svg"), "\n")
cat("Wrote", file.path(opt$outdir, "transport_burden_breakdown_values.csv"), "\n")
if (file.exists(mp4_path)) cat("Wrote", mp4_path, "\n")
if (file.exists(gif_path)) cat("Wrote", gif_path, "\n")
cat("Wrote", file.path(opt$outdir, "transport_mc_animation_last_frame.png"), "\n")
cat("Wrote", file.path(opt$outdir, "transport_graphics_filter_metadata.json"), "\n")
cat("Wrote", file.path(opt$outdir, "transport_graphics_README.md"), "\n")
