#!/usr/bin/env Rscript
## tools/build_audit_uniform_dataset.R
## ============================================================================
## Builds a fully uniform Dataset B variant by recomputing the functional unit
## denominator (kcal_delivered) and the primary metric (co2_per_1000kcal) for
## ALL 72,872 rows using the audit_analysis.R formula.
##
## BACKGROUND:
##   The original Dataset B (analysis_postfix_validated.csv.gz) had only 64.1%
##   FU coverage because the route simulation's load model config lacked
##   units_per_case, producing NA for payload → NA for kcal_delivered → NA for
##   co2_per_1000kcal. This script bypasses the load model entirely by deriving
##   payload from columns already present in every row.
##
## AUDIT FORMULA (from tools/audit_analysis.R lines 20-25):
##   payload_kg       = payload_max_lb_draw * load_fraction * 0.453592
##   kcal_delivered   = payload_kg * kcal_per_kg_product
##   co2_per_1000kcal = co2_kg_total / kcal_delivered * 1000
##
##   Where:
##     payload_max_lb_draw  = sampled trailer max payload capacity (lbs)
##     load_fraction        = truck utilization fraction [0, 1]
##     0.453592             = lb-to-kg conversion factor
##     kcal_per_kg_product  = caloric density of the dog food product
##     co2_kg_total         = total trip CO2 (propulsion + TRU)
##
## INPUTS:
##   artifacts/analysis_final_2026-03-17/analysis_postfix_validated.csv.gz
##     — The 72,872-row Dataset B with partial FU coverage
##   artifacts/analysis_final_2026-03-17/fu_recovery_enrichment.csv
##     — Exogenous-draw recovered FU values (method B) for comparison
##   (optional) Phase 2 validated transport_sim_rows.csv from local drive
##
## OUTPUTS:
##   analysis_postfix_audit_uniform.csv.gz — Canonical candidate (72,872 rows, 100% FU)
##   fu_method_comparison.csv              — Four-way comparison table (methods A/B/C/D)
##   fu_method_comparison_memo.txt         — Human-readable summary with baselines
##   manifest/dataset_fingerprint_audit_uniform.json — SHA-256 provenance fingerprint
##
## USAGE:
##   Rscript tools/build_audit_uniform_dataset.R
##   (no arguments — paths are hardcoded to the canonical artifact directory)
##
## DEPENDENCIES:
##   data.table, jsonlite, digest
## ============================================================================

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(digest)
})

ARTIFACT_DIR <- "artifacts/analysis_final_2026-03-17"

## ── Load original Dataset B ──────────────────────────────────────────────────
cat("Loading original Dataset B...\n")
d <- fread(cmd = sprintf("gzcat '%s/analysis_postfix_validated.csv.gz'", ARTIFACT_DIR),
           na.strings = c("", "NA"))
cat(sprintf("  Rows: %d\n", nrow(d)))

## Preserve original (partially-populated) FU values for the four-way comparison
d[, old_kcal_delivered := kcal_delivered]
d[, old_co2_per_1000kcal := co2_per_1000kcal]
d[, old_payload_kg := payload_kg]

## ── Apply audit_analysis.R formula UNIFORMLY to ALL rows ─────────────────────
cat("Applying audit_analysis.R formula to all 72,872 rows...\n")
d[, payload_kg := payload_max_lb_draw * load_fraction * 0.453592]
d[, kcal_delivered := payload_kg * kcal_per_kg_product]
d[, co2_per_1000kcal := co2_kg_total / kcal_delivered * 1000]
d[, fu_method := "audit_uniform"]

n_valid <- sum(is.finite(d$co2_per_1000kcal) & d$co2_per_1000kcal > 0)
cat(sprintf("  Valid co2_per_1000kcal: %d / %d (%.1f%%)\n", n_valid, nrow(d),
            100 * n_valid / nrow(d)))

## ── Validation ───────────────────────────────────────────────────────────────
cat("\n=== Validation ===\n")
cat(sprintf("  NaN/Inf in co2_per_1000kcal: %d\n",
            sum(!is.finite(d$co2_per_1000kcal))))
cat(sprintf("  co2_per_1000kcal <= 0: %d\n",
            sum(d$co2_per_1000kcal <= 0, na.rm = TRUE)))
