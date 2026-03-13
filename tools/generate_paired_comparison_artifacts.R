#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--bundle_root"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--outdir"), type = "character", default = "outputs/analysis/paired_comparison"),
  make_option(c("--recursive"), type = "character", default = "true"),
  make_option(c("--allow_noncanonical"), type = "character", default = "false")
)))

`%||%` <- function(x, y) if (is.null(x)) y else x
to_bool <- function(x) tolower(trimws(as.character(x %||% "true"))) %in% c("1", "true", "yes", "y")

bundle_root <- normalizePath(opt$bundle_root, winslash = "/", mustWork = FALSE)
if (!dir.exists(bundle_root)) stop("bundle_root not found: ", bundle_root)
allow_noncanonical <- to_bool(opt$allow_noncanonical)
if (!allow_noncanonical && !grepl("/outputs/run_bundle/canonical/", gsub("\\\\", "/", bundle_root), fixed = TRUE)) {
  stop("bundle_root must be under outputs/run_bundle/canonical. Pass --allow_noncanonical=true to override.")
}
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

if (file.exists("R/log_helpers.R")) {
  source("R/log_helpers.R")
  configure_log(tag = "generate_paired")
} else if (!exists("log_event")) {
  log_event <- function(level = "INFO", phase = "unknown", msg = "") {
    cat(paste0(level, ": ", msg, "\n"))
    invisible(paste0(level, ": ", msg))
  }
}

log_lines <- character()
log_msg <- function(level, msg) {
  entry <- log_event(level, "analysis", msg)
  log_lines <<- c(log_lines, entry)
}

pick_first_finite_metric <- function(dt, candidates, out_name) {
  for (nm in candidates) {
    if (nm %in% names(dt) && any(is.finite(dt[[nm]]))) {
      return(nm)
    }
  }
  stop("No finite metric available for ", out_name, ". Tried: ", paste(candidates, collapse = ", "))
}

label_product <- function(x) {
  v <- tolower(trimws(as.character(x)))
  ifelse(v == "dry", "Dry", ifelse(v == "refrigerated", "Refrigerated", x))
}
label_origin <- function(x) {
  v <- tolower(trimws(as.character(x)))
  ifelse(v == "dry_factory_set", "Dry factory set",
         ifelse(v == "refrigerated_factory_set", "Refrigerated factory set", x))
}
label_powertrain <- function(x) {
  v <- tolower(trimws(as.character(x)))
  ifelse(v == "bev", "BEV", ifelse(v == "diesel", "Diesel", x))
}
label_traffic <- function(x) {
  v <- tolower(trimws(as.character(x)))
  ifelse(v == "freeflow", "Freeflow", ifelse(v == "stochastic", "Stochastic", x))
}

pair_dirs <- list.dirs(bundle_root, recursive = to_bool(opt$recursive), full.names = TRUE)
pair_dirs <- sort(unique(pair_dirs[grepl("/pair_[^/]+$", pair_dirs)]))
if (length(pair_dirs) == 0L) stop("No pair_* directories found under ", bundle_root)

summ_paths <- file.path(pair_dirs, "summaries.csv")
summ_paths <- summ_paths[file.exists(summ_paths)]
if (length(summ_paths) == 0L) stop("No summaries.csv files found under pair_* directories in ", bundle_root)

d <- data.table::rbindlist(lapply(summ_paths, function(p) {
  x <- data.table::fread(p, showProgress = FALSE)
  x[, pair_bundle_dir := basename(dirname(p))]
  x
}), fill = TRUE, use.names = TRUE)

need_cols <- c(
  "pair_id", "scenario", "product_type", "origin_network", "powertrain", "traffic_mode", "artifact_mode", "status",
  "co2_per_1000kcal", "co2_per_kg_protein", "transport_cost_per_1000kcal",
  "trucker_hours_per_1000kcal", "delivery_time_min", "cube_utilization_pct",
  "charge_stops", "refuel_stops", "delay_minutes", "distance_miles",
  "time_charging_min", "energy_kwh_propulsion", "kcal_delivered", "driver_on_duty_min"
)
for (cn in need_cols) if (!cn %in% names(d)) d[, (cn) := NA]

