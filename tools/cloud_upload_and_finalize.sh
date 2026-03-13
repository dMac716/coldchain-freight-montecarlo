#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${RUN_ID:-}"
LANE_ID="${LANE_ID:-${CONTRIBUTOR_ID:-${USER:-unknown}}}"
OUT_ROOT="${OUT_ROOT:-}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-}"
GCP_ACCOUNT_ID="${GCP_ACCOUNT_ID:-}"
WORKER_COUNT="${WORKER_COUNT:-1}"
SEED_BASE="${SEED_BASE:-${SEED:-5600}}"
N_REPS="${N_REPS:-0}"
SCENARIO_DESIGN_VERSION="${SCENARIO_DESIGN_VERSION:-crossed_factory_transport_v1}"
LAUNCHER_VERSION="${LAUNCHER_VERSION:-tools/cloud_upload_and_finalize.sh}"
UPLOAD_ON_VALIDATION_FAIL="${UPLOAD_ON_VALIDATION_FAIL:-true}"
ALLOW_REMOTE_OVERWRITE="${ALLOW_REMOTE_OVERWRITE:-false}"
VALIDATION_DUCKDB_PATH="${VALIDATION_DUCKDB_PATH:-/tmp/transport_catalog_validation.duckdb}"

if [[ -z "${RUN_ID}" || -z "${OUT_ROOT}" || -z "${REMOTE_RESULTS_ROOT}" ]]; then
  echo "Required env vars: RUN_ID, OUT_ROOT, REMOTE_RESULTS_ROOT"
  exit 1
fi

if [[ ! -d "${OUT_ROOT}" ]]; then
  echo "OUT_ROOT does not exist: ${OUT_ROOT}"
  exit 1
fi

stage_checkpoint_tree() {
  local src="$1"
  local dst="$2"
  if [[ ! -d "${src}" ]]; then
    return 0
  fi
  mkdir -p "${dst}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude '.DS_Store' \
      --exclude 'bundle_*' \
      --exclude '*.png' \
      --exclude '*.svg' \
      --exclude '*.gif' \
      --exclude '*.mp4' \
      "${src}/" "${dst}/"
  else
    cp -R "${src}/." "${dst}/"
  fi
}

for req in \
  "${OUT_ROOT}/crossed_factory_transport_scenarios.csv" \
  "${OUT_ROOT}/crossed_factory_transport_summary.csv" \
  "${OUT_ROOT}/transport_effect_decomposition.csv" \
  "${OUT_ROOT}/transport_sim_rows.csv" \
  "${OUT_ROOT}/transport_sim_paired_summary.csv" \
  "${OUT_ROOT}/transport_sim_powertrain_summary.csv" \
  "${OUT_ROOT}/transport_sim_graphics_inputs.csv" \
  "${OUT_ROOT}/crossed_factory_transport_validation_report.txt"; do
  if [[ ! -f "${req}" ]]; then
    echo "Missing required output: ${req}"
    exit 1
  fi
done

REMOTE_ROOT_NORMALIZED="${REMOTE_RESULTS_ROOT%/}"
if [[ "${REMOTE_ROOT_NORMALIZED}" == */transport_runs ]]; then
  TARGET_ROOT="${REMOTE_ROOT_NORMALIZED}/${LANE_ID}/${RUN_ID}"
else
  TARGET_ROOT="${REMOTE_ROOT_NORMALIZED}/transport_runs/${LANE_ID}/${RUN_ID}"
fi
BUCKET_PATH="${TARGET_ROOT}"

Rscript tools/write_transport_run_manifest.R \
  --run_id "${RUN_ID}" \
  --out_root "${OUT_ROOT}" \
  --lane_id "${LANE_ID}" \
  --gcp_account_id "${GCP_ACCOUNT_ID}" \
  --seed_base "${SEED_BASE}" \
  --n_reps "${N_REPS}" \
  --worker_count "${WORKER_COUNT}" \
  --launcher_version "${LAUNCHER_VERSION}" \
  --scenario_design_version "${SCENARIO_DESIGN_VERSION}" \
  --validation_passed false \
  --promotable false \
  --bucket_path "${BUCKET_PATH}" \
  --validator_status pending \
  --remote_results_root "${REMOTE_RESULTS_ROOT}" >/dev/null

STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGE_ROOT}"' EXIT
RUN_STAGE="${STAGE_ROOT}/transport_runs/${LANE_ID}/${RUN_ID}"