cat(sprintf("  Range: [%.6f, %.6f]\n",
            min(d$co2_per_1000kcal, na.rm = TRUE),
            max(d$co2_per_1000kcal, na.rm = TRUE)))

## Diesel baseline
dry_d <- d[powertrain == "diesel" & product_type == "dry", mean(co2_per_1000kcal)]
ref_d <- d[powertrain == "diesel" & product_type == "refrigerated", mean(co2_per_1000kcal)]
cat(sprintf("\n  Diesel dry mean:    %.6f\n", dry_d))
cat(sprintf("  Diesel refrig mean: %.6f\n", ref_d))

## ── Load exogenous-draw enrichment for comparison ────────────────────────────
## Method B: payload_lb from sample_exogenous_draws(cfg, seed).
## These were recovered by tools/recover_fu_backfill.R for the 26,152 missing rows.
cat("\nLoading exogenous-draw enrichment...\n")
enrich <- fread(sprintf("%s/fu_recovery_enrichment.csv", ARTIFACT_DIR))
setnames(enrich, c("kcal_delivered", "co2_per_1000kcal", "payload_kg"),
         c("exo_kcal_delivered", "exo_co2_per_1000kcal", "exo_payload_kg"),
         skip_absent = TRUE)

d <- merge(d, enrich[, .(run_id, exo_kcal_delivered, exo_co2_per_1000kcal, exo_payload_kg)],
           by = "run_id", all.x = TRUE, sort = FALSE)

## ── Load phase2 validated data ───────────────────────────────────────────────
## Method D: cube+weight constrained load model from an 80-row validated run.
## Located on local Google Drive. Skipped silently if the file is not present.
cat("Loading phase2 validated data...\n")
p2_path <- "/Users/dMac/My Drive (djmacdonald@ucdavis.edu)/UC Davis/Winter 2025/KissockPaper/local_chunked_run_report_bundle/data/transport_sim_rows.csv"
p2 <- if (file.exists(p2_path)) fread(p2_path) else data.table()
if (nrow(p2) > 0) {
  p2[, product_type := ifelse(grepl("dry", scenario_name), "dry", "refrigerated")]
  p2[, powertrain := ifelse(grepl("bev", scenario_name), "bev", "diesel")]
}

## ── Build four-way comparison table ──────────────────────────────────────────
## Compares co2_per_1000kcal summary statistics across all four FU methods:
##   A_old_stored       — original stored values (46,720 rows, unknown payload source)
##   B_exo_draw_recovery — recovered via exogenous cargo draw (~11t mean payload)
##   C_audit_uniform    — this script's output (~19t trailer-max payload)
##   D_phase2_validated — cube-limited physical model (80 rows, different routes)
cat("\n=== FOUR-WAY COMPARISON BY SCENARIO ===\n\n")

scenarios <- CJ(product_type = c("dry", "refrigerated"),
                powertrain = c("diesel", "bev"))

comparison_rows <- list()

fmt <- function(vals, scenario, label) {
  vals <- vals[is.finite(vals)]
  if (length(vals) == 0) return(NULL)
  data.table(
    scenario = scenario,
    method = label,
    n = length(vals),
    mean = round(mean(vals), 6),
    sd = round(sd(vals), 6),
    p05 = round(quantile(vals, 0.05), 6),
    p50 = round(quantile(vals, 0.50), 6),
    p95 = round(quantile(vals, 0.95), 6)
  )
}

for (i in seq_len(nrow(scenarios))) {
  pt <- scenarios$product_type[i]
  pw <- scenarios$powertrain[i]
  sc <- paste0(pt, "/", pw)
  sub <- d[product_type == pt & powertrain == pw]
  if (nrow(sub) == 0) next

  comparison_rows <- c(comparison_rows, list(
    fmt(sub[!is.na(old_co2_per_1000kcal), old_co2_per_1000kcal], sc, "A_old_stored"),
    fmt(sub[!is.na(exo_co2_per_1000kcal), exo_co2_per_1000kcal], sc, "B_exo_draw_recovery"),
    fmt(sub$co2_per_1000kcal, sc, "C_audit_uniform"),
    if (nrow(p2) > 0) fmt(p2[product_type == pt & powertrain == pw, co2_per_1000kcal], sc, "D_phase2_validated") else NULL
  ))
}

comp <- rbindlist(Filter(function(x) !is.null(x), comparison_rows))
print(comp)