chr_cols <- c("pair_id", "scenario", "product_type", "origin_network", "powertrain", "traffic_mode", "artifact_mode", "status")
for (cn in chr_cols) d[, (cn) := as.character(get(cn))]
num_cols <- setdiff(need_cols, chr_cols)
for (cn in num_cols) d[, (cn) := suppressWarnings(as.numeric(get(cn)))]

ok <- d[is.na(status) | tolower(trimws(status)) %in% c("", "ok")]
if (nrow(ok) == 0L) stop("No OK rows in paired summaries.")

# trucker_hours fallback + diagnostics
finite_trucker_before <- sum(is.finite(ok$trucker_hours_per_1000kcal))
missing_th <- !is.finite(ok$trucker_hours_per_1000kcal)
can_fill <- missing_th & is.finite(ok$driver_on_duty_min) & is.finite(ok$kcal_delivered) & ok$kcal_delivered > 0
if (any(can_fill)) {
  ok[can_fill, trucker_hours_per_1000kcal := (driver_on_duty_min / 60) / (kcal_delivered / 1000)]
}
finite_trucker_after <- sum(is.finite(ok$trucker_hours_per_1000kcal))
log_msg("INFO", paste0("trucker_hours finite count: before=", finite_trucker_before, " after=", finite_trucker_after))
if (!any(is.finite(ok$trucker_hours_per_1000kcal)) && any(is.finite(ok$driver_on_duty_min))) {
  ok[, trucker_hours_trip := driver_on_duty_min / 60]
  log_msg("WARN", "trucker_hours_per_1000kcal unavailable; using trip-level driver_on_duty_min/60 fallback for figure C2.")
} else {
  ok[, trucker_hours_trip := NA_real_]
}

if (!any(is.finite(ok$co2_per_1000kcal)) && any(is.finite(ok$co2_kg_total))) {
  ok[, co2_per_1000kcal := co2_kg_total]
  log_msg("WARN", "co2_per_1000kcal unavailable; using co2_kg_total fallback (per-trip proxy) for figure A and core table.")
}
if (!any(is.finite(ok$co2_per_kg_protein)) && all(c("co2_kg_total", "protein_kg_delivered") %in% names(ok))) {
  fill_idx <- !is.finite(ok$co2_per_kg_protein) & is.finite(ok$co2_kg_total) & is.finite(ok$protein_kg_delivered) & ok$protein_kg_delivered > 0
  if (any(fill_idx)) {
    ok[fill_idx, co2_per_kg_protein := co2_kg_total / protein_kg_delivered]
    log_msg("WARN", "Filled co2_per_kg_protein from co2_kg_total/protein_kg_delivered where available.")
  }
}

group_cols <- c("product_type", "origin_network", "powertrain", "traffic_mode")
metric_cols <- c(
  "co2_per_1000kcal", "co2_per_kg_protein", "transport_cost_per_1000kcal",
  "trucker_hours_per_1000kcal", "delivery_time_min", "cube_utilization_pct",
  "charge_stops", "refuel_stops", "delay_minutes"
)
core_tbl <- ok[, c(
  list(n_rows = .N, n_pairs = data.table::uniqueN(pair_id)),
  lapply(.SD, function(v) if (all(!is.finite(v))) NA_real_ else as.numeric(mean(v, na.rm = TRUE)))
), by = group_cols, .SDcols = metric_cols]
core_tbl[, product_type := label_product(product_type)]
core_tbl[, origin_network := label_origin(origin_network)]
core_tbl[, powertrain := label_powertrain(powertrain)]
core_tbl[, traffic_mode := label_traffic(traffic_mode)]
data.table::setorder(core_tbl, product_type, origin_network, powertrain, traffic_mode)
core_csv <- file.path(opt$outdir, "paired_core_comparison_table.csv")
data.table::fwrite(core_tbl, core_csv)

build_subtitle <- function(dt) {
  n_pairs <- data.table::uniqueN(dt$pair_id)
  modes <- unique(dt$artifact_mode)
  modes <- modes[!is.na(modes) & nzchar(modes)]
  mode_txt <- if (length(modes) > 0) paste(sort(unique(modes)), collapse = ",") else "unknown"
  paste0("n pairs=", n_pairs, " | bundle_root=", bundle_root, " | artifact_mode=", mode_txt)
}

