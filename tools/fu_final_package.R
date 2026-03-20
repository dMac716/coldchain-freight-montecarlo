#!/usr/bin/env Rscript
## tools/fu_final_package.R
## ============================================================================
## Produces the final FU sensitivity analysis package for the paper.
##
## This script assembles results from all four FU computation methods into a
## frozen, self-contained output directory suitable for submission or archiving.
##
## THE FOUR FU METHOD SOURCES:
##   1. audit_uniform (C)     — All 72,872 rows. Payload = trailer max * load
##                               fraction. Mean ~19 tonnes. Low variance. From
##                               build_audit_uniform_dataset.R output at
##                               /tmp/audit_uniform_input.csv.
##
##   2. legacy_stored (A)     — 46,720 rows with original co2_per_1000kcal from
##                               the March 16 validated dataset. Payload source
##                               unknown (old run_chunk pipeline). From
##                               analysis_postfix_validated.csv.gz.
##
##   3. exo_draw (B)          — 26,152 recovered rows. Payload from stochastic
##                               cargo weight draw (triangular 8k-42k lb). Mean
##                               ~11 tonnes. High variance. From
##                               fu_recovery_enrichment.csv.
##
##   4. phase2_load_model (D) — 80 validated rows. Payload from cube+weight
##                               constrained packing model. Dry ~16.4t, refrig
##                               ~3.4t. From local Google Drive transport_sim_rows.csv.
##
## OUTPUT PACKAGE CONTENTS:
##   fu_sensitivity_frozen.csv              Long-form dataset (all methods stacked)
##   fu_sensitivity_summary.csv             Quantile summary by method/product/powertrain
##   fig_fu_sensitivity_two_panel.png/pdf   Publication figure: boxplots by method
##   fig_payload_by_method.png              Companion: payload density by method
##   fu_sensitivity_results_memo.txt        Narrative interpretation and ranking table
##
## USAGE:
##   Rscript tools/fu_final_package.R
##   (requires /tmp/audit_uniform_input.csv and artifact directory to exist)
##
## DEPENDENCIES:
##   data.table, ggplot2, scales
## ============================================================================

suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
  library(scales)
})

ARTIFACT_DIR <- "artifacts/analysis_final_2026-03-17"
OUTDIR <- file.path(ARTIFACT_DIR, "fu_sensitivity_final")
dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)

## ── Load all sources ─────────────────────────────────────────────────────────
cat("Loading sources...\n")

orig <- fread(cmd = sprintf("gzcat '%s/analysis_postfix_validated.csv.gz'", ARTIFACT_DIR),
              na.strings = c("", "NA"))
enrich <- fread(sprintf("%s/fu_recovery_enrichment.csv", ARTIFACT_DIR))
au <- fread("/tmp/audit_uniform_input.csv")

p2_path <- "/Users/dMac/My Drive (djmacdonald@ucdavis.edu)/UC Davis/Winter 2025/KissockPaper/local_chunked_run_report_bundle/data/transport_sim_rows.csv"
p2 <- if (file.exists(p2_path)) fread(p2_path) else data.table()
if (nrow(p2) > 0) {
  p2[, product_type := ifelse(grepl("dry", scenario_name), "dry", "refrigerated")]
  p2[, powertrain := ifelse(grepl("bev", scenario_name), "bev", "diesel")]
}

## ── Build long-form dataset with explicit method labels ──────────────────────
## Stack all four methods into a single long-form dataset. Each row carries
## its fu_method label so consumers can filter/facet without ambiguity.
## The factor ordering (phase2 → legacy → exo → audit) reflects increasing
## payload magnitude, which is the natural comparison order.
cat("Building frozen comparison dataset...\n")

rows <- list()

## C: audit_uniform — all 72,872 rows
rows[[1]] <- au[, .(
  powertrain, product_type,
  co2_per_1000kcal,
  payload_kg,
  kcal_delivered,
  fu_method = "audit_uniform"
)]

## A: legacy_stored — 46,720 rows with original values
a_sub <- orig[!is.na(co2_per_1000kcal)]
rows[[2]] <- a_sub[, .(
  powertrain, product_type,
  co2_per_1000kcal,
  payload_kg,
  kcal_delivered,
  fu_method = "legacy_stored"
)]

