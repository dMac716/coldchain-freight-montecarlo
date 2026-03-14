#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${1:-${RUN_ID:-full_n20}}"
N="${N:-20}"
SEED="${SEED:-123}"
BATCH_SIZE="${BATCH_SIZE:-50}"
ARTIFACT_MODE="${ARTIFACT_MODE:-summary_only}"

sanitize_token() {
  local v="$1"
  # Remove whitespace and trailing commas from accidental "VAR=val," shell usage.
  v="${v//[[:space:]]/}"
  v="${v%,}"
  printf "%s" "$v"
}

N="$(sanitize_token "${N}")"
SEED="$(sanitize_token "${SEED}")"
BATCH_SIZE="$(sanitize_token "${BATCH_SIZE}")"
ARTIFACT_MODE="$(sanitize_token "${ARTIFACT_MODE}")"

if ! [[ "${N}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: N must be a non-negative integer, got '${N}'" >&2
  exit 1
fi
if ! [[ "${SEED}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SEED must be a non-negative integer, got '${SEED}'" >&2
  exit 1
fi
if ! [[ "${BATCH_SIZE}" =~ ^[0-9]+$ ]] || [[ "${BATCH_SIZE}" -lt 1 ]]; then
  echo "ERROR: BATCH_SIZE must be an integer >= 1, got '${BATCH_SIZE}'" >&2
  exit 1
fi
if [[ "${ARTIFACT_MODE}" != "summary_only" && "${ARTIFACT_MODE}" != "full" ]]; then
  echo "ERROR: ARTIFACT_MODE must be 'summary_only' or 'full', got '${ARTIFACT_MODE}'" >&2
  exit 1
fi

SCENARIOS=("CENTRALIZED" "REGIONALIZED" "SMOKE_LOCAL")
POWERTRAINS=("diesel" "bev")

ROOT_RUN="outputs/run_bundle/${RUN_ID}"
ROOT_LCI="outputs/lci_reports/${RUN_ID}"
ROOT_VAL="outputs/validation/${RUN_ID}"
ROOT_SUM="outputs/summaries"

mkdir -p "${ROOT_RUN}" "${ROOT_LCI}" "${ROOT_VAL}" "${ROOT_SUM}"

echo "RUN_ID=${RUN_ID} N=${N} SEED=${SEED} ARTIFACT_MODE=${ARTIFACT_MODE}"

echo "[1/6] Running Monte Carlo route simulations..."
for SCEN in "${SCENARIOS[@]}"; do
  for PT in "${POWERTRAINS[@]}"; do
    BUNDLE_ROOT="${ROOT_RUN}/${SCEN}_${PT}"
    mkdir -p "${BUNDLE_ROOT}"
    Rscript tools/run_route_sim_mc.R \
      --scenario "${SCEN}" \
      --powertrain "${PT}" \
      --n "${N}" \
      --seed "${SEED}" \
      --paired_origin_networks true \
      --paired_traffic_modes true \
      --artifact_mode "${ARTIFACT_MODE}" \
      --batch_size "${BATCH_SIZE}" \
      --bundle_root "${BUNDLE_ROOT}" \
      --summary_out "${BUNDLE_ROOT}/route_sim_summary.csv"
  done
done

echo "[2/6] Merging MC batches..."
BUNDLE_ROOTS=()
for SCEN in "${SCENARIOS[@]}"; do
  for PT in "${POWERTRAINS[@]}"; do
    BUNDLE_ROOTS+=("${ROOT_RUN}/${SCEN}_${PT}")
  done
done
BUNDLE_ROOTS_CSV="$(IFS=,; echo "${BUNDLE_ROOTS[*]}")"

Rscript tools/merge_mc_batches.R \
  --bundle_roots "${BUNDLE_ROOTS_CSV}" \
  --runs_out "${ROOT_SUM}/${RUN_ID}_runs_merged.csv" \
  --summary_out "${ROOT_SUM}/${RUN_ID}_summary_merged.csv" \
  --summary_by_origin_out "${ROOT_SUM}/${RUN_ID}_summary_by_origin.csv"

echo "[3/6] Building LCI reports..."
for SCEN in "${SCENARIOS[@]}"; do
  for PT in "${POWERTRAINS[@]}"; do
    BUNDLE_DIR="${ROOT_RUN}/${SCEN}_${PT}"
    OUT_DIR="${ROOT_LCI}/${SCEN}_${PT}"
    mkdir -p "${OUT_DIR}"
    Rscript tools/make_lci_inventory_reports.R \
      --bundle_dir "${BUNDLE_DIR}" \
      --scan_children true \
      --product_type all \
      --outdir "${OUT_DIR}"
  done
done

echo "[4/6] Validating route simulation outputs..."
for SCEN in "${SCENARIOS[@]}"; do
  for PT in "${POWERTRAINS[@]}"; do
    INPUT_DIR="${ROOT_RUN}/${SCEN}_${PT}"
    OUT_DIR="${ROOT_VAL}/route_${SCEN}_${PT}"
    mkdir -p "${OUT_DIR}"
    Rscript tools/validate_route_sim_outputs.R \
      --input_dir "${INPUT_DIR}" \
      --outdir "${OUT_DIR}" \
      --fail_on_error true
  done
done

echo "[5/6] Validating LCI outputs..."
for SCEN in "${SCENARIOS[@]}"; do
  for PT in "${POWERTRAINS[@]}"; do
    LCI_DIR="${ROOT_LCI}/${SCEN}_${PT}"
    OUT_DIR="${ROOT_VAL}/lci_${SCEN}_${PT}"
    mkdir -p "${OUT_DIR}"
    Rscript tools/validate_lci_report.R \
      --lci_dir "${LCI_DIR}" \
      --outdir "${OUT_DIR}" \
      --fail_on_error true
  done
done

echo "[6/6] Running end-to-end validations..."
for SCEN in "${SCENARIOS[@]}"; do
  OUT_DIR="${ROOT_VAL}/end_to_end_${SCEN}"
  mkdir -p "${OUT_DIR}"
  Rscript tools/validate_end_to_end.R \
    --dry_bundle_root "${ROOT_RUN}/${SCEN}_diesel" \
    --refrigerated_bundle_root "${ROOT_RUN}/${SCEN}_bev" \
    --dry_lci_dir "${ROOT_LCI}/${SCEN}_diesel" \
    --refrigerated_lci_dir "${ROOT_LCI}/${SCEN}_bev" \
    --outdir "${OUT_DIR}"
done

echo "Pipeline complete."
echo "Merged runs: ${ROOT_SUM}/${RUN_ID}_runs_merged.csv"
echo "Merged summary: ${ROOT_SUM}/${RUN_ID}_summary_merged.csv"
echo "Summary by origin: ${ROOT_SUM}/${RUN_ID}_summary_by_origin.csv"
echo "Validation root: ${ROOT_VAL}"