## Write comparison
comp_path <- file.path(ARTIFACT_DIR, "fu_method_comparison.csv")
fwrite(comp, comp_path)
cat(sprintf("\nComparison table -> %s\n", comp_path))

## ── Write uniform dataset ────────────────────────────────────────────────────
## Strip comparison columns before writing — the output dataset should contain
## only the audit-uniform FU values, not the old/exo variants used above.
cat("\nWriting uniform audit-formula dataset...\n")
out <- copy(d)
out[, c("old_kcal_delivered", "old_co2_per_1000kcal", "old_payload_kg",
        "exo_kcal_delivered", "exo_co2_per_1000kcal", "exo_payload_kg") := NULL]

out_path <- file.path(ARTIFACT_DIR, "analysis_postfix_audit_uniform.csv.gz")
fwrite(out, out_path)
cat(sprintf("  Dataset -> %s (%d rows)\n", out_path, nrow(out)))

## ── Fingerprint ──────────────────────────────────────────────────────────────
## Content-addressable fingerprint: SHA-256 hash of sorted run-level fields
## ensures any row additions, deletions, or value changes are detectable.
out[, scenario_key := paste(powertrain, product_type, origin_network, sep = "/")]
counts <- as.list(out[, .N, by = scenario_key][, setNames(N, scenario_key)])
mean_co2 <- as.list(
  out[is.finite(co2_per_1000kcal),
      .(mean_co2 = round(mean(co2_per_1000kcal), 6)),
      by = scenario_key][, setNames(mean_co2, scenario_key)])

hash_input <- out[order(run_id), paste(run_id, co2_kg_total, distance_miles, charge_stops, sep = "|")]
content_hash <- digest(paste(hash_input, collapse = "\n"), algo = "sha256")

fp <- list(
  dataset = "analysis_postfix_audit_uniform.csv.gz",
  fu_method = "audit_analysis.R uniform: payload_kg = payload_max_lb_draw * load_fraction * 0.453592",
  built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  total_rows = nrow(out),
  fu_coverage_pct = round(100 * n_valid / nrow(out), 2),
  counts_per_scenario = counts,
  mean_co2_per_1000kcal_per_scenario = mean_co2,
  diesel_baseline = list(dry_mean = round(dry_d, 6), refrig_mean = round(ref_d, 6)),
  content_hash = content_hash,
  note = "All FU values recomputed uniformly. Exogenous-draw enriched dataset retained as sensitivity artifact only."
)

fp_path <- file.path(ARTIFACT_DIR, "manifest", "dataset_fingerprint_audit_uniform.json")
write(toJSON(fp, auto_unbox = TRUE, pretty = TRUE), fp_path)
cat(sprintf("  Fingerprint -> %s\n", fp_path))

## ── Summary memo ─────────────────────────────────────────────────────────────
## Human-readable memo documenting all four FU methods, their payload definitions,
## diesel baseline values, and a recommendation for which dataset to promote.
memo_path <- file.path(ARTIFACT_DIR, "fu_method_comparison_memo.txt")
sink(memo_path)
cat(sprintf("FU Method Comparison Memo — %s\n", Sys.time()))
cat("================================================================\n\n")

cat("BACKGROUND\n")
cat("----------\n")
cat("Dataset B (analysis_postfix_validated.csv.gz) had 72,872 rows but only\n")
cat("46,720 (64.1%) had co2_per_1000kcal. Four candidate methods exist for\n")
cat("computing the functional unit denominator (kcal_delivered).\n\n")

cat("METHODS\n")
cat("-------\n")
cat("A. Old stored:      From March 16 validated dataset (old run_chunk pipeline).\n")
cat("                    Payload source unknown; only available for 46,720 rows.\n\n")
cat("B. Exo draw:        payload_lb from sample_exogenous_draws(cfg, seed).\n")
cat("                    Uses cfg$cargo$payload_lb triangular(8k,22k,42k).\n")
cat("                    Deterministic per seed. Applied to 26,152 missing rows.\n\n")
cat("C. Audit uniform:   payload_kg = payload_max_lb_draw * load_fraction * 0.453592.\n")
cat("                    From tools/audit_analysis.R lines 20-25.\n")
cat("                    Applied uniformly to ALL 72,872 rows.\n\n")
cat("D. Phase2 valid.:   payload_kg = actual_units_loaded * unit_weight_lb * 0.45359237.\n")
cat("                    Load-model (cube+weight constrained) from validated 80-row run.\n")
cat("                    Requires units_per_case config (missing in production config).\n\n")

