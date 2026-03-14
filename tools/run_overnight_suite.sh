#!/usr/bin/env bash
set -euo pipefail

DATE_TAG="${DATE_TAG:-$(date +%Y%m%d)}"
N="${N:-20}"
SEED_PRIMARY="${SEED_PRIMARY:-123}"
SEED_SECONDARY="${SEED_SECONDARY:-321}"
ARTIFACT_MODE="${ARTIFACT_MODE:-summary_only}"

RUN_ID_PRIMARY="${RUN_ID_PRIMARY:-full_n20_overnight_${DATE_TAG}}"
RUN_ID_SECONDARY="${RUN_ID_SECONDARY:-full_n20_overnight_seed${SEED_SECONDARY}}"

echo "DATE_TAG=${DATE_TAG}"
echo "N=${N} ARTIFACT_MODE=${ARTIFACT_MODE}"
echo "RUN_ID_PRIMARY=${RUN_ID_PRIMARY} SEED_PRIMARY=${SEED_PRIMARY}"
echo "RUN_ID_SECONDARY=${RUN_ID_SECONDARY} SEED_SECONDARY=${SEED_SECONDARY}"

echo "[1/5] Primary full pipeline run..."
RUN_ID="${RUN_ID_PRIMARY}" N="${N}" SEED="${SEED_PRIMARY}" ARTIFACT_MODE="${ARTIFACT_MODE}" \
  bash tools/run_full_n20_pipeline.sh

echo "[2/5] Secondary full pipeline run..."
RUN_ID="${RUN_ID_SECONDARY}" N="${N}" SEED="${SEED_SECONDARY}" ARTIFACT_MODE="${ARTIFACT_MODE}" \
  bash tools/run_full_n20_pipeline.sh

echo "[3/5] Merge both batch roots..."
mkdir -p outputs/summaries
Rscript tools/merge_mc_batches.R \
  --bundle_roots "outputs/run_bundle/${RUN_ID_PRIMARY},outputs/run_bundle/${RUN_ID_SECONDARY}" \
  --runs_out "outputs/summaries/full_n20_overnight_combined_runs_${DATE_TAG}.csv" \
  --summary_out "outputs/summaries/full_n20_overnight_combined_summary_${DATE_TAG}.csv" \
  --summary_by_origin_out "outputs/summaries/full_n20_overnight_combined_summary_by_origin_${DATE_TAG}.csv"

echo "[4/5] Validate each run root..."
SCENARIOS=("CENTRALIZED" "REGIONALIZED" "SMOKE_LOCAL")
POWERTRAINS=("diesel" "bev")
for RID in "${RUN_ID_PRIMARY}" "${RUN_ID_SECONDARY}"; do
  for SCEN in "${SCENARIOS[@]}"; do
    for PT in "${POWERTRAINS[@]}"; do
      Rscript tools/validate_route_sim_outputs.R \
        --input_dir "outputs/run_bundle/${RID}/${SCEN}_${PT}" \
        --outdir "outputs/validation/${RID}/route_${SCEN}_${PT}" \
        --fail_on_error true
    done
  done
done

echo "[5/5] Archive key outputs..."
mkdir -p outputs/archive
tar -czf "outputs/archive/full_n20_overnight_${DATE_TAG}.tar.gz" \
  "outputs/run_bundle/${RUN_ID_PRIMARY}" \
  "outputs/run_bundle/${RUN_ID_SECONDARY}" \
  "outputs/lci_reports/${RUN_ID_PRIMARY}" \
  "outputs/lci_reports/${RUN_ID_SECONDARY}" \
  "outputs/validation/${RUN_ID_PRIMARY}" \
  "outputs/validation/${RUN_ID_SECONDARY}" \
  "outputs/summaries/full_n20_overnight_combined_runs_${DATE_TAG}.csv" \
  "outputs/summaries/full_n20_overnight_combined_summary_${DATE_TAG}.csv" \
  "outputs/summaries/full_n20_overnight_combined_summary_by_origin_${DATE_TAG}.csv"

echo "Overnight suite complete."
echo "Archive: outputs/archive/full_n20_overnight_${DATE_TAG}.tar.gz"
