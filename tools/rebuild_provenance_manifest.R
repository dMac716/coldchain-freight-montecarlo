#!/usr/bin/env Rscript
## tools/rebuild_provenance_manifest.R
##
## Phase 1: Ingest all summaries.csv files from extracted tarballs and
## transport_runs, enrich with provenance from file paths + sibling JSON,
## classify BEV bug era, and produce a flat manifest.csv.
##
## Usage:
##   Rscript tools/rebuild_provenance_manifest.R \
##     --extracted /tmp/master_rebuild/extracted \
##     --transport /tmp/master_rebuild/transport_runs \
##     --tarballs  /tmp/master_rebuild/tarballs \
##     --outdir    /tmp/master_rebuild/manifest

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

## ── CLI args ────────────────────────────────────────────────────────────────
args <- commandArgs(trailingOnly = TRUE)
parse_arg <- function(flag, default) {
  idx <- match(flag, args)
  if (is.na(idx)) return(default)
  args[idx + 1L]
}

EXTRACTED_DIR  <- parse_arg("--extracted", "/tmp/master_rebuild/extracted")
TRANSPORT_DIR  <- parse_arg("--transport", "/tmp/master_rebuild/transport_runs")
TARBALLS_DIR   <- parse_arg("--tarballs",  "/tmp/master_rebuild/tarballs")
OUTDIR         <- parse_arg("--outdir",    "/tmp/master_rebuild/manifest")

dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

## ── Build tarball→source_directory mapping ──────────────────────────────────
## Authoritative: the tarball files physically present in each GCS subdirectory.
build_tarball_map <- function(tarballs_dir) {
  map <- list()
  for (src_dir in c("runs", "reruns_bev_fix", "local_backup")) {
    d <- file.path(tarballs_dir, src_dir)
    if (!dir.exists(d)) next
    tars <- list.files(d, pattern = "\\.tar\\.gz$")
    names_clean <- sub("\\.tar\\.gz$", "", tars)
    for (nm in names_clean) {
      map[[nm]] <- src_dir
    }
  }
  map
}

tarball_map <- build_tarball_map(TARBALLS_DIR)
cat(sprintf("Tarball map: %d entries across sources\n", length(tarball_map)))

## ── Derive source_platform from tarball/directory name ──────────────────────
derive_platform <- function(name) {
  name <- tolower(name)
  if (grepl("gcp-ta-worker|coldchain-worker", name)) return("gcp")
  if (grepl("^az_|_azure", name))                    return("azure")
  if (grepl("^cs[0-9]|codespace", name))             return("codespace")
  if (grepl("_local$|^local_|_local_", name))        return("local")
  if (grepl("camber", name))                         return("camber")
  if (grepl("bev_extra|bev_local|bev_prod", name))   return("local")
  if (grepl("traffic_aware", name))                  return("gcp")
  if (grepl("extend_ta", name))                      return("local")
  if (grepl("marathon", name))                       return("local")  # fallback
  "unknown"
}

## ── Find all summaries.csv files ────────────────────────────────────────────
cat("Discovering summaries.csv files...\n")
t0 <- proc.time()

extracted_files <- list.files(
  EXTRACTED_DIR, pattern = "^summaries\\.csv$",
  recursive = TRUE, full.names = TRUE
)
cat(sprintf("  extracted/: %d summaries.csv files\n", length(extracted_files)))

transport_files <- list.files(
  TRANSPORT_DIR, pattern = "^summaries\\.csv$",
  recursive = TRUE, full.names = TRUE
)
cat(sprintf("  transport_runs/: %d summaries.csv files\n", length(transport_files)))

elapsed <- (proc.time() - t0)[3]
cat(sprintf("Discovery took %.1f seconds\n", elapsed))

