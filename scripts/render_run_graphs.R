#!/usr/bin/env Rscript
# scripts/render_run_graphs.R
# Render standard diagnostic graphs for a completed simulation run.
#
# Usage:
#   Rscript scripts/render_run_graphs.R --run_dir runs/<run_id>
#
# Outputs (inside <run_dir>/graphs/):
#   emissions_by_scenario.png
#   emissions_distribution.png
#   cost_by_scenario.png
#   cost_distribution.png
#   scenario_comparison.png
#   summary_grid.png
#
# Also writes: <run_dir>/summary.json

suppressPackageStartupMessages({
  library(optparse)
  library(jsonlite)
  library(ggplot2)
})

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_msg <- function(level, run_id, msg, phase = "render", seed = NA) {
  entry <- sprintf(
    '[%s] [render_graphs] run_id="%s" lane="codespace" seed="%s" phase="%s" status="%s" msg="%s"',
    format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    run_id, ifelse(is.na(seed), "unknown", as.character(seed)),
    phase, level, msg
  )
  cat(entry, "\n")
  entry
}

write_log_entry <- function(log_file, entry) {
  cat(entry, "\n", file = log_file, append = TRUE)
}

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
option_list <- list(
  make_option("--run_dir",  type = "character", default = NULL,
              help = "Path to run directory (required)"),
  make_option("--force",    action = "store_true", default = FALSE,
              help = "Overwrite existing graphs"),
  make_option("--width",    type = "double",    default = 10,
              help = "Plot width in inches [default: %default]"),
  make_option("--height",   type = "double",    default = 6,
              help = "Plot height in inches [default: %default]"),
  make_option("--dpi",      type = "integer",   default = 150,
              help = "PNG resolution [default: %default]")
)
opts <- parse_args(OptionParser(option_list = option_list))

if (is.null(opts$run_dir)) {
  cat("ERROR: --run_dir is required.\n")
  quit(status = 1)
}

run_dir <- normalizePath(opts$run_dir, mustWork = FALSE)
run_id  <- basename(run_dir)

if (!dir.exists(run_dir)) {
  cat(sprintf("ERROR: run directory not found: %s\n", run_dir))
  quit(status = 1)
}

graphs_dir <- file.path(run_dir, "graphs")
log_file   <- file.path(run_dir, "run.log")

dir.create(graphs_dir, recursive = TRUE, showWarnings = FALSE)

log_entry <- log_msg("INFO", run_id, paste("Starting graph render for", run_dir))
write_log_entry(log_file, log_entry)

# ---------------------------------------------------------------------------
# Helper: resolve seed from manifest or summary
# ---------------------------------------------------------------------------
resolve_seed <- function(run_dir) {
  for (f in c("manifest.json", "summary.json")) {
    p <- file.path(run_dir, f)
    if (file.exists(p)) {
      tryCatch({
        m <- fromJSON(p)
        if (!is.null(m$seed)) return(as.character(m$seed))
      }, error = function(e) NULL)
    }
  }
  "unknown"
}

seed_val <- resolve_seed(run_dir)

# ---------------------------------------------------------------------------
# Helper: find simulation output CSVs
# ---------------------------------------------------------------------------
find_results_csv <- function(run_dir) {
  candidates <- c(
    file.path(run_dir, "results.csv"),
    file.path(run_dir, "summary.csv"),
    file.path(run_dir, "outputs", "results.csv"),
    file.path(run_dir, "outputs", "summary.csv")
  )
  found <- candidates[file.exists(candidates)]
  if (length(found) > 0) return(found[1])
  # fallback: glob any CSV
  csvs <- list.files(run_dir, pattern = "\\.csv$", recursive = TRUE,
                     full.names = TRUE)
  if (length(csvs) > 0) csvs[1] else NULL
}

# ---------------------------------------------------------------------------
# Graceful data loader — returns NULL with a warning on failure
# ---------------------------------------------------------------------------
load_results <- function(path) {
  if (is.null(path) || !file.exists(path)) return(NULL)
  tryCatch(
    utils::read.csv(path, stringsAsFactors = FALSE),
    error = function(e) {
      log_msg("WARN", run_id, paste("Could not read results:", conditionMessage(e)))
      NULL
    }
  )
}

