#!/usr/bin/env bash
set -euo pipefail

DRY_BUNDLE_ROOT="${1:-outputs/run_bundle/canonical/analysis_core_dry}"
REF_BUNDLE_ROOT="${2:-outputs/run_bundle/canonical/analysis_core_refrigerated}"
OUT_ROOT="${3:-outputs/lci_reports/canonical}"

DRY_OUT="${OUT_ROOT}/dry"
REF_OUT="${OUT_ROOT}/refrigerated"
FULL_OUT="${OUT_ROOT}/full_lca"
mkdir -p "$DRY_OUT" "$REF_OUT" "$FULL_OUT"

[[ -d "$DRY_BUNDLE_ROOT" ]] || { echo "Missing dry canonical bundle root: $DRY_BUNDLE_ROOT"; exit 1; }
[[ -d "$REF_BUNDLE_ROOT" ]] || { echo "Missing refrigerated canonical bundle root: $REF_BUNDLE_ROOT"; exit 1; }

run_rscript() {
  OMP_NUM_THREADS=1 \
  OPENBLAS_NUM_THREADS=1 \
  MKL_NUM_THREADS=1 \
  VECLIB_MAXIMUM_THREADS=1 \
  R_DATATABLE_NUM_THREADS=1 \
  Rscript "$@"
}

run_lci_family() {
  local family_root="$1"
  local product_type="$2"
  local out_root="$3"
  local ran=0

  # Case A: root itself is a bundle root
  if [[ -f "${family_root}/summaries.csv" ]]; then
    local rid
    rid="$(basename "$family_root")"
    run_rscript tools/make_lci_inventory_reports.R \
      --bundle_dir "$family_root" \
      --scan_children false \
      --product_type "$product_type" \
      --functional_unit 1000kcal \
      --outdir "${out_root}/${rid}"
    ran=1
  fi

  # Case B: root contains canonical run_id folders; process each run_id independently.
  while IFS= read -r run_dir; do
    [[ -d "$run_dir" ]] || continue
    local rid
    rid="$(basename "$run_dir")"
    run_rscript tools/make_lci_inventory_reports.R \
      --bundle_dir "$run_dir" \
      --scan_children true \
      --product_type "$product_type" \
      --functional_unit 1000kcal \
      --outdir "${out_root}/${rid}"
    ran=1
  done < <(find "$family_root" -mindepth 1 -maxdepth 1 -type d | sort)

  [[ "$ran" -eq 1 ]] || { echo "No canonical run bundles found under ${family_root}"; exit 1; }
}

echo "[1/4] Build dry canonical LCI"
run_lci_family "$DRY_BUNDLE_ROOT" "dry" "$DRY_OUT"

echo "[2/4] Build refrigerated canonical LCI"
run_lci_family "$REF_BUNDLE_ROOT" "refrigerated" "$REF_OUT"

echo "[3/4] Merge canonical dry+refrigerated ledgers"
export DRY_OUT REF_OUT FULL_OUT
run_rscript - <<'RS'
suppressPackageStartupMessages(library(data.table))
dry_out <- Sys.getenv("DRY_OUT")
ref_out <- Sys.getenv("REF_OUT")
full_out <- Sys.getenv("FULL_OUT")

led_files <- c(
  Sys.glob(file.path(dry_out, "*", "inventory_ledger.csv")),
  Sys.glob(file.path(ref_out, "*", "inventory_ledger.csv"))
)
if (length(led_files) == 0) stop("No inventory_ledger.csv files found under canonical dry/refrigerated outputs")
led <- rbindlist(lapply(led_files, function(p) fread(p, showProgress = FALSE)), fill = TRUE, use.names = TRUE)
fwrite(led, file.path(full_out, "inventory_ledger_full.csv"))

stg_files <- c(
  Sys.glob(file.path(dry_out, "*", "inventory_summary_by_stage.csv")),
  Sys.glob(file.path(ref_out, "*", "inventory_summary_by_stage.csv"))
)
if (length(stg_files) == 0) stop("No inventory_summary_by_stage.csv files found under canonical dry/refrigerated outputs")
stg <- rbindlist(lapply(stg_files, function(p) fread(p, showProgress = FALSE)), fill = TRUE, use.names = TRUE)
fwrite(stg, file.path(full_out, "inventory_summary_by_stage_full.csv"))
RS

echo "[4/4] Completeness audit"
run_rscript tools/check_lci_completeness.R --ledger_csv "${FULL_OUT}/inventory_ledger_full.csv" --outdir "$FULL_OUT"

echo "PASS: canonical LCI built under ${OUT_ROOT}"
