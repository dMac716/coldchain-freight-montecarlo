#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
})
if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table package required")

opt <- parse_args(OptionParser(option_list = list(
  make_option(c("--ledger_csv"), type = "character", default = "outputs/lci_reports/canonical/full_lca/inventory_ledger_full.csv"),
  make_option(c("--outdir"), type = "character", default = "outputs/lci_reports/canonical/full_lca")
)))

if (!file.exists(opt$ledger_csv)) stop("ledger_csv not found: ", opt$ledger_csv)
dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

d <- data.table::fread(opt$ledger_csv, showProgress = FALSE)
for (cn in c("stage", "system_id", "dataset_key")) if (!cn %in% names(d)) d[, (cn) := NA_character_]
d[, stage := as.character(stage)]
d[, product_type := as.character(system_id)]
d[, dataset_key := as.character(dataset_key)]
d[, is_placeholder := is.na(dataset_key) | dataset_key == "" | dataset_key == "NEEDS_SOURCE_VALUE"]

overall <- data.table::data.table(
  total_rows = nrow(d),
  placeholder_rows = sum(d$is_placeholder, na.rm = TRUE),
  complete_rows = sum(!d$is_placeholder, na.rm = TRUE)
)
overall[, completion_pct := ifelse(total_rows > 0, 100 * complete_rows / total_rows, NA_real_)]

by_stage <- d[, .(
  total_rows = .N,
  placeholder_rows = sum(is_placeholder, na.rm = TRUE),
  complete_rows = sum(!is_placeholder, na.rm = TRUE)
), by = .(stage)]
by_stage[, completion_pct := ifelse(total_rows > 0, 100 * complete_rows / total_rows, NA_real_)]

by_product <- d[, .(
  total_rows = .N,
  placeholder_rows = sum(is_placeholder, na.rm = TRUE),
  complete_rows = sum(!is_placeholder, na.rm = TRUE)
), by = .(product_type)]
by_product[, completion_pct := ifelse(total_rows > 0, 100 * complete_rows / total_rows, NA_real_)]

data.table::fwrite(overall, file.path(opt$outdir, "lci_completeness_overall.csv"))
data.table::fwrite(by_stage, file.path(opt$outdir, "lci_completeness_by_stage.csv"))
data.table::fwrite(by_product, file.path(opt$outdir, "lci_completeness_by_product_type.csv"))

cat("Wrote", file.path(opt$outdir, "lci_completeness_overall.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "lci_completeness_by_stage.csv"), "\n")
cat("Wrote", file.path(opt$outdir, "lci_completeness_by_product_type.csv"), "\n")