# ---------------------------------------------------------------------------
# Placeholder chart when data is absent
# ---------------------------------------------------------------------------
placeholder_plot <- function(title, detail = "No data available for this run.") {
  ggplot(data.frame(x = 0.5, y = 0.5, label = detail), aes(x, y)) +
    annotate("text", x = 0.5, y = 0.5, label = detail,
             size = 5, colour = "grey50") +
    labs(title = title, x = NULL, y = NULL) +
    theme_minimal() +
    theme(axis.text = element_blank(), axis.ticks = element_blank(),
          panel.grid = element_blank())
}

# ---------------------------------------------------------------------------
# Save helper (idempotent unless --force)
# ---------------------------------------------------------------------------
save_plot <- function(p, filename, width = opts$width,
                      height = opts$height, dpi = opts$dpi) {
  path <- file.path(graphs_dir, filename)
  if (file.exists(path) && !opts$force) {
    log_msg("INFO", run_id,
            paste("Skipping (already exists, use --force to overwrite):", filename))
    return(path)
  }
  ggsave(path, plot = p, width = width, height = height, dpi = dpi,
         device = "png", bg = "white")
  log_entry <- log_msg("INFO", run_id,
                        paste("Rendered:", filename), seed = seed_val)
  write_log_entry(log_file, log_entry)
  path
}

# ---------------------------------------------------------------------------
# Load data once
# ---------------------------------------------------------------------------
results_path <- find_results_csv(run_dir)
df <- load_results(results_path)

has_data      <- !is.null(df) && nrow(df) > 0
has_scenario  <- has_data && "scenario" %in% names(df)
has_emissions <- has_data && any(c("emissions_kg_co2e", "co2_kg", "ghg_kg") %in% names(df))
has_cost      <- has_data && any(c("cost_usd", "total_cost", "cost") %in% names(df))

# Normalise column names to a common schema
if (has_data) {
  names(df) <- tolower(gsub("\\s+", "_", names(df)))
  if (!"scenario" %in% names(df) && nrow(df) > 0) df$scenario <- "default"
  emit_col <- intersect(c("emissions_kg_co2e", "co2_kg", "ghg_kg"), names(df))[1]
  cost_col  <- intersect(c("cost_usd", "total_cost", "cost"), names(df))[1]
}

rendered <- character(0)

# ---------------------------------------------------------------------------
# Graph 1: Emissions by scenario
# ---------------------------------------------------------------------------
if (has_scenario && has_emissions) {
  agg <- aggregate(df[[emit_col]] ~ df$scenario,
                   data = df, FUN = mean, na.rm = TRUE)
  names(agg) <- c("scenario", "mean_emissions")
  p1 <- ggplot(agg, aes(x = reorder(scenario, mean_emissions),
                         y = mean_emissions, fill = scenario)) +
    geom_col(show.legend = FALSE) +
    coord_flip() +
    labs(title = "Mean Emissions by Scenario",
         x = "Scenario", y = "kg CO\u2082e per unit") +
    theme_minimal()
} else {
  p1 <- placeholder_plot("Emissions by Scenario")
}
rendered <- c(rendered, save_plot(p1, "emissions_by_scenario.png"))

# ---------------------------------------------------------------------------
# Graph 2: Emissions distribution
# ---------------------------------------------------------------------------
if (has_emissions) {
  p2 <- ggplot(df, aes(x = .data[[emit_col]])) +
    geom_histogram(bins = 50, fill = "steelblue", colour = "white") +
    labs(title = "Emissions Distribution",
         x = "kg CO\u2082e per unit", y = "Count") +
    theme_minimal()
} else {
  p2 <- placeholder_plot("Emissions Distribution")
}
rendered <- c(rendered, save_plot(p2, "emissions_distribution.png"))

# ---------------------------------------------------------------------------
# Graph 3: Cost by scenario
# ---------------------------------------------------------------------------
if (has_scenario && has_cost) {
  agg_c <- aggregate(df[[cost_col]] ~ df$scenario,
                     data = df, FUN = mean, na.rm = TRUE)
  names(agg_c) <- c("scenario", "mean_cost")
  p3 <- ggplot(agg_c, aes(x = reorder(scenario, mean_cost),
                            y = mean_cost, fill = scenario)) +
    geom_col(show.legend = FALSE) +
    coord_flip() +
    labs(title = "Mean Cost by Scenario",
         x = "Scenario", y = "USD per unit") +
    theme_minimal()
} else {
  p3 <- placeholder_plot("Cost by Scenario")
}
rendered <- c(rendered, save_plot(p3, "cost_by_scenario.png"))