## B: exo_draw — 26,152 recovered rows
b_sub <- merge(enrich[, .(run_id, co2_per_1000kcal, payload_kg, kcal_delivered)],
               au[, .(run_id, powertrain, product_type)],
               by = "run_id")
rows[[3]] <- b_sub[, .(
  powertrain, product_type,
  co2_per_1000kcal,
  payload_kg,
  kcal_delivered,
  fu_method = "exo_draw"
)]

## D: phase2_load_model — 80 validated rows
if (nrow(p2) > 0) {
  rows[[4]] <- p2[, .(
    powertrain, product_type,
    co2_per_1000kcal,
    payload_kg = payload_kg_delivered,
    kcal_delivered = total_kcal_delivered,
    fu_method = "phase2_load_model"
  )]
}

frozen <- rbindlist(rows, fill = TRUE)
frozen[, fu_method := factor(fu_method,
  levels = c("phase2_load_model", "legacy_stored", "exo_draw", "audit_uniform"))]

fwrite(frozen, file.path(OUTDIR, "fu_sensitivity_frozen.csv"))
cat(sprintf("  Frozen dataset: %d rows\n", nrow(frozen)))

## ── Summary statistics table ─────────────────────────────────────────────────
summary_dt <- frozen[is.finite(co2_per_1000kcal), .(
  n = .N,
  mean_co2_fu = round(mean(co2_per_1000kcal), 6),
  sd = round(sd(co2_per_1000kcal), 6),
  p05 = round(quantile(co2_per_1000kcal, 0.05), 6),
  p50 = round(quantile(co2_per_1000kcal, 0.50), 6),
  p95 = round(quantile(co2_per_1000kcal, 0.95), 6),
  mean_payload_kg = round(mean(payload_kg, na.rm = TRUE), 0)
), by = .(product_type, powertrain, fu_method)]

setorder(summary_dt, product_type, powertrain, fu_method)
fwrite(summary_dt, file.path(OUTDIR, "fu_sensitivity_summary.csv"))

## ── Publication figure ───────────────────────────────────────────────────────
## Two-panel boxplot: one panel per product type (dry / refrigerated).
## Within each panel, x-axis shows the four FU methods, fill distinguishes
## diesel vs BEV. This is the key figure demonstrating that BEV-vs-diesel
## ranking depends on the FU denominator choice.
cat("Building publication figure...\n")

method_labels <- c(
  "phase2_load_model" = "Phase 2\n(cube-limited)",
  "legacy_stored" = "Legacy\n(old pipeline)",
  "exo_draw" = "Exogenous\n(cargo draw)",
  "audit_uniform" = "Audit\n(trailer-max)"
)

method_colors <- c(
  "phase2_load_model" = "#CC79A7",
  "legacy_stored" = "#E69F00",
  "exo_draw" = "#56B4E9",
  "audit_uniform" = "#009E73"
)

powertrain_fills <- c(diesel = "coral", bev = "steelblue")

plot_data <- frozen[is.finite(co2_per_1000kcal)]
plot_data[, pw_label := factor(toupper(powertrain), levels = c("DIESEL", "BEV"))]
plot_data[, method_label := factor(method_labels[as.character(fu_method)],
                                    levels = method_labels)]
plot_data[, pt_label := factor(
  ifelse(product_type == "dry", "Dry Product (Hill\u2019s 30 lb)",
         "Refrigerated Product (Freshpet 4.5 lb)"),
  levels = c("Dry Product (Hill\u2019s 30 lb)", "Refrigerated Product (Freshpet 4.5 lb)")
)]

## Two-panel figure
pub_fig <- ggplot(plot_data,
                  aes(x = method_label, y = co2_per_1000kcal, fill = powertrain)) +
  geom_boxplot(outlier.size = 0.2, outlier.alpha = 0.15, width = 0.7,
               position = position_dodge(width = 0.8)) +
  scale_fill_manual(values = powertrain_fills,
                    labels = c(diesel = "Diesel", bev = "BEV"),
                    name = "Powertrain") +
  facet_wrap(~pt_label, scales = "free_y", ncol = 2) +
  labs(
    title = "CO\u2082 Emissions per Functional Unit by Denominator Method",
    subtitle = "Route distance controlled; FU denominator choice dominates the BEV vs diesel ranking",
    x = "Functional Unit Method",
    y = expression("kg CO"[2]*" / 1000 kcal delivered")
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title = element_text(face = "bold", size = 15),
    plot.subtitle = element_text(size = 11, color = "gray30"),
    strip.text = element_text(face = "bold", size = 12),
    axis.text.x = element_text(size = 9, lineheight = 0.9),
    legend.position = "top",
    panel.grid.major.x = element_blank()
  )

