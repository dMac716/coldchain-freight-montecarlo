#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${1:-${RUN_ID:-full_n20}}"

SCENARIOS=("CENTRALIZED" "REGIONALIZED" "SMOKE_LOCAL")
POWERTRAINS=("diesel" "bev")

ROOT_RUN="outputs/run_bundle/${RUN_ID}"
ROOT_LCI="outputs/lci_reports/${RUN_ID}"
ROOT_VAL="outputs/validation/${RUN_ID}"

mkdir -p "${ROOT_LCI}" "${ROOT_VAL}"

echo "RUN_ID=${RUN_ID}"

echo "[1/4] Building LCI reports (scan_children=true)..."
for SCEN in "${SCENARIOS[@]}"; do
  for PT in "${POWERTRAINS[@]}"; do
    BUNDLE_DIR="${ROOT_RUN}/${SCEN}_${PT}"
    OUT_DIR="${ROOT_LCI}/${SCEN}_${PT}"
    if [[ ! -d "${BUNDLE_DIR}" ]]; then
      echo "SKIP: missing bundle dir ${BUNDLE_DIR}"
      continue
    fi
    mkdir -p "${OUT_DIR}"
    Rscript tools/make_lci_inventory_reports.R \
      --bundle_dir "${BUNDLE_DIR}" \
      --scan_children true \
      --product_type all \
      --outdir "${OUT_DIR}"
  done
done

echo "[2/4] Validating route simulation outputs..."
for SCEN in "${SCENARIOS[@]}"; do
  for PT in "${POWERTRAINS[@]}"; do
    INPUT_DIR="${ROOT_RUN}/${SCEN}_${PT}"
    OUT_DIR="${ROOT_VAL}/route_${SCEN}_${PT}"
    if [[ ! -d "${INPUT_DIR}" ]]; then
      echo "SKIP: missing route validation input ${INPUT_DIR}"
      continue
    fi
    mkdir -p "${OUT_DIR}"
    Rscript tools/validate_route_sim_outputs.R \
      --input_dir "${INPUT_DIR}" \
      --outdir "${OUT_DIR}" \
      --fail_on_error true
  done
done

echo "[3/4] Validating LCI outputs..."
for SCEN in "${SCENARIOS[@]}"; do
  for PT in "${POWERTRAINS[@]}"; do
    LCI_DIR="${ROOT_LCI}/${SCEN}_${PT}"
    OUT_DIR="${ROOT_VAL}/lci_${SCEN}_${PT}"
    if [[ ! -f "${LCI_DIR}/inventory_ledger.csv" ]]; then
      echo "SKIP: missing LCI ledger ${LCI_DIR}/inventory_ledger.csv"
      continue
    fi
    mkdir -p "${OUT_DIR}"
    Rscript tools/validate_lci_report.R \
      --lci_dir "${LCI_DIR}" \
      --outdir "${OUT_DIR}" \
      --fail_on_error true
  done
done

echo "[4/4] Running end-to-end validations..."
for SCEN in "${SCENARIOS[@]}"; do
  OUT_DIR="${ROOT_VAL}/end_to_end_${SCEN}"
  DRY_BUNDLE="${ROOT_RUN}/${SCEN}_diesel"
  REF_BUNDLE="${ROOT_RUN}/${SCEN}_bev"
  DRY_LCI="${ROOT_LCI}/${SCEN}_diesel"
  REF_LCI="${ROOT_LCI}/${SCEN}_bev"
  if [[ ! -d "${DRY_BUNDLE}" || ! -d "${REF_BUNDLE}" || ! -f "${DRY_LCI}/inventory_ledger.csv" || ! -f "${REF_LCI}/inventory_ledger.csv" ]]; then
    echo "SKIP: end-to-end ${SCEN} requires both diesel+bev bundles and LCI ledgers"
    continue
  fi
  mkdir -p "${OUT_DIR}"
  Rscript tools/validate_end_to_end.R \
    --dry_bundle_root "${DRY_BUNDLE}" \
    --refrigerated_bundle_root "${REF_BUNDLE}" \
    --dry_lci_dir "${DRY_LCI}" \
    --refrigerated_lci_dir "${REF_LCI}" \
    --outdir "${OUT_DIR}"
done

echo "Post-merge pipeline complete."
echo "LCI root: ${ROOT_LCI}"
echo "Validation root: ${ROOT_VAL}"