# ---------------------------------------------------------------------------
# Graph 4: Cost distribution
# ---------------------------------------------------------------------------
if (has_cost) {
  p4 <- ggplot(df, aes(x = .data[[cost_col]])) +
    geom_histogram(bins = 50, fill = "darkorange", colour = "white") +
    labs(title = "Cost Distribution", x = "USD per unit", y = "Count") +
    theme_minimal()
} else {
  p4 <- placeholder_plot("Cost Distribution")
}
rendered <- c(rendered, save_plot(p4, "cost_distribution.png"))

# ---------------------------------------------------------------------------
# Graph 5: Scenario comparison (boxplot)
# ---------------------------------------------------------------------------
if (has_scenario && has_emissions) {
  p5 <- ggplot(df, aes(x = scenario, y = .data[[emit_col]], fill = scenario)) +
    geom_boxplot(show.legend = FALSE, outlier.size = 0.8) +
    labs(title = "Emissions Scenario Comparison",
         x = "Scenario", y = "kg CO\u2082e per unit") +
    theme_minimal() +
    theme(axis.text.x = element_text(angle = 30, hjust = 1))
} else {
  p5 <- placeholder_plot("Scenario Comparison")
}
rendered <- c(rendered, save_plot(p5, "scenario_comparison.png"))

# ---------------------------------------------------------------------------
# Graph 6: Summary grid (2×2 mini panels)
# ---------------------------------------------------------------------------
make_mini <- function(p) {
  p + theme_minimal(base_size = 8) +
    labs(title = NULL) +
    theme(legend.position = "none",
          axis.text = element_text(size = 6))
}

summary_plots <- list(make_mini(p1), make_mini(p2), make_mini(p3), make_mini(p4))

grid_file <- file.path(graphs_dir, "summary_grid.png")
if (!file.exists(grid_file) || opts$force) {
  tryCatch({
    png(grid_file,
        width  = as.integer(opts$width  * opts$dpi),
        height = as.integer(opts$height * opts$dpi),
        res    = opts$dpi)
    on.exit(if (length(dev.list()) > 0) dev.off(), add = TRUE)
    graphics::layout(matrix(1:4, nrow = 2))
    for (sp in summary_plots) print(sp)
    dev.off()
    on.exit(NULL)   # clear the guard once successfully closed
    rendered <- c(rendered, grid_file)
    log_entry <- log_msg("INFO", run_id, "Rendered: summary_grid.png", seed = seed_val)
    write_log_entry(log_file, log_entry)
  }, error = function(e) {
    log_msg("WARN", run_id,
            paste("summary_grid.png failed:", conditionMessage(e)))
    if (file.exists(grid_file)) file.remove(grid_file)
  })
}

# ---------------------------------------------------------------------------
# Write summary.json
# ---------------------------------------------------------------------------
summary_path <- file.path(run_dir, "summary.json")

git_sha <- tryCatch(
  trimws(system("git rev-parse --short HEAD 2>/dev/null", intern = TRUE)),
  error = function(e) "unknown"
)

summary_obj <- list(
  run_id          = run_id,
  graphs_rendered = length(rendered),
  status          = "success",
  timestamp       = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  git_sha         = git_sha,
  graphs          = basename(rendered)
)

if (!file.exists(summary_path) || opts$force) {
  write_json(summary_obj, summary_path, pretty = TRUE, auto_unbox = TRUE)
  log_entry <- log_msg("INFO", run_id, "Wrote summary.json", seed = seed_val)
  write_log_entry(log_file, log_entry)
}

log_entry <- log_msg("INFO", run_id,
                     sprintf("Done. %d graph(s) in %s",
                             length(rendered), graphs_dir),
                     seed = seed_val)
write_log_entry(log_file, log_entry)
cat(sprintf("summary.json: %s\n", summary_path))