## ── Map extracted file → source tarball + source directory ──────────────────
## Extracted dirs are: EXTRACTED_DIR/<tarball_name>/...
## OR for local_backup: EXTRACTED_DIR/local_run_bundles_backup/<sub_bundle>/...
resolve_source <- function(filepath, extracted_dir, tarball_map) {
  rel <- sub(paste0("^", gsub("([\\[\\]])", "\\\\\\1", extracted_dir), "/"), "", filepath)
  parts <- strsplit(rel, "/", fixed = TRUE)[[1]]
  top_dir <- parts[1]

  ## Direct tarball match

  if (!is.null(tarball_map[[top_dir]])) {
    return(list(
      source_tarball   = paste0(top_dir, ".tar.gz"),
      source_directory = tarball_map[[top_dir]],
      source_platform  = derive_platform(top_dir)
    ))
  }

  ## local_backup: top_dir is "local_run_bundles_backup", sub-bundle is parts[2]
  if (top_dir == "local_run_bundles_backup") {
    sub_bundle <- if (length(parts) >= 2) parts[2] else top_dir
    return(list(
      source_tarball   = "local_run_bundles_backup.tar.gz",
      source_directory = "local_backup",
      source_platform  = derive_platform(sub_bundle)
    ))
  }

  ## Nested extraction: some tarballs extract into a subdir with same name
  ## e.g., marathon2_seed610000_gcp-ta-worker-1/marathon2_seed610000_gcp-ta-worker-1/...
  ## The top_dir might be the tarball name but the summaries are nested deeper
  ## Check if this top_dir is an extracted tarball dir that contains sub-dirs
  ## matching another tarball name
  for (nm in names(tarball_map)) {
    if (startsWith(top_dir, nm) || startsWith(nm, top_dir)) {
      return(list(
        source_tarball   = paste0(nm, ".tar.gz"),
        source_directory = tarball_map[[nm]],
        source_platform  = derive_platform(nm)
      ))
    }
  }

  ## Fallback
  list(
    source_tarball   = top_dir,
    source_directory = "unknown",
    source_platform  = derive_platform(top_dir)
  )
}

## ── Read sibling JSON helpers ───────────────────────────────────────────────
read_pair_manifest <- function(dir) {
  f <- file.path(dir, "pair_manifest.json")
  if (!file.exists(f)) return(list(seed = NA_integer_, member_count = NA_integer_))
  tryCatch({
    j <- fromJSON(f, simplifyVector = TRUE)
    list(
      seed         = as.integer(j$seed),
      member_count = as.integer(j$member_count)
    )
  }, error = function(e) list(seed = NA_integer_, member_count = NA_integer_))
}

read_artifacts_json <- function(dir) {
  f <- file.path(dir, "artifacts.json")
  if (!file.exists(f)) return(list(model_version = NA_character_, inputs_hash = NA_character_))
  tryCatch({
    j <- fromJSON(f, simplifyVector = TRUE)
    list(
      model_version = as.character(j$model_version %||% NA_character_),
      inputs_hash   = as.character(j$inputs_hash %||% NA_character_)
    )
  }, error = function(e) list(model_version = NA_character_, inputs_hash = NA_character_))
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a[1])) b else a

## ── Columns to extract from summaries.csv ───────────────────────────────────
PAYLOAD_COLS <- c(
  "run_id", "pair_id", "powertrain", "product_type", "origin_network",
  "scenario_id", "scenario",
  "charge_stops", "distance_miles", "co2_kg_total", "co2_per_1000kcal",
  "energy_kwh_total", "trip_duration_total_h", "kcal_delivered",
  "payload_max_lb_draw", "load_fraction", "kcal_per_kg_product",
  "kcal_per_truck", "status"
)

## ── Process a single summaries.csv ──────────────────────────────────────────
process_summary <- function(filepath, source_info) {
  dt <- tryCatch(
    fread(filepath, select = PAYLOAD_COLS, na.strings = c("", "NA"),
          showProgress = FALSE, fill = TRUE),
    error = function(e) NULL
  )
  if (is.null(dt) || nrow(dt) == 0) return(NULL)

  ## Ensure all columns exist
  for (col in PAYLOAD_COLS) {
    if (!col %in% names(dt)) dt[, (col) := NA]
  }

  ## Read sibling JSON
  pair_dir <- dirname(filepath)
  pm <- read_pair_manifest(pair_dir)
  aj <- read_artifacts_json(pair_dir)

  ## Extract seed from pair_id (e.g., "ANALYSIS_CORE_bev_seed_660499" → 660499)
  seed_from_pair <- tryCatch(
    as.integer(sub(".*seed_", "", dt$pair_id[1])),
    warning = function(w) NA_integer_
  )

  dt[, `:=`(
    seed             = pm$seed %||% seed_from_pair,
    member_count     = pm$member_count,
    model_version    = aj$model_version,
    inputs_hash      = aj$inputs_hash,
    source_tarball   = source_info$source_tarball,
    source_directory = source_info$source_directory,
    source_platform  = source_info$source_platform,
    filepath         = filepath
  )]

  ## Classify BEV bug era
  dt[, bug_era := fcase(
    powertrain == "bev" & !is.na(charge_stops) & charge_stops == 0, "legacy_bugged_bev",
    powertrain == "bev" & !is.na(charge_stops) & charge_stops > 0,  "post_fix_bev",
    powertrain == "diesel", "diesel",
    default = "unknown"
  )]

  ## Completeness check
  dt[, completeness_status := fifelse(
    is.na(co2_kg_total) | is.na(distance_miles) | is.na(powertrain),
    "incomplete", "complete"
  )]

  dt
}

