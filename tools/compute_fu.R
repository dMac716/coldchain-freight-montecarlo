#!/usr/bin/env Rscript
## tools/compute_fu.R
## ============================================================================
## Single entry point for functional unit (FU) computation.
##
## Computes co2_per_1000kcal — the primary emissions metric normalized to the
## functional unit of 1,000 kcal delivered to retail. Enforces a single method
## per dataset to prevent mixed-method contamination.
##
## INPUTS:
##   A gzipped or plain CSV containing at minimum:
##     payload_max_lb_draw  — sampled max payload in lbs (from MC draw)
##     load_fraction        — truck utilization fraction [0, 1]
##     kcal_per_kg_product  — caloric density of product (kcal/kg)
##     co2_kg_total         — total trip CO2 in kg (propulsion + TRU)
##   For --method load_model, also requires: seed, product_type
##
## OUTPUTS:
##   CSV with three new/overwritten columns:
##     payload_kg           — delivered payload mass in kilograms
##     kcal_delivered       — total kcal on the truck
##     co2_per_1000kcal     — kg CO2 per 1,000 kcal delivered (the FU metric)
##     fu_method            — tag identifying which method was used
##   Plus a JSON fingerprint in <output_dir>/manifest/
##
## USAGE:
##   Rscript tools/compute_fu.R \
##     --input  artifacts/analysis_final_2026-03-17/analysis_postfix_validated.csv.gz \
##     --output artifacts/analysis_final_2026-03-17/analysis_postfix_<method>.csv.gz \
##     --method audit_uniform
##
## CLI ARGUMENTS:
##   --input    Path to input CSV or CSV.GZ dataset (required)
##   --output   Path for output CSV (required unless --dry-run)
##   --method   FU computation method (required). One of:
##                audit_uniform — uses trailer-max payload from the dataset
##                load_model    — re-derives payload via the physical load model
##   --dry-run  Validate and summarize without writing output
##
## METHODS:
##   audit_uniform    Algebraic derivation from stored columns:
##                      payload_kg = payload_max_lb_draw * load_fraction * 0.453592
##                    Produces ~19 tonne mean payload. Low variance. Applicable
##                    to all rows. Matches tools/audit_analysis.R formula.
##
##   load_model       Re-derives payload via the cube+weight constrained packing
##                    model (resolve_load_draw), using each row's seed:
##                      payload_kg = product_mass_lb_per_truck * 0.45359237
##                    Requires units_per_case in config/test_kit.yaml — currently
##                    NOT available, so this method will fail at the config gate.
##
## DEPENDENCIES:
##   data.table, jsonlite, digest
##   For load_model: R/sim/*.R chain, R/08_load_model.R, R/07_food_composition.R
##
## All outputs are tagged with fu_method column. Never produces mixed-method
## datasets — the post-compute validation aborts if multiple methods are found.
## ============================================================================

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(digest)
})

## ── CLI args ─────────────────────────────────────────────────────────────────
## Parse named arguments from command line: --flag value pairs.
## parse_arg() returns the token immediately after the flag, or default if absent.
args <- commandArgs(trailingOnly = TRUE)
parse_arg <- function(flag, default = NULL) {
  idx <- match(flag, args)
  if (is.na(idx)) return(default)
  args[idx + 1L]
}

INPUT_PATH  <- parse_arg("--input")   # Source dataset (CSV or CSV.GZ)
OUTPUT_PATH <- parse_arg("--output")  # Destination path for tagged output
METHOD      <- parse_arg("--method")  # "audit_uniform" or "load_model"
DRY_RUN     <- "--dry-run" %in% args  # If TRUE, validate only — no file written

VALID_METHODS <- c("audit_uniform", "load_model")

## ── Validation ───────────────────────────────────────────────────────────────
## Hard gates: abort early if required arguments are missing or invalid.
if (is.null(INPUT_PATH))  stop("--input is required")
if (is.null(OUTPUT_PATH) && !DRY_RUN) stop("--output is required (or use --dry-run)")
if (is.null(METHOD))      stop("--method is required. Valid: ", paste(VALID_METHODS, collapse = ", "))
if (!METHOD %in% VALID_METHODS) stop("Unknown method: ", METHOD, ". Valid: ", paste(VALID_METHODS, collapse = ", "))
if (!file.exists(INPUT_PATH)) stop("Input file not found: ", INPUT_PATH)

cat(sprintf("[compute_fu] method=%s input=%s\n", METHOD, INPUT_PATH))

## ── Load ─────────────────────────────────────────────────────────────────────
is_gz <- grepl("\\.gz$", INPUT_PATH)
d <- if (is_gz) {
  fread(cmd = sprintf("gzcat '%s'", INPUT_PATH), na.strings = c("", "NA"))
} else {
  fread(INPUT_PATH, na.strings = c("", "NA"))
}
cat(sprintf("[compute_fu] loaded %d rows, %d columns\n", nrow(d), ncol(d)))