plot_box_metric <- function(dt, ycol, x_expr, x_label_fun, title, ylab, file_stub, required = TRUE) {
  dx <- dt[is.finite(get(ycol))]
  if (nrow(dx) == 0L) {
    msg <- paste0(file_stub, " has zero finite rows for metric ", ycol)
    if (required) stop(msg)
    log_msg("WARN", msg)
    return(invisible(FALSE))
  }
  dx[, plot_group := eval(x_expr)]
  dx <- dx[!is.na(plot_group) & nzchar(plot_group)]
  if (nrow(dx) == 0L) {
    msg <- paste0(file_stub, " has zero rows after grouping filter for metric ", ycol)
    if (required) stop(msg)
    log_msg("WARN", msg)
    return(invisible(FALSE))
  }
  dx[, plot_group := x_label_fun(plot_group)]
  subt <- build_subtitle(dx)
  png(file.path(opt$outdir, paste0(file_stub, ".png")), width = 1920, height = 1080, res = 150)
  par(mar = c(10, 7, 6, 2) + 0.1, cex.axis = 1.1, cex.lab = 1.2, cex.main = 1.4, cex.sub = 0.95)
  boxplot(dx[[ycol]] ~ dx$plot_group, las = 2, ylab = ylab, xlab = "", main = title, sub = subt,
          col = "#d9e8ff", border = "#1f5fbf")
  stripchart(dx[[ycol]] ~ dx$plot_group, method = "jitter", add = TRUE, pch = 16, cex = 0.6,
             col = grDevices::adjustcolor("#2F80ED", alpha.f = 0.35), vertical = TRUE)
  dev.off()
  grDevices::svg(file.path(opt$outdir, paste0(file_stub, ".svg")), width = 13.5, height = 7.5)
  par(mar = c(10, 7, 6, 2) + 0.1, cex.axis = 1.1, cex.lab = 1.2, cex.main = 1.4, cex.sub = 0.95)
  boxplot(dx[[ycol]] ~ dx$plot_group, las = 2, ylab = ylab, xlab = "", main = title, sub = subt,
          col = "#d9e8ff", border = "#1f5fbf")
  stripchart(dx[[ycol]] ~ dx$plot_group, method = "jitter", add = TRUE, pch = 16, cex = 0.6,
             col = grDevices::adjustcolor("#2F80ED", alpha.f = 0.35), vertical = TRUE)
  dev.off()
  invisible(TRUE)
}

# A) Transport emissions comparison
plot_box_metric(
  ok,
  ycol = "co2_per_1000kcal",
  x_expr = quote(paste(label_product(product_type), label_powertrain(powertrain), sep = " / ")),
  x_label_fun = identity,
  title = "Transport Emissions by Product and Powertrain",
  ylab = if (any(is.finite(d$co2_per_1000kcal))) "kg CO2 per 1000 kcal delivered" else "kg CO2 per trip (proxy)",
  file_stub = "fig_a_transport_emissions_comparison",
  required = TRUE
)

# B) Protein efficiency comparison (optional if protein basis unavailable)
plot_box_metric(
  ok,
  ycol = "co2_per_kg_protein",
  x_expr = quote(paste(label_product(product_type), label_powertrain(powertrain), sep = " / ")),
  x_label_fun = identity,
  title = "Protein Efficiency by Product and Powertrain",
  ylab = "kg CO2 per kg protein delivered",
  file_stub = "fig_b_protein_efficiency_comparison",
  required = FALSE
)

# C1) Delivery Time by Scenario
plot_box_metric(
  ok,
  ycol = "delivery_time_min",
  x_expr = quote(ifelse(is.na(scenario) | !nzchar(trimws(scenario)), label_traffic(traffic_mode), scenario)),
  x_label_fun = identity,
  title = "Delivery Time by Scenario",
  ylab = "Delivery time (minutes)",
  file_stub = "fig_c1_delivery_time_by_scenario",
  required = TRUE
)

# C2) Trucker Hours by Product and Origin
plot_box_metric(
  ok,
  ycol = "trucker_hours_per_1000kcal",
  x_expr = quote(paste(label_product(product_type), label_origin(origin_network), sep = " / ")),
  x_label_fun = identity,
  title = "Trucker Hours per 1000 kcal by Product and Origin",
  ylab = "Trucker hours per 1000 kcal",
  file_stub = "fig_c2_trucker_hours_by_product_origin",
  required = FALSE
)