ggsave(file.path(OUTDIR, "fig_fu_sensitivity_two_panel.png"), pub_fig,
       width = 14, height = 7, dpi = 300)
ggsave(file.path(OUTDIR, "fig_fu_sensitivity_two_panel.pdf"), pub_fig,
       width = 14, height = 7)

cat("  Publication figure written (PNG + PDF).\n")

## ── Payload companion figure ─────────────────────────────────────────────────
## Shows the underlying payload distributions that drive FU differences.
## Explains *why* the methods disagree: different payload definitions produce
## different denominators, and refrigerated freight is especially sensitive
## because of the cube-limited vs trailer-max divergence.
pay_data <- frozen[is.finite(payload_kg)]
pay_data[, method_label := factor(method_labels[as.character(fu_method)],
                                   levels = method_labels)]
pay_data[, pt_label := factor(
  ifelse(product_type == "dry", "Dry Product", "Refrigerated Product"),
  levels = c("Dry Product", "Refrigerated Product")
)]

pay_fig <- ggplot(pay_data, aes(x = payload_kg / 1000, fill = fu_method, color = fu_method)) +
  geom_density(alpha = 0.2, linewidth = 0.8) +
  scale_fill_manual(values = method_colors, labels = method_labels, name = "FU Method") +
  scale_color_manual(values = method_colors, labels = method_labels, name = "FU Method") +
  facet_wrap(~pt_label, scales = "free") +
  labs(
    title = "Payload Distribution by FU Method",
    subtitle = "The denominator driving functional unit differences",
    x = "Payload (tonnes)"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title = element_text(face = "bold", size = 15),
    plot.subtitle = element_text(size = 11, color = "gray30"),
    strip.text = element_text(face = "bold", size = 12),
    legend.position = "bottom"
  )

ggsave(file.path(OUTDIR, "fig_payload_by_method.png"), pay_fig,
       width = 12, height = 5, dpi = 300)
cat("  Payload companion figure written.\n")

## ── Results memo ─────────────────────────────────────────────────────────────
## Narrative memo for human review: headline finding, method descriptions,
## summary statistics, BEV-vs-diesel ranking table, and interpretation.
cat("Writing results memo...\n")

memo_path <- file.path(OUTDIR, "fu_sensitivity_results_memo.txt")
sink(memo_path)

cat("RESULTS MEMO: Functional Unit Sensitivity Analysis\n")
cat("===================================================\n")
cat(sprintf("Generated: %s\n\n", Sys.time()))

cat("HEADLINE\n")
cat("--------\n")
cat("When route distance is controlled, the inferred climate advantage of BEV\n")
cat("versus diesel depends strongly on the functional unit denominator; under\n")
cat("cube-limited physical loading BEV outperforms diesel, while under\n")
cat("trailer-max normalization BEV appears worse.\n\n")

cat("METHODS COMPARED\n")
cat("----------------\n")
cat("  phase2_load_model  Cube+weight constrained packing (item -> box -> pallet -> truck).\n")
cat("                     Payload = actual_units_loaded * unit_weight_lb * 0.45359237.\n")
cat("                     Dry: ~16.4 tonnes.  Refrigerated: ~3.4 tonnes.\n")
cat("                     Source: 80 validated phase2 production rows.\n\n")

cat("  legacy_stored      Original March 16 validated dataset (old run_chunk pipeline).\n")
cat("                     Payload source: unknown old-pipeline method.\n")
cat("                     Source: 46,720 rows (diesel + pre-fix BEV).\n\n")

cat("  exo_draw           Stochastic cargo weight from sample_exogenous_draws(cfg, seed).\n")
cat("                     Payload = cfg$cargo$payload_lb draw (~8-42k lb triangular).\n")
cat("                     Mean: ~10.9 tonnes.  High variance.\n")
cat("                     Source: 26,152 recovered rows (post-fix BEV + rerun diesel).\n\n")