mkdir -p \
  "${RUN_STAGE}/raw" \
  "${RUN_STAGE}/summaries" \
  "${RUN_STAGE}/logs" \
  "${RUN_STAGE}/checkpoints" \
  "${RUN_STAGE}/validation"

cp -f "${OUT_ROOT}/manifest.json" "${RUN_STAGE}/manifest.json"
cp -f "${OUT_ROOT}/crossed_factory_transport_scenarios.csv" "${RUN_STAGE}/raw/"
cp -f "${OUT_ROOT}/transport_sim_rows.csv" "${RUN_STAGE}/raw/"
cp -f "${OUT_ROOT}/crossed_factory_transport_summary.csv" "${RUN_STAGE}/summaries/"
cp -f "${OUT_ROOT}/transport_effect_decomposition.csv" "${RUN_STAGE}/summaries/"
cp -f "${OUT_ROOT}/transport_sim_paired_summary.csv" "${RUN_STAGE}/summaries/"
cp -f "${OUT_ROOT}/transport_sim_powertrain_summary.csv" "${RUN_STAGE}/summaries/"
cp -f "${OUT_ROOT}/transport_sim_graphics_inputs.csv" "${RUN_STAGE}/summaries/"
cp -f "${OUT_ROOT}/progress.log" "${RUN_STAGE}/logs/" 2>/dev/null || true
cp -f "${OUT_ROOT}/nohup.log" "${RUN_STAGE}/logs/" 2>/dev/null || true
cp -f "${OUT_ROOT}/crossed_factory_transport_validation_report.txt" "${RUN_STAGE}/validation/"
cp -f "${OUT_ROOT}/last_completed_replicate_id.txt" "${RUN_STAGE}/checkpoints/" 2>/dev/null || true
stage_checkpoint_tree "${OUT_ROOT}/phase1" "${RUN_STAGE}/checkpoints/phase1"
stage_checkpoint_tree "${OUT_ROOT}/phase2" "${RUN_STAGE}/checkpoints/phase2"

VALIDATOR_STATUS=failed
if Rscript tools/post_run_validator.R \
  --artifact_root "${RUN_STAGE}" \
  --run_id "${RUN_ID}" \
  --lane_id "${LANE_ID}" \
  --duckdb_test_db "${VALIDATION_DUCKDB_PATH}" \
  --update_manifest true >/dev/null; then
  VALIDATOR_STATUS=promotable
else
  VALIDATOR_STATUS=failed
fi

cp -f "${RUN_STAGE}/manifest.json" "${OUT_ROOT}/manifest.json"
mkdir -p "${OUT_ROOT}/validation"
cp -f "${RUN_STAGE}/validation/post_run_validator.txt" "${OUT_ROOT}/validation/"
cp -f "${RUN_STAGE}/validation/post_run_validator.json" "${OUT_ROOT}/validation/"

if [[ "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
  if ! command -v gsutil >/dev/null 2>&1; then
    echo "gsutil is required for gs:// upload"
    exit 1
  fi
  if [[ "${ALLOW_REMOTE_OVERWRITE}" != "true" ]] && gsutil -q stat "${TARGET_ROOT}/manifest.json"; then
    echo "Remote target already exists: ${TARGET_ROOT}"
    exit 1
  fi
else
  if [[ "${ALLOW_REMOTE_OVERWRITE}" != "true" ]] && [[ -e "${TARGET_ROOT}/manifest.json" ]]; then
    echo "Remote target already exists: ${TARGET_ROOT}"
    exit 1
  fi
fi

if [[ "${VALIDATOR_STATUS}" != "promotable" && "${UPLOAD_ON_VALIDATION_FAIL}" != "true" ]]; then
  echo "Validation failed; upload suppressed because UPLOAD_ON_VALIDATION_FAIL=${UPLOAD_ON_VALIDATION_FAIL}"
  exit 1
fi

if [[ "${REMOTE_RESULTS_ROOT}" == gs://* ]]; then
  gsutil -m cp -r "${RUN_STAGE}"/* "${TARGET_ROOT}/"
else
  mkdir -p "${TARGET_ROOT}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${RUN_STAGE}/" "${TARGET_ROOT}/"
  else
    cp -R "${RUN_STAGE}/." "${TARGET_ROOT}/"
  fi
fi

echo "validator_status=${VALIDATOR_STATUS}"
echo "bucket_path=${TARGET_ROOT}"
echo "manifest=${OUT_ROOT}/manifest.json"