if (!file.exists(file.path(opt$outdir, "fig_c2_trucker_hours_by_product_origin.png"))) {
  plot_box_metric(
    ok,
    ycol = "trucker_hours_trip",
    x_expr = quote(paste(label_product(product_type), label_origin(origin_network), sep = " / ")),
    x_label_fun = identity,
    title = "Trucker Hours (Trip-level) by Product and Origin",
    ylab = "Trucker hours per trip (driver_on_duty_min/60)",
    file_stub = "fig_c2_trucker_hours_by_product_origin",
    required = TRUE
  )
}

# D) Geography Sensitivity Index (skip cleanly if unavailable)
gsi_src <- ok[origin_network %in% c("dry_factory_set", "refrigerated_factory_set")]
if (nrow(gsi_src) == 0L) {
  log_msg("WARN", "GSI source rows are empty; skipping GSI figure.")
} else {
  gsi_pair <- data.table::dcast(
    gsi_src,
    pair_id + product_type + powertrain + traffic_mode ~ origin_network,
    value.var = c("co2_per_1000kcal", "distance_miles", "delivery_time_min"),
    fun.aggregate = mean
  )
  need_wide <- c(
    "co2_per_1000kcal_dry_factory_set", "co2_per_1000kcal_refrigerated_factory_set",
    "distance_miles_dry_factory_set", "distance_miles_refrigerated_factory_set",
    "delivery_time_min_dry_factory_set", "delivery_time_min_refrigerated_factory_set"
  )
  if (!all(need_wide %in% names(gsi_pair))) {
    log_msg("WARN", "GSI required columns missing after reshape; skipping GSI figure.")
  } else {
    gsi_pair[, gsi_kgco2 := co2_per_1000kcal_refrigerated_factory_set - co2_per_1000kcal_dry_factory_set]
    gsi_pair[, gsi_miles := distance_miles_refrigerated_factory_set - distance_miles_dry_factory_set]
    gsi_pair[, gsi_minutes := delivery_time_min_refrigerated_factory_set - delivery_time_min_dry_factory_set]
    gsi_summ <- gsi_pair[, .(
      gsi_kgco2_p05 = as.numeric(stats::quantile(gsi_kgco2, 0.05, na.rm = TRUE, names = FALSE)),
      gsi_kgco2_p50 = as.numeric(stats::quantile(gsi_kgco2, 0.50, na.rm = TRUE, names = FALSE)),
      gsi_kgco2_p95 = as.numeric(stats::quantile(gsi_kgco2, 0.95, na.rm = TRUE, names = FALSE)),
      gsi_miles_p50 = as.numeric(stats::quantile(gsi_miles, 0.50, na.rm = TRUE, names = FALSE)),
      gsi_minutes_p50 = as.numeric(stats::quantile(gsi_minutes, 0.50, na.rm = TRUE, names = FALSE)),
      n_pairs = .N
    ), by = .(product_type, powertrain, traffic_mode)]
    data.table::fwrite(gsi_summ, file.path(opt$outdir, "fig_d_gsi_summary.csv"))
    gsi_plot <- gsi_summ[is.finite(gsi_kgco2_p05) & is.finite(gsi_kgco2_p50) & is.finite(gsi_kgco2_p95)]
    if (nrow(gsi_plot) == 0L) {
      log_msg("WARN", "GSI summary contains no finite kgCO2 quantiles; skipping GSI figure.")
    } else {
      gsi_plot[, label := paste(label_product(product_type), label_powertrain(powertrain), sep = " / ")]
      yl <- range(c(gsi_plot$gsi_kgco2_p05, gsi_plot$gsi_kgco2_p95), na.rm = TRUE)
      if (!all(is.finite(yl))) {
        log_msg("WARN", "GSI y-limits are non-finite; skipping GSI figure.")
      } else {
        png(file.path(opt$outdir, "fig_d_gsi_kgco2.png"), width = 1920, height = 1080, res = 150)
        par(mar = c(10, 7, 6, 2) + 0.1, cex.axis = 1.1, cex.lab = 1.2, cex.main = 1.4, cex.sub = 0.95)
        plot(seq_len(nrow(gsi_plot)), gsi_plot$gsi_kgco2_p50, pch = 16, ylim = yl,
             xaxt = "n", xlab = "", ylab = "GSI (kg CO2 per 1000 kcal)",
             main = "GSI (kgCO2) by Product and Powertrain",
             sub = paste0("n groups=", nrow(gsi_plot), " | ", build_subtitle(ok)))
        axis(1, at = seq_len(nrow(gsi_plot)), labels = gsi_plot$label, las = 2)
        segments(seq_len(nrow(gsi_plot)), gsi_plot$gsi_kgco2_p05, seq_len(nrow(gsi_plot)), gsi_plot$gsi_kgco2_p95, lwd = 3, col = "#2F80ED")
        abline(h = 0, lty = 2, col = "#666666")
        dev.off()
      }
    }
  }
}