## ── Main ingestion loop ─────────────────────────────────────────────────────
cat("\n=== Phase 1a: Processing extracted/ summaries ===\n")
t0 <- proc.time()

## Process in batches for memory efficiency
BATCH_SIZE <- 5000
all_results <- vector("list", ceiling(length(extracted_files) / BATCH_SIZE))
batch_idx <- 1

for (start in seq(1, length(extracted_files), by = BATCH_SIZE)) {
  end <- min(start + BATCH_SIZE - 1, length(extracted_files))
  batch_files <- extracted_files[start:end]

  batch_results <- lapply(batch_files, function(f) {
    src <- resolve_source(f, EXTRACTED_DIR, tarball_map)
    process_summary(f, src)
  })

  batch_results <- Filter(Negate(is.null), batch_results)
  if (length(batch_results) > 0) {
    all_results[[batch_idx]] <- rbindlist(batch_results, fill = TRUE)
  }
  batch_idx <- batch_idx + 1

  pct <- round(end / length(extracted_files) * 100)
  cat(sprintf("\r  Processed %d / %d extracted files (%d%%)",
              end, length(extracted_files), pct))
}
cat("\n")

extracted_dt <- rbindlist(Filter(Negate(is.null), all_results), fill = TRUE)
elapsed <- (proc.time() - t0)[3]
cat(sprintf("  Extracted: %d rows from %d files (%.1f min)\n",
            nrow(extracted_dt), length(extracted_files), elapsed / 60))

## ── Process transport_runs ──────────────────────────────────────────────────
cat("\n=== Phase 1b: Processing transport_runs/ summaries ===\n")
t0 <- proc.time()

transport_results <- lapply(transport_files, function(f) {
  ## transport_runs are NOT from tarballs — they're directory copies
  src <- list(
    source_tarball   = NA_character_,
    source_directory = "transport_runs",
    source_platform  = derive_platform(f)
  )
  process_summary(f, src)
})

transport_results <- Filter(Negate(is.null), transport_results)
transport_dt <- if (length(transport_results) > 0) {
  rbindlist(transport_results, fill = TRUE)
} else {
  data.table()
}

elapsed <- (proc.time() - t0)[3]
cat(sprintf("  Transport: %d rows from %d files (%.1f sec)\n",
            nrow(transport_dt), length(transport_files), elapsed))

## ── Combine ─────────────────────────────────────────────────────────────────
cat("\n=== Combining all sources ===\n")
manifest <- rbindlist(list(extracted_dt, transport_dt), fill = TRUE)

cat(sprintf("Total manifest rows:     %d\n", nrow(manifest)))
cat(sprintf("Unique run_ids:          %d\n", uniqueN(manifest$run_id)))
cat(sprintf("  from extracted/:       %d rows\n", nrow(extracted_dt)))
cat(sprintf("  from transport_runs/:  %d rows\n", nrow(transport_dt)))

## ── Summary stats ───────────────────────────────────────────────────────────
cat("\n--- By source_directory ---\n")
print(manifest[, .N, by = source_directory][order(-N)])

cat("\n--- By powertrain × bug_era ---\n")
print(manifest[, .N, by = .(powertrain, bug_era)][order(powertrain, bug_era)])

cat("\n--- By source_platform ---\n")
print(manifest[, .N, by = source_platform][order(-N)])

cat("\n--- By origin_network ---\n")
print(manifest[, .N, by = origin_network][order(-N)])

cat("\n--- Completeness ---\n")
print(manifest[, .N, by = completeness_status])

## ── Write manifest ──────────────────────────────────────────────────────────
out_path <- file.path(OUTDIR, "manifest.csv")
fwrite(manifest, out_path)
cat(sprintf("\nManifest written to: %s (%d rows)\n", out_path, nrow(manifest)))

## Also write a quick summary
summary_path <- file.path(OUTDIR, "manifest_summary.txt")
sink(summary_path)
cat(sprintf("Manifest built: %s\n", Sys.time()))
cat(sprintf("Total rows: %d\n", nrow(manifest)))
cat(sprintf("Unique run_ids: %d\n", uniqueN(manifest$run_id)))
cat("\nBy source_directory:\n")
print(manifest[, .N, by = source_directory][order(-N)])
cat("\nBy powertrain × bug_era:\n")
print(manifest[, .N, by = .(powertrain, bug_era)][order(powertrain, bug_era)])
cat("\nBy source_platform:\n")
print(manifest[, .N, by = source_platform][order(-N)])
cat("\nBy origin_network:\n")
print(manifest[, .N, by = origin_network][order(-N)])
cat("\nBy completeness_status:\n")
print(manifest[, .N, by = completeness_status])
sink()
cat(sprintf("Summary written to: %s\n", summary_path))