## ── Prerequisite checks ─────────────────────────────────────────────────────
## Both methods need these four columns. Any NA in these columns makes FU
## derivation impossible for that row, so we fail hard rather than silently
## produce partial coverage.
required_cols <- c("payload_max_lb_draw", "load_fraction", "kcal_per_kg_product", "co2_kg_total")

missing_cols <- setdiff(required_cols, names(d))
if (length(missing_cols) > 0) {
  stop("Missing required columns: ", paste(missing_cols, collapse = ", "))
}

for (col in required_cols) {
  n_na <- sum(is.na(d[[col]]))
  if (n_na > 0) stop(sprintf("Column %s has %d NAs — cannot compute FU", col, n_na))
}

## ── Compute ──────────────────────────────────────────────────────────────────
## METHOD BRANCH 1: audit_uniform
## Uses columns already present in the dataset. No external config needed.
## payload_kg is the trailer's sampled max capacity (lb) scaled by load fraction,
## converted to kg via the lb-to-kg constant (0.453592). This treats payload as
## "how much the truck could carry at its sampled utilization" — a trailer-max
## normalization that produces higher denominators and lower per-FU emissions
## than physical cube-limited loading.
if (METHOD == "audit_uniform") {
  cat("[compute_fu] applying: payload_kg = payload_max_lb_draw * load_fraction * 0.453592\n")
  d[, payload_kg := payload_max_lb_draw * load_fraction * 0.453592]
  d[, kcal_delivered := payload_kg * kcal_per_kg_product]
  d[, co2_per_1000kcal := co2_kg_total / kcal_delivered * 1000]
  d[, fu_method := "audit_uniform"]

## METHOD BRANCH 2: load_model
## Re-derives payload from the physical packing model (cube + weight constrained).
## Each row's seed deterministically reproduces the same load draw used in the
## original simulation. Requires units_per_case in config to compute
## product_mass_lb_per_truck. Currently blocked by missing config values.
} else if (METHOD == "load_model") {
  ## Check config prerequisites
  cfg_path <- "config/test_kit.yaml"
  if (!file.exists(cfg_path)) stop("Config not found: ", cfg_path)

  cfg <- yaml::read_yaml(cfg_path)$test_kit
  dry_upc <- cfg$load_model$products$dry$units_per_case
  ref_upc <- cfg$load_model$products$refrigerated$units_per_case

  if (is.null(dry_upc) || is.null(ref_upc)) {
    stop(
      "load_model method requires units_per_case in config.\n",
      "  dry units_per_case: ", if (is.null(dry_upc)) "MISSING" else dry_upc, "\n",
      "  refrigerated units_per_case: ", if (is.null(ref_upc)) "MISSING" else ref_upc, "\n",
      "Add units_per_case to config/test_kit.yaml load_model.products before using this method.\n",
      "Alternatively, use --method audit_uniform."
    )
  }

  cat("[compute_fu] sourcing load model chain...\n")
  source("R/sim/05_charger_state_model.R")
  source("R/sim/01_build_route_segments.R")
  source("R/sim/02_traffic_model.R")
  source("R/sim/07_event_simulator.R")
  source("R/08_load_model.R")
  source("R/07_food_composition.R")

  food_inputs <- read_food_inputs("data")
  if (is.null(food_inputs)) stop("Food input files not found in data/")
  Sys.unsetenv("REAL_RUN")

  ## Validate on 3 test seeds before processing full dataset.
  ## If the load model returns NA for any test seed, config is still incomplete.
  cat("[compute_fu] validating load model determinism...\n")
  for (test_seed in c(42L, 99999L, 710000L)) {
    ld <- resolve_load_draw(test_seed, cfg, "dry")
    if (!is.finite(ld$product_mass_lb_per_truck)) {
      stop("resolve_load_draw returned NA for product_mass_lb_per_truck with seed ", test_seed,
           " — config is still incomplete")
    }
  }
  cat("[compute_fu] load model validation passed\n")

  if (!("seed" %in% names(d))) stop("load_model method requires 'seed' column")
  if (!("product_type" %in% names(d))) stop("load_model method requires 'product_type' column")

  ## Row-by-row computation: replay each row's seed through the load model
  ## and food profile to get deterministic payload and kcal values.
  ## Uses data.table::set() for in-place updates to avoid copy overhead.
  cat("[compute_fu] computing FU via load model for ", nrow(d), " rows...\n")
  d[, payload_kg := NA_real_]
  d[, kcal_delivered := NA_real_]
  d[, co2_per_1000kcal := NA_real_]

  t0 <- proc.time()
  for (i in seq_len(nrow(d))) {
    seed_val <- as.integer(d$seed[i])
    pt <- d$product_type[i]
    ld <- resolve_load_draw(seed_val, cfg, pt)
    prof <- resolve_food_profile(pt, food_inputs, seed_val)

    mass_lb <- ld$product_mass_lb_per_truck
    pkg <- if (is.finite(mass_lb)) mass_lb * 0.45359237 else NA_real_
    kcal <- if (is.finite(pkg) && is.finite(prof$kcal_per_kg_product)) pkg * prof$kcal_per_kg_product else NA_real_
    fu <- if (is.finite(kcal) && kcal > 0) d$co2_kg_total[i] / kcal * 1000 else NA_real_

    set(d, i, "payload_kg", pkg)
    set(d, i, "kcal_delivered", kcal)
    set(d, i, "co2_per_1000kcal", fu)

    if (i %% 5000 == 0) {
      cat(sprintf("[compute_fu] %d / %d (%.1f s)\n", i, nrow(d), (proc.time() - t0)[3]))
    }
  }
  d[, fu_method := "load_model"]
}

