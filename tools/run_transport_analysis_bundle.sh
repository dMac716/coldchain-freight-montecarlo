#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <bundle_root_1[,bundle_root_2,...]> [out_root]"
  exit 1
fi

BUNDLE_ROOTS_CSV="$1"
OUT_ROOT="${2:-outputs/analysis/transport_analysis_bundle}"
ALLOW_NONCANONICAL="${ALLOW_NONCANONICAL:-false}"
IFS=',' read -r -a BUNDLE_ROOTS <<< "$BUNDLE_ROOTS_CSV"

mkdir -p "$OUT_ROOT"

fail() {
  echo "FAIL: $1"
  exit 1
}

run_rscript() {
  OMP_NUM_THREADS=1 \
  OPENBLAS_NUM_THREADS=1 \
  MKL_NUM_THREADS=1 \
  VECLIB_MAXIMUM_THREADS=1 \
  R_DATATABLE_NUM_THREADS=1 \
  Rscript "$@"
}

check_file_nonempty() {
  local f="$1"
  [[ -f "$f" ]] || fail "Missing artifact: $f"
  [[ -s "$f" ]] || fail "Empty artifact: $f"
}

echo "OUT_ROOT=$OUT_ROOT"
for root in "${BUNDLE_ROOTS[@]}"; do
  root_trimmed="$(echo "$root" | xargs)"
  [[ -d "$root_trimmed" ]] || fail "Bundle root not found: $root_trimmed"
  if [[ "$ALLOW_NONCANONICAL" != "true" ]] && [[ "$root_trimmed" != outputs/run_bundle/canonical/* ]]; then
    fail "Non-canonical bundle root blocked: $root_trimmed (set ALLOW_NONCANONICAL=true to override)"
  fi
  run_name="$(basename "$root_trimmed")"
  outdir="$OUT_ROOT/$run_name"
  mkdir -p "$outdir"

  echo "[1/4] Generate paired comparison artifacts for $root_trimmed"
  run_rscript tools/generate_paired_comparison_artifacts.R \
    --bundle_root "$root_trimmed" \
    --outdir "$outdir"

  echo "[2/4] Validate required outputs for $run_name"
  check_file_nonempty "$outdir/paired_core_comparison_table.csv"
  check_file_nonempty "$outdir/fig_a_transport_emissions_comparison.png"
  check_file_nonempty "$outdir/fig_c1_delivery_time_by_scenario.png"
  check_file_nonempty "$outdir/fig_c2_trucker_hours_by_product_origin.png"
  check_file_nonempty "$outdir/figure_generation_log.txt"

  # Optional panels may log "zero finite rows" warnings; do not fail on those.
  # Hard failures are enforced by required artifact existence checks above.

  echo "[3/4] Validate optional figures for $run_name"
  if [[ -f "$outdir/fig_b_protein_efficiency_comparison.png" ]]; then
    check_file_nonempty "$outdir/fig_b_protein_efficiency_comparison.png"
  else
    echo "WARN: Protein efficiency figure skipped for $run_name (co2_per_kg_protein unavailable; see figure_generation_log.txt)"
  fi
  if [[ -f "$outdir/fig_d_gsi_kgco2.png" ]]; then
    check_file_nonempty "$outdir/fig_d_gsi_kgco2.png"
  else
    echo "WARN: GSI figure skipped for $run_name (see figure_generation_log.txt)"
  fi
  if [[ -f "$outdir/fig_e_bev_outlier_diagnostic.png" ]]; then
    check_file_nonempty "$outdir/fig_e_bev_outlier_diagnostic.png"
  else
    echo "WARN: BEV diagnostic figure skipped for $run_name (see figure_generation_log.txt)"
  fi

  echo "[4/4] Optional LCI checks for $run_name"
  if [[ "${RUN_LCI_CHECKS:-false}" == "true" ]]; then
    lci_dir="${LCI_DIR:-outputs/lci_reports/$run_name}"
    [[ -d "$lci_dir" ]] || fail "RUN_LCI_CHECKS=true but LCI_DIR not found: $lci_dir"
    if [[ -f "$lci_dir/merged_inventory_ledger.csv" ]]; then
      check_file_nonempty "$lci_dir/merged_inventory_ledger.csv"
    else
      echo "WARN: merged_inventory_ledger.csv not found at $lci_dir (skipping merged-ledger check)"
    fi
  fi
done

echo "PASS: transport analysis bundle completed"