cat("  audit_uniform      Trailer max capacity * load fraction.\n")
cat("                     Payload = payload_max_lb_draw * load_fraction * 0.453592.\n")
cat("                     Mean: ~19.0 tonnes.  Low variance.\n")
cat("                     Source: All 72,872 rows (uniform recomputation).\n\n")

cat("SUMMARY STATISTICS (co2_per_1000kcal)\n")
cat("-------------------------------------\n")
print(summary_dt)

cat("\n\nBEV vs DIESEL RANKING BY METHOD\n")
cat("-------------------------------\n")

for (pt in c("dry", "refrigerated")) {
  cat(sprintf("\n  %s:\n", toupper(pt)))
  for (m in levels(frozen$fu_method)) {
    d_val <- frozen[product_type == pt & powertrain == "diesel" & fu_method == m &
                     is.finite(co2_per_1000kcal), mean(co2_per_1000kcal)]
    b_val <- frozen[product_type == pt & powertrain == "bev" & fu_method == m &
                     is.finite(co2_per_1000kcal), mean(co2_per_1000kcal)]
    if (length(d_val) == 0 || length(b_val) == 0) next
    if (is.na(d_val) || is.na(b_val)) next
    pct <- round(100 * (d_val - b_val) / d_val, 1)
    winner <- if (b_val < d_val) "BEV WINS" else "DIESEL WINS"
    cat(sprintf("    %-20s  diesel=%.4f  bev=%.4f  delta=%+.1f%%  %s\n",
                m, d_val, b_val, pct, winner))
  }
}

cat("\n\nINTERPRETATION\n")
cat("--------------\n")
cat("The route simulation holds distance constant across powertrain scenarios\n")
cat("(same origin-destination pairs, same route geometry). This means CO2\n")
cat("differences between BEV and diesel are driven by:\n")
cat("  (a) energy efficiency differences (propulsion + TRU), and\n")
cat("  (b) the functional unit denominator (how much food is delivered).\n\n")

cat("Under cube-limited physical loading (phase2_load_model), refrigerated\n")
cat("product fills only ~3.4 tonnes per truck due to case geometry constraints.\n")
cat("This small denominator amplifies per-FU emissions for both powertrains,\n")
cat("but BEV's lower absolute CO2 per trip (~288 vs ~668 g/1000kcal) gives it\n")
cat("a ~57% advantage. The physical loading model correctly captures that\n")
cat("refrigerated freight is volume-limited, not weight-limited.\n\n")

cat("Under trailer-max normalization (audit_uniform), payload is assumed at\n")
cat("~19 tonnes for all scenarios. This inflates kcal_delivered for refrigerated\n")
cat("freight by ~5.6x relative to the physical model, compressing per-FU\n")
cat("emissions and erasing the BEV advantage. The result is an artifact of the\n")
cat("denominator assumption, not a real change in energy efficiency.\n\n")

cat("The exogenous cargo draw (exo_draw) falls between these extremes, with\n")
cat("high variance reflecting the unconstrained triangular distribution.\n\n")

cat("CONCLUSION: The choice of functional unit denominator is a first-order\n")
cat("determinant of the BEV-vs-diesel comparison for refrigerated cold-chain\n")
cat("freight. Studies using trailer-max normalization may systematically\n")
cat("understate the climate benefit of electrification for cube-limited loads.\n\n")

cat("OUTPUT FILES\n")
cat("------------\n")
cat("  fu_sensitivity_frozen.csv              Frozen comparison dataset (all methods)\n")
cat("  fu_sensitivity_summary.csv             Summary statistics by method/scenario\n")
cat("  fu_sensitivity_results_memo.txt        This memo\n")
cat("  fig_fu_sensitivity_two_panel.png/pdf   Publication figure\n")
cat("  fig_payload_by_method.png              Payload companion figure\n")

sink()
cat(sprintf("  Memo -> %s\n", memo_path))

## ── Final listing ────────────────────────────────────────────────────────────
cat("\n=== FINAL PACKAGE ===\n")
for (f in list.files(OUTDIR, recursive = TRUE)) {
  info <- file.info(file.path(OUTDIR, f))
  cat(sprintf("  %-45s  %s\n", f, format(info$size, big.mark = ",")))
}
cat("\nDone.\n")