## ── Post-compute validation ──────────────────────────────────────────────────
## Three validation gates protect output quality:
## 1. Coverage gate: at least 99% of rows must have finite positive FU values.
## 2. Range check: warns if max FU > 2.0 (plausibility flag, not a hard stop).
## 3. Method purity: exactly one fu_method value — prevents mixed-method datasets.
n_valid <- sum(is.finite(d$co2_per_1000kcal) & d$co2_per_1000kcal > 0)
n_total <- nrow(d)
coverage <- 100 * n_valid / n_total

cat(sprintf("[compute_fu] coverage: %d / %d (%.1f%%)\n", n_valid, n_total, coverage))

if (n_valid < n_total) {
  n_bad <- n_total - n_valid
  cat(sprintf("[compute_fu] WARNING: %d rows have invalid FU values\n", n_bad))
  if (coverage < 99) {
    stop("[compute_fu] ABORT: FU coverage below 99% — investigate before writing output")
  }
}

## Range check
fu_range <- range(d$co2_per_1000kcal[is.finite(d$co2_per_1000kcal)])
cat(sprintf("[compute_fu] FU range: [%.6f, %.6f]\n", fu_range[1], fu_range[2]))
if (fu_range[2] > 2.0) {
  cat("[compute_fu] WARNING: max FU > 2.0 — check for outliers\n")
}

## Method purity check
methods_in_output <- unique(d$fu_method[!is.na(d$fu_method)])
if (length(methods_in_output) != 1L) {
  stop("[compute_fu] ABORT: output has mixed fu_methods: ", paste(methods_in_output, collapse = ", "))
}

## ── Summary ──────────────────────────────────────────────────────────────────
cat("\n[compute_fu] SUMMARY:\n")
summary_dt <- d[is.finite(co2_per_1000kcal), .(
  n = .N,
  mean_fu = round(mean(co2_per_1000kcal), 6),
  p50_fu = round(median(co2_per_1000kcal), 6),
  mean_payload_kg = round(mean(payload_kg), 0)
), by = .(powertrain, product_type)]
print(summary_dt)

## ── Write ────────────────────────────────────────────────────────────────────
## Writes the tagged dataset and a SHA-256 content fingerprint for provenance.
## The fingerprint hashes run_id|co2_kg_total|distance_miles|charge_stops to
## detect any row-level changes between builds.
if (DRY_RUN) {
  cat("\n[compute_fu] DRY RUN — no output written\n")
} else {
  fwrite(d, OUTPUT_PATH)
  cat(sprintf("\n[compute_fu] wrote %s (%d rows, fu_method=%s)\n",
              OUTPUT_PATH, nrow(d), METHOD))

  ## Write fingerprint
  fp_dir <- file.path(dirname(OUTPUT_PATH), "manifest")
  dir.create(fp_dir, showWarnings = FALSE, recursive = TRUE)

  d[, scenario_key := paste(powertrain, product_type, origin_network, sep = "/")]
  hash_input <- d[order(run_id), paste(run_id, co2_kg_total, distance_miles, charge_stops, sep = "|")]
  content_hash <- digest(paste(hash_input, collapse = "\n"), algo = "sha256")

  fp <- list(
    dataset = basename(OUTPUT_PATH),
    fu_method = METHOD,
    built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    total_rows = nrow(d),
    fu_coverage_pct = round(coverage, 2),
    content_hash = content_hash
  )

  fp_name <- sprintf("dataset_fingerprint_%s.json", METHOD)
  fp_path <- file.path(fp_dir, fp_name)
  write(toJSON(fp, auto_unbox = TRUE, pretty = TRUE), fp_path)
  cat(sprintf("[compute_fu] fingerprint → %s\n", fp_path))
}

cat("[compute_fu] done.\n")