# E) BEV outlier diagnostic
bev <- ok[tolower(powertrain) == "bev"]
if (nrow(bev) == 0L) {
  log_msg("WARN", "No BEV rows found; skipping BEV outlier diagnostic figure.")
} else {
  if ("charger_levels_used" %in% names(bev)) {
    bev[, charger_regime := as.character(charger_levels_used)]
  } else if ("connector_types_used" %in% names(bev)) {
    bev[, charger_regime := as.character(connector_types_used)]
  } else {
    bev[, charger_regime := "unknown"]
  }
  bev[is.na(charger_regime) | !nzchar(charger_regime), charger_regime := "unknown"]
  bev[, charger_regime := ifelse(grepl("L2|level2", charger_regime, ignore.case = TRUE), "L2",
                                 ifelse(grepl("DCFC|L3|fast|level3", charger_regime, ignore.case = TRUE), "L3/DCFC", "mixed/unknown"))]
  cols <- c("L2" = "#2F80ED", "L3/DCFC" = "#EB5757", "mixed/unknown" = "#666666")
  metrics <- c("energy_kwh_propulsion", "charge_stops", "time_charging_min")
  usable <- metrics[vapply(metrics, function(m) any(is.finite(bev[[m]]) & is.finite(bev$co2_per_1000kcal)), logical(1))]
  if (length(usable) == 0L) {
    log_msg("WARN", "No finite BEV diagnostic metric pairs found; skipping BEV outlier figure.")
  } else {
    png(file.path(opt$outdir, "fig_e_bev_outlier_diagnostic.png"), width = 1920, height = 1080, res = 150)
    par(mfrow = c(1, length(usable)), mar = c(6, 6, 6, 2) + 0.1, cex.axis = 1.0, cex.lab = 1.15, cex.main = 1.2)
    for (metric in usable) {
      keep <- is.finite(bev$co2_per_1000kcal) & is.finite(bev[[metric]])
      g <- bev$charger_regime[keep]
      colv <- cols[g]; colv[is.na(colv)] <- cols[["mixed/unknown"]]
      plot(bev$co2_per_1000kcal[keep], bev[[metric]][keep], pch = 16, cex = 0.75,
           col = grDevices::adjustcolor(colv, alpha.f = 0.75),
           xlab = "kg CO2 per 1000 kcal", ylab = metric,
           main = paste0("BEV diagnostic: ", metric, "\n", build_subtitle(bev)))
    }
    dev.off()
  }
}

log_path <- file.path(opt$outdir, "figure_generation_log.txt")
writeLines(log_lines, con = log_path, useBytes = TRUE)

metric_meta <- data.table::data.table(
  figure = c("fig_a_transport_emissions_comparison", "fig_b_protein_efficiency_comparison", "fig_c2_trucker_hours_by_product_origin"),
  metric_basis = c(
    if (any(is.finite(d$co2_per_1000kcal))) "co2_per_1000kcal" else "co2_kg_total_proxy",
    if (file.exists(file.path(opt$outdir, "fig_b_protein_efficiency_comparison.png")) && any(is.finite(ok$co2_per_kg_protein))) "co2_per_kg_protein" else "unavailable",
    if (file.exists(file.path(opt$outdir, "fig_c2_trucker_hours_by_product_origin.png")) && any(is.finite(ok$trucker_hours_per_1000kcal))) "trucker_hours_per_1000kcal" else "driver_on_duty_min_over_60_proxy"
  )
)
data.table::fwrite(metric_meta, file.path(opt$outdir, "figure_metric_basis.csv"))
cat("Wrote paired comparison table:", core_csv, "\n")
cat("Wrote figures/log to:", normalizePath(opt$outdir, winslash = "/", mustWork = FALSE), "\n")
