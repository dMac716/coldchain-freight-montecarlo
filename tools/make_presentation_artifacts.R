#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

quantile_triplet <- function(x) {
  x <- as.numeric(x)
  data.frame(
    p05 = as.numeric(stats::quantile(x, 0.05, na.rm = TRUE, names = FALSE)),
    p50 = as.numeric(stats::quantile(x, 0.50, na.rm = TRUE, names = FALSE)),
    p95 = as.numeric(stats::quantile(x, 0.95, na.rm = TRUE, names = FALSE)),
    stringsAsFactors = FALSE
  )
}

safe_read_csv <- function(path) {
  if (!file.exists(path) || !isTRUE(file.info(path)$size > 0)) return(data.frame())
  tryCatch(utils::read.csv(path, stringsAsFactors = FALSE), error = function(e) data.frame())
}

read_track <- function(path_gz) {
  if (!file.exists(path_gz) || !isTRUE(file.info(path_gz)$size > 0)) return(data.frame())
  con <- gzfile(path_gz, open = "rt")
  on.exit(close(con), add = TRUE)
  tryCatch(utils::read.csv(con, stringsAsFactors = FALSE), error = function(e) data.frame())
}

plot_metric_by_scenario <- function(df, metric_col, ylab, out_png) {
  d <- df[is.finite(df[[metric_col]]), c("scenario", metric_col), drop = FALSE]
  if (nrow(d) == 0) return(data.frame())
  split_d <- split(d[[metric_col]], d$scenario)
  rows <- lapply(names(split_d), function(s) {
    q <- quantile_triplet(split_d[[s]])
    data.frame(scenario = s, metric = metric_col, p05 = q$p05, p50 = q$p50, p95 = q$p95, stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  ord <- order(out$p50, decreasing = TRUE, na.last = TRUE)
  out <- out[ord, , drop = FALSE]

  grDevices::png(out_png, width = 1400, height = 900, res = 150)
  on.exit(grDevices::dev.off(), add = TRUE)
  par(mar = c(10, 6, 3, 1))
  xx <- seq_len(nrow(out))
  plot(xx, out$p50, pch = 19, col = "#0b3c5d", ylim = range(c(out$p05, out$p95), na.rm = TRUE), xaxt = "n", xlab = "", ylab = ylab)
  segments(xx, out$p05, xx, out$p95, col = "#328cc1", lwd = 2)
  axis(1, at = xx, labels = out$scenario, las = 2, cex.axis = 0.8)
  grid(col = "#dddddd")
  out
}

normalize_util_pct <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  ifelse(is.finite(x) & x > 1.5, x / 100, x)
}

option_list <- list(
  make_option(c("--bundle_dir"), type = "character", default = "outputs/run_bundle"),
  make_option(c("--bundle_glob"), type = "character", default = ""),
  make_option(c("--outdir"), type = "character", default = "outputs/presentation"),
  make_option(c("--config_path"), type = "character", default = "test_kit.yaml")
)
opt <- parse_args(OptionParser(option_list = option_list))

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

bundle_dirs <- if (nzchar(opt$bundle_glob)) {
  Sys.glob(opt$bundle_glob)
} else {
  list.dirs(opt$bundle_dir, full.names = TRUE, recursive = FALSE)
}
bundle_dirs <- bundle_dirs[file.exists(file.path(bundle_dirs, "summaries.csv"))]
if (length(bundle_dirs) == 0) stop("No run bundles with summaries.csv found")

rows <- list()
params_rows <- list()
for (bd in bundle_dirs) {
  sm <- safe_read_csv(file.path(bd, "summaries.csv"))
  if (nrow(sm) == 0) next
  pm <- if (file.exists(file.path(bd, "params.json"))) {
    tryCatch(jsonlite::fromJSON(file.path(bd, "params.json"), simplifyVector = TRUE), error = function(e) list())
  } else {
    list()
  }
  sm$bundle_dir <- bd
  sm$powertrain <- as.character(pm$powertrain %||% NA_character_)
  sm$facility_id <- as.character(pm$facility_id %||% NA_character_)
  sm$seed <- as.integer(pm$seed %||% NA_integer_)
  sm$retail_id <- if ("retail_id" %in% names(sm)) as.character(sm$retail_id) else as.character(sm$route_id %||% NA_character_)
  sm$spatial <- if ("spatial" %in% names(sm)) as.character(sm$spatial) else as.character(sm$origin_network %||% NA_character_)
  rows[[length(rows) + 1L]] <- sm
  params_rows[[length(params_rows) + 1L]] <- data.frame(
    bundle_dir = bd,
    has_config = as.integer(!is.null(pm$config)),
    stringsAsFactors = FALSE
  )
}
if (length(rows) == 0) stop("No non-empty summaries.csv found in bundle set")

run_df <- do.call(rbind, rows)
utils::write.csv(run_df, file.path(opt$outdir, "run_level_presentation.csv"), row.names = FALSE)

metrics <- list(
  co2_per_1000kcal = "kg CO2 per 1000 kcal",
  co2_per_kg_protein = "kg CO2 per kg protein",
  delivery_time_min = "Delivery Time (min)",
  trucker_hours_per_1000kcal = "Trucker Hours per 1000 kcal"
)
metric_tables <- list()
for (m in names(metrics)) {
  tbl <- plot_metric_by_scenario(run_df, m, metrics[[m]], file.path(opt$outdir, paste0(m, "_by_scenario.png")))
  if (nrow(tbl) > 0) {
    utils::write.csv(tbl, file.path(opt$outdir, paste0(m, "_by_scenario.csv")), row.names = FALSE)
    metric_tables[[m]] <- tbl
  }
}

key_scenarios <- sort(unique(as.character(run_df$scenario)))
key_rows <- lapply(key_scenarios, function(sc) {
  d <- run_df[as.character(run_df$scenario) == sc, , drop = FALSE]
  data.frame(
    scenario = sc,
    median_co2_per_1000kcal = as.numeric(stats::quantile(d$co2_per_1000kcal, 0.50, na.rm = TRUE, names = FALSE)),
    median_co2_per_kg_protein = as.numeric(stats::quantile(d$co2_per_kg_protein, 0.50, na.rm = TRUE, names = FALSE)),
    median_delivery_time_min = as.numeric(stats::quantile(d$delivery_time_min, 0.50, na.rm = TRUE, names = FALSE)),
    median_trucker_hours_per_1000kcal = as.numeric(stats::quantile(d$trucker_hours_per_1000kcal, 0.50, na.rm = TRUE, names = FALSE)),
    median_truckloads_per_1e6_kcal = as.numeric(stats::quantile(d$truckloads_per_1e6_kcal, 0.50, na.rm = TRUE, names = FALSE)),
    median_truckloads_per_1000kg_product = as.numeric(stats::quantile(d$truckloads_per_1000kg_product, 0.50, na.rm = TRUE, names = FALSE)),
    stringsAsFactors = FALSE
  )
})
key_numbers <- do.call(rbind, key_rows)
utils::write.csv(key_numbers, file.path(opt$outdir, "key_numbers.csv"), row.names = FALSE)

# GSI by product_type/powertrain/spatial/retail_id
req <- c("pair_id", "origin_network", "co2_per_kg_protein", "product_type", "powertrain", "spatial", "retail_id")
gsi_tbl <- data.frame(
  product_type = character(),
  powertrain = character(),
  spatial = character(),
  retail_id = character(),
  GSI_kgco2 = numeric(),
  gsi_p05 = numeric(),
  gsi_p95 = numeric(),
  p_gsi_gt_0 = numeric(),
  stringsAsFactors = FALSE
)
if (all(req %in% names(run_df))) {
  dd <- run_df[is.finite(run_df$co2_per_kg_protein), req, drop = FALSE]
  keys <- split(dd, list(dd$pair_id, dd$product_type, dd$powertrain, dd$spatial, dd$retail_id), drop = TRUE)
  pair_rows <- lapply(keys, function(x) {
    a <- x$co2_per_kg_protein[tolower(x$origin_network) == "refrigerated_factory_set"]
    b <- x$co2_per_kg_protein[tolower(x$origin_network) == "dry_factory_set"]
    if (length(a) == 0 || length(b) == 0) return(NULL)
    data.frame(
      product_type = as.character(x$product_type[[1]]),
      powertrain = as.character(x$powertrain[[1]]),
      spatial = as.character(x$spatial[[1]]),
      retail_id = as.character(x$retail_id[[1]]),
      gsi_delta = as.numeric(stats::median(a, na.rm = TRUE) - stats::median(b, na.rm = TRUE)),
      stringsAsFactors = FALSE
    )
  })
  pair_rows <- Filter(Negate(is.null), pair_rows)
  if (length(pair_rows) > 0) {
    gsi_pairs <- do.call(rbind, pair_rows)
    groups <- split(gsi_pairs, list(gsi_pairs$product_type, gsi_pairs$powertrain, gsi_pairs$spatial, gsi_pairs$retail_id), drop = TRUE)
    gsi_tbl <- do.call(rbind, lapply(groups, function(g) {
      x <- as.numeric(g$gsi_delta)
      data.frame(
        product_type = as.character(g$product_type[[1]]),
        powertrain = as.character(g$powertrain[[1]]),
        spatial = as.character(g$spatial[[1]]),
        retail_id = as.character(g$retail_id[[1]]),
        GSI_kgco2 = as.numeric(stats::quantile(x, 0.50, na.rm = TRUE, names = FALSE)),
        gsi_p05 = as.numeric(stats::quantile(x, 0.05, na.rm = TRUE, names = FALSE)),
        gsi_p95 = as.numeric(stats::quantile(x, 0.95, na.rm = TRUE, names = FALSE)),
        p_gsi_gt_0 = mean(x > 0, na.rm = TRUE),
        stringsAsFactors = FALSE
      )
    }))
    if (nrow(gsi_tbl) > 0) {
      grDevices::png(file.path(opt$outdir, "gsi_kgco2.png"), width = 1400, height = 900, res = 150)
      par(mar = c(10, 6, 3, 1))
      lbl <- paste(gsi_tbl$product_type, gsi_tbl$powertrain, gsi_tbl$spatial, gsi_tbl$retail_id, sep = " | ")
      xx <- seq_len(nrow(gsi_tbl))
      plot(xx, gsi_tbl$GSI_kgco2, pch = 19, col = "#b22222", ylim = range(c(gsi_tbl$gsi_p05, gsi_tbl$gsi_p95), na.rm = TRUE), xaxt = "n", xlab = "", ylab = "GSI (kg CO2 per kg protein)")
      segments(xx, gsi_tbl$gsi_p05, xx, gsi_tbl$gsi_p95, col = "#ef8a62", lwd = 2)
      axis(1, at = xx, labels = lbl, las = 2, cex.axis = 0.6)
      abline(h = 0, lty = 2, col = "gray40")
      grid(col = "#dddddd")
      grDevices::dev.off()
    }
  }
}
utils::write.csv(gsi_tbl, file.path(opt$outdir, "gsi_by_product_powertrain_spatial_retail.csv"), row.names = FALSE)

# Stop-time breakdown: BEV vs diesel
stop_components <- c("driver_driving_min", "time_charging_min", "time_refuel_min", "driver_off_duty_min", "time_load_unload_min", "time_traffic_delay_min")
if (all(c("powertrain", stop_components) %in% names(run_df))) {
  d <- run_df[, c("scenario", "powertrain", stop_components), drop = FALSE]
  d$powertrain <- tolower(as.character(d$powertrain))
  d <- d[d$powertrain %in% c("bev", "diesel"), , drop = FALSE]
  if (nrow(d) > 0) {
    keys <- split(d, list(d$scenario, d$powertrain), drop = TRUE)
    stack_rows <- lapply(keys, function(x) {
      data.frame(
        scenario = as.character(x$scenario[[1]]),
        powertrain = as.character(x$powertrain[[1]]),
        driving = as.numeric(stats::quantile(x$driver_driving_min, 0.50, na.rm = TRUE, names = FALSE)),
        charging_refuel = as.numeric(stats::quantile(x$time_charging_min + x$time_refuel_min, 0.50, na.rm = TRUE, names = FALSE)),
        rest = as.numeric(stats::quantile(x$driver_off_duty_min, 0.50, na.rm = TRUE, names = FALSE)),
        load_unload = as.numeric(stats::quantile(x$time_load_unload_min, 0.50, na.rm = TRUE, names = FALSE)),
        traffic_delay = as.numeric(stats::quantile(x$time_traffic_delay_min, 0.50, na.rm = TRUE, names = FALSE)),
        stringsAsFactors = FALSE
      )
    })
    stop_tbl <- do.call(rbind, stack_rows)
    utils::write.csv(stop_tbl, file.path(opt$outdir, "stop_time_breakdown_bev_vs_diesel.csv"), row.names = FALSE)

    grDevices::png(file.path(opt$outdir, "stop_time_breakdown_bev_vs_diesel.png"), width = 1500, height = 900, res = 150)
    mat <- rbind(stop_tbl$driving, stop_tbl$charging_refuel, stop_tbl$rest, stop_tbl$load_unload, stop_tbl$traffic_delay)
    colnames(mat) <- paste(stop_tbl$scenario, stop_tbl$powertrain, sep = " | ")
    barplot(mat,
      beside = FALSE,
      col = c("#1f78b4", "#33a02c", "#ff7f00", "#6a3d9a", "#b15928"),
      ylab = "Median Minutes",
      las = 2
    )
    legend("topright", legend = c("driving", "charging/refuel", "rest", "load-unload", "traffic delay"),
      fill = c("#1f78b4", "#33a02c", "#ff7f00", "#6a3d9a", "#b15928"), cex = 0.8)
    grDevices::dev.off()
  }
}

# Load diagnostics scatter
if (all(c("cube_utilization_pct", "payload_utilization_pct", "limiting_constraint") %in% names(run_df))) {
  lu <- run_df[, c("cube_utilization_pct", "payload_utilization_pct", "limiting_constraint", "scenario", "run_id"), drop = FALSE]
  lu$cube_utilization_frac <- normalize_util_pct(lu$cube_utilization_pct)
  lu$payload_utilization_frac <- normalize_util_pct(lu$payload_utilization_pct)
  lu <- lu[is.finite(lu$cube_utilization_frac) & is.finite(lu$payload_utilization_frac), , drop = FALSE]
  utils::write.csv(lu, file.path(opt$outdir, "load_diagnostics_scatter.csv"), row.names = FALSE)

  if (nrow(lu) > 0) {
    cols <- ifelse(tolower(as.character(lu$limiting_constraint)) == "cube", "#d7301f", "#1a9850")
    grDevices::png(file.path(opt$outdir, "load_diagnostics_scatter.png"), width = 1400, height = 900, res = 150)
    plot(lu$cube_utilization_frac, lu$payload_utilization_frac,
      pch = 19,
      col = cols,
      xlab = "Cube utilization (fraction)",
      ylab = "Payload utilization (fraction)",
      xlim = c(0, max(1.1, max(lu$cube_utilization_frac, na.rm = TRUE))),
      ylim = c(0, max(1.1, max(lu$payload_utilization_frac, na.rm = TRUE)))
    )
    abline(v = 1, lty = 2, col = "gray40")
    abline(h = 1, lty = 2, col = "gray40")
    legend("bottomright", legend = c("cube-limited", "weight-limited"), col = c("#d7301f", "#1a9850"), pch = 19)
    grid(col = "#dddddd")
    grDevices::dev.off()
  }
}

# Assumptions snapshot
assumptions <- list()
first_params <- NULL
for (bd in bundle_dirs) {
  p <- file.path(bd, "params.json")
  if (!file.exists(p)) next
  pj <- tryCatch(jsonlite::fromJSON(p, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.null(pj$config)) {
    first_params <- pj$config
    break
  }
}
if (!is.null(first_params)) {
  assumptions <- list(
    load_model = first_params$load_model,
    driver_time = first_params$driver_time,
    hos = first_params$hos
  )
} else if (file.exists(opt$config_path)) {
  if (!requireNamespace("yaml", quietly = TRUE)) stop("yaml package required to write assumptions_used.yaml")
  y <- yaml::read_yaml(opt$config_path)
  root <- y$test_kit %||% y
  assumptions <- list(
    load_model = root$load_model,
    driver_time = root$driver_time,
    hos = root$hos
  )
}
if (!requireNamespace("yaml", quietly = TRUE)) stop("yaml package required to write assumptions_used.yaml")
yaml::write_yaml(assumptions, file.path(opt$outdir, "assumptions_used.yaml"))

# One-page markdown summary
md_path <- file.path(opt$outdir, "presentation_snapshot.md")
lines <- c(
  "# Presentation Snapshot",
  "",
  sprintf("Generated UTC: %s", format(Sys.time(), tz = "UTC", usetz = TRUE)),
  sprintf("Runs included: %d", nrow(run_df)),
  "",
  "## Key Metrics by Scenario (p05 / p50 / p95)",
  ""
)
for (m in names(metric_tables)) {
  tab <- metric_tables[[m]]
  lines <- c(lines, sprintf("### %s", m))
  for (i in seq_len(nrow(tab))) {
    lines <- c(lines, sprintf("- %s: %.3f / %.3f / %.3f", tab$scenario[[i]], tab$p05[[i]], tab$p50[[i]], tab$p95[[i]]))
  }
  lines <- c(lines, "")
}
if (nrow(key_numbers) > 0) {
  lines <- c(lines, "## Scenario Medians", "")
  for (i in seq_len(nrow(key_numbers))) {
    lines <- c(lines,
      sprintf(
        "- %s: co2/1000kcal=%.3f, co2/kg_protein=%.3f, delivery_min=%.1f, trucker_h/1000kcal=%.4f",
        key_numbers$scenario[[i]],
        key_numbers$median_co2_per_1000kcal[[i]],
        key_numbers$median_co2_per_kg_protein[[i]],
        key_numbers$median_delivery_time_min[[i]],
        key_numbers$median_trucker_hours_per_1000kcal[[i]]
      )
    )
  }
}
writeLines(lines, md_path)

cat("Wrote", opt$outdir, "\n")