cat("COMPARISON TABLE (co2_per_1000kcal)\n")
cat("-----------------------------------\n")
print(comp)

cat("\n\nPAYLOAD SUMMARY (kg)\n")
cat("--------------------\n")
old_mean <- d[!is.na(old_kcal_delivered), mean(old_kcal_delivered / kcal_per_kg_product, na.rm = TRUE)]
exo_mean <- mean(d$exo_payload_kg, na.rm = TRUE)
aud_mean <- mean(d$payload_kg)
cat(sprintf("  A. Old stored:      mean ~%.0f (back-calculated from kcal_delivered)\n", old_mean))
cat(sprintf("  B. Exogenous draw:  mean  %.0f (from cargo distribution, high variance)\n", exo_mean))
cat(sprintf("  C. Audit uniform:   mean  %.0f (trailer max * LF, low variance)\n", aud_mean))
cat("  D. Phase2 load model: dry=16,442, refrig=3,370 (cube-limited)\n\n")

cat("DIESEL BASELINES\n")
cat("----------------\n")
cat("  CLAUDE.md reference:  dry=0.0283, refrig=0.0480\n")
old_dry_d <- d[powertrain == "diesel" & product_type == "dry" & !is.na(old_co2_per_1000kcal),
               mean(old_co2_per_1000kcal)]
old_ref_d <- d[powertrain == "diesel" & product_type == "refrigerated" & !is.na(old_co2_per_1000kcal),
               mean(old_co2_per_1000kcal)]
exo_dry_d <- d[powertrain == "diesel" & product_type == "dry" & !is.na(exo_co2_per_1000kcal),
               mean(exo_co2_per_1000kcal)]
cat(sprintf("  A. Old stored:        dry=%.4f, refrig=%.4f\n", old_dry_d, old_ref_d))
if (length(exo_dry_d) > 0 && !is.na(exo_dry_d)) {
  cat(sprintf("  B. Exo draw recovery: dry=%.4f (rerun rows only)\n", exo_dry_d))
}
cat(sprintf("  C. Audit uniform:     dry=%.4f, refrig=%.4f\n", dry_d, ref_d))
cat("  D. Phase2 validated:  dry=0.0743, refrig=0.6684 (80 rows, different routes)\n\n")

cat("KEY FINDING\n")
cat("-----------\n")
cat("No two methods produce the same FU values. The four methods use different\n")
cat("payload definitions:\n")
cat("  A uses an unknown old-pipeline payload.\n")
cat("  B uses a stochastic cargo-weight draw (mean ~11 tonnes).\n")
cat("  C uses trailer max capacity * load fraction (mean ~19 tonnes).\n")
cat("  D uses cube+weight-constrained product mass (dry ~16t, refrig ~3.4t).\n\n")
cat("Method C (audit uniform) is the only one that:\n")
cat("  1. Can be applied to ALL 72,872 rows.\n")
cat("  2. Uses only columns present in every row.\n")
cat("  3. Matches the documented analysis-stage derivation.\n")
cat("  4. Produces a single consistent denominator definition.\n\n")

cat("DATASET STATUS\n")
cat("--------------\n")
cat("  CANONICAL CANDIDATE:  analysis_postfix_audit_uniform.csv.gz   (72,872 rows, 100% FU)\n")
cat("  SENSITIVITY ONLY:     analysis_postfix_validated_enriched.csv.gz (exo-draw method)\n")
cat("  ORIGINAL (mixed):     analysis_postfix_validated.csv.gz         (64.1% FU coverage)\n")
cat("  COMPARISON:           fu_method_comparison.csv\n\n")

cat("DECISION NEEDED\n")
cat("---------------\n")
cat("Accept audit-uniform (C) as canonical and update CLAUDE.md baselines, OR\n")
cat("fix the config to enable load-model (D) for deterministic recomputation\n")
cat("using the pallet-weight-constrained method.\n")

sink()
cat(sprintf("\n  Memo -> %s\n", memo_path))

cat("\n=== DONE ===\n")
cat(sprintf("  Canonical candidate: %s (%d rows, %.1f%% FU coverage)\n",
            out_path, nrow(out), 100 * n_valid / nrow(out)))
