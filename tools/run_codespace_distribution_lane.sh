#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Low-memory, resumable Codespaces lane for crossed factory transport simulation.
# Keeps output isolated from local runs and uses a separate seed block.

sanitize_id() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

CONTRIBUTOR_ID="${CONTRIBUTOR_ID:-${USER:-unknown}}"
LANE_ID="${LANE_ID:-codespace-$(sanitize_id "${CONTRIBUTOR_ID}")}"
SEED="${SEED:-5600}"
RUN_ID="${RUN_ID:-${LANE_ID}_$(date -u +%Y%m%dT%H%M%SZ)_seed${SEED}}"
OUT_ROOT="${OUT_ROOT:-outputs/distribution/${LANE_ID}/${RUN_ID}}"
N_REPS="${N_REPS:-20}"
DURATION_HOURS="${DURATION_HOURS:-24}"
CHUNK_SIZE="${CHUNK_SIZE:-2}"
VALIDATE_FIRST="${VALIDATE_FIRST:-true}"
RUN_LCI="${RUN_LCI:-false}"
SWAP_GROWTH_GB_LIMIT="${SWAP_GROWTH_GB_LIMIT:-2.0}"
STOP_ON_MEMORY_PRESSURE="${STOP_ON_MEMORY_PRESSURE:-true}"
RESUME="${RESUME:-true}"
PROMOTE_TO_REMOTE="${PROMOTE_TO_REMOTE:-false}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
LAUNCHER_VERSION="${LAUNCHER_VERSION:-tools/run_codespace_distribution_lane.sh}"
SCENARIO_DESIGN_VERSION="${SCENARIO_DESIGN_VERSION:-crossed_factory_transport_v1}"
NOTES="${NOTES:-}"
REQUIRE_DEV_BRANCH="${REQUIRE_DEV_BRANCH:-false}"

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
if [[ "${REQUIRE_DEV_BRANCH}" == "true" && ! "${CURRENT_BRANCH}" =~ ^dev/ ]]; then
  echo "Current branch must match dev/* when REQUIRE_DEV_BRANCH=true. Got: ${CURRENT_BRANCH:-detached}"
  exit 1
fi

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-1}"
export VECLIB_MAXIMUM_THREADS="${VECLIB_MAXIMUM_THREADS:-1}"
export R_DATATABLE_NUM_THREADS="${R_DATATABLE_NUM_THREADS:-1}"

echo "codespace lane config:"
echo "  LANE_ID=${LANE_ID}"
echo "  RUN_ID=${RUN_ID}"
echo "  OUT_ROOT=${OUT_ROOT}"
echo "  N_REPS=${N_REPS}"
echo "  SEED=${SEED}"
echo "  DURATION_HOURS=${DURATION_HOURS}"
echo "  CHUNK_SIZE=${CHUNK_SIZE}"
echo "  VALIDATE_FIRST=${VALIDATE_FIRST}"
echo "  RUN_LCI=${RUN_LCI}"
echo "  CONTRIBUTOR_ID=${CONTRIBUTOR_ID}"
echo "  CURRENT_BRANCH=${CURRENT_BRANCH:-detached}"
echo "  PROMOTE_TO_REMOTE=${PROMOTE_TO_REMOTE}"
echo "  REMOTE_RESULTS_ROOT=${REMOTE_RESULTS_ROOT}"

if [[ "${VALIDATE_FIRST}" == "true" ]]; then
  echo "[phase1] validation-only pass (N_REPS=1)"
  RUN_ID="${RUN_ID}" \
  OUT_ROOT="${OUT_ROOT}" \
  N_REPS=1 \
  SEED="${SEED}" \
  DURATION_HOURS="${DURATION_HOURS}" \
  CHUNK_SIZE="${CHUNK_SIZE}" \
  STOP_ON_MEMORY_PRESSURE="${STOP_ON_MEMORY_PRESSURE}" \
  SWAP_GROWTH_GB_LIMIT="${SWAP_GROWTH_GB_LIMIT}" \
  RESUME=false \
  RUN_LCI=false \
  VALIDATE_ONLY=true \
  bash "${REPO_ROOT}/tools/run_crossed_factory_transport_pipeline.sh"
fi

echo "[phase2] chunked production"
RUN_ID="${RUN_ID}" \
OUT_ROOT="${OUT_ROOT}" \
N_REPS="${N_REPS}" \
SEED="${SEED}" \
DURATION_HOURS="${DURATION_HOURS}" \
CHUNK_SIZE="${CHUNK_SIZE}" \
STOP_ON_MEMORY_PRESSURE="${STOP_ON_MEMORY_PRESSURE}" \
SWAP_GROWTH_GB_LIMIT="${SWAP_GROWTH_GB_LIMIT}" \
RESUME="${RESUME}" \
RUN_LCI="${RUN_LCI}" \
VALIDATE_ONLY=false \
bash "${REPO_ROOT}/tools/run_crossed_factory_transport_pipeline.sh"

Rscript "${REPO_ROOT}/tools/write_transport_run_manifest.R" \
  --run_id "${RUN_ID}" \
  --out_root "${OUT_ROOT}" \
  --lane_id "${LANE_ID}" \
  --contributor_id "${CONTRIBUTOR_ID}" \
  --launcher_version "${LAUNCHER_VERSION}" \
  --scenario_design_version "${SCENARIO_DESIGN_VERSION}" \
  --notes "${NOTES}" \
  --remote_results_root "${REMOTE_RESULTS_ROOT}"

if [[ "${PROMOTE_TO_REMOTE}" == "true" ]]; then
  if [[ -z "${REMOTE_RESULTS_ROOT}" ]]; then
    echo "PROMOTE_TO_REMOTE=true requires REMOTE_RESULTS_ROOT"
    exit 1
  fi
  bash "${REPO_ROOT}/tools/promote_transport_run_artifacts.sh"
fi

echo "codespace lane complete"
echo "  controlled rows: ${OUT_ROOT}/crossed_factory_transport_scenarios.csv"
echo "  controlled summary: ${OUT_ROOT}/crossed_factory_transport_summary.csv"
echo "  effects: ${OUT_ROOT}/transport_effect_decomposition.csv"
echo "  realistic rows: ${OUT_ROOT}/transport_sim_rows.csv"
echo "  validation: ${OUT_ROOT}/crossed_factory_transport_validation_report.txt"
echo "  progress: ${OUT_ROOT}/progress.log"
echo "  manifest: ${OUT_ROOT}/manifest.json"
